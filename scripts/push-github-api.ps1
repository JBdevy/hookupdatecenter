param(
  [Parameter(Mandatory = $true)]
  [string]$Branch,

  [string]$Tag = ''
)

$ErrorActionPreference = 'Stop'

function Invoke-GitBlobBase64 {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'git'
  $startInfo.WorkingDirectory = (Get-Location).Path
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Arguments = (($Arguments | ForEach-Object {
    '"' + $_.Replace('"', '\"') + '"'
  }) -join ' ')

  $process = [System.Diagnostics.Process]::Start($startInfo)
  $memory = [System.IO.MemoryStream]::new()
  $process.StandardOutput.BaseStream.CopyTo($memory)
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    $memory.Dispose()
    $process.Dispose()
    throw "git $($Arguments -join ' ') falhou: $stderr"
  }
  $base64 = [Convert]::ToBase64String($memory.ToArray())
  $memory.Dispose()
  $process.Dispose()
  return $base64
}

function Invoke-GitText {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = 'git'
  $startInfo.WorkingDirectory = (Get-Location).Path
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.Arguments = (($Arguments | ForEach-Object {
    '"' + $_.Replace('"', '\"') + '"'
  }) -join ' ')
  $process = [System.Diagnostics.Process]::Start($startInfo)
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    $process.Dispose()
    throw "git $($Arguments -join ' ') falhou: $stderr"
  }
  $process.Dispose()
  return $stdout
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [object]$Body = $null
  )

  $parameters = @{
    Method = $Method
    Uri = "https://api.github.com$Path"
    Headers = $script:GitHubHeaders
    TimeoutSec = 60
  }
  if ($null -ne $Body) {
    $parameters.ContentType = 'application/json'
    $parameters.Body = $Body | ConvertTo-Json -Depth 8 -Compress
  }
  return Invoke-RestMethod @parameters
}

function Get-GitHubRefOrNull {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    return Invoke-GitHubJson -Method Get -Path $Path
  } catch {
    if ($_.Exception.Response -and
        [int]$_.Exception.Response.StatusCode -eq 404) {
      return $null
    }
    throw
  }
}

$remoteUrl = (git remote get-url origin).Trim()
if ($remoteUrl -notmatch 'github\.com[/:]([^/]+)/([^/]+?)(?:\.git)?$') {
  throw "O origin nao aponta para um repositorio GitHub reconhecido: $remoteUrl"
}
$owner = $Matches[1]
$repository = $Matches[2]
$repositoryPath = "/repos/$owner/$repository"

$credentialLines = @(
  'protocol=https',
  'host=github.com',
  ''
) | git credential fill
$credential = @{}
foreach ($line in $credentialLines) {
  $separator = $line.IndexOf('=')
  if ($separator -gt 0) {
    $credential[$line.Substring(0, $separator)] =
      $line.Substring($separator + 1)
  }
}
if (-not $credential.ContainsKey('password')) {
  throw 'A credencial do GitHub nao foi encontrada no gerenciador do Git.'
}

$script:GitHubHeaders = @{
  Authorization = 'Bearer ' + $credential.password
  Accept = 'application/vnd.github+json'
  'X-GitHub-Api-Version' = '2022-11-28'
  'User-Agent' = 'Hook-Center-Release-Script'
}

try {
  $localHead = (git rev-parse HEAD).Trim()
  $localParent = (git rev-parse 'HEAD^').Trim()
  $localTree = (git rev-parse 'HEAD^{tree}').Trim()
  $encodedBranch = [Uri]::EscapeDataString($Branch)
  $branchRefPath = "$repositoryPath/git/ref/heads/$encodedBranch"
  $remoteBranch = Invoke-GitHubJson -Method Get -Path $branchRefPath
  $remoteHead = [string]$remoteBranch.object.sha
  $publishedHead = $localHead

  if ($remoteHead -ne $localHead) {
    if ($remoteHead -ne $localParent) {
      $remoteCommit = Invoke-GitHubJson -Method Get `
        -Path "$repositoryPath/git/commits/$remoteHead"
      $remoteParent = if ($remoteCommit.parents.Count -gt 0) {
        [string]$remoteCommit.parents[0].sha
      } else { '' }
      if ([string]$remoteCommit.tree.sha -eq $localTree -and
          $remoteParent -eq $localParent) {
        $publishedHead = $remoteHead
      } else {
        throw "O GitHub esta em $remoteHead, mas o commit local parte de $localParent. Atualize a branch antes de tentar novamente."
      }
    }

    if ($publishedHead -eq $localHead) {
      Write-Host 'Enviando o commit pela API oficial do GitHub...'
      $parentCommit = Invoke-GitHubJson -Method Get `
        -Path "$repositoryPath/git/commits/$localParent"
      $changedRaw = Invoke-GitText -Arguments @(
        'diff-tree', '--no-commit-id', '--name-only', '-r', '-z',
        $localParent, $localHead
      )
      $changedPaths = @($changedRaw.Split([char]0) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($changedPaths.Count -eq 0) {
        throw 'O commit local nao possui arquivos alterados.'
      }

      $treeEntries = @()
      foreach ($relativePath in $changedPaths) {
        $treeLine = Invoke-GitText -Arguments @(
          'ls-tree', '-z', $localHead, '--', $relativePath
        )
        if ([string]::IsNullOrEmpty($treeLine)) {
          $treeEntries += @{
            path = $relativePath
            mode = '100644'
            type = 'blob'
            sha = $null
          }
          continue
        }
        $treeLine = $treeLine.TrimEnd([char]0)
        if ($treeLine -notmatch '^([0-9]{6}) ([a-z]+) ([0-9a-f]{40})\t') {
          throw "Entrada Git invalida para $relativePath."
        }
        $mode = $Matches[1]
        $type = $Matches[2]
        if ($type -ne 'blob') {
          throw "O fallback da API nao aceita o tipo $type em $relativePath."
        }
        $blobBase64 = Invoke-GitBlobBase64 -Arguments @(
          'cat-file', 'blob', "${localHead}:$relativePath"
        )
        $blob = Invoke-GitHubJson -Method Post `
          -Path "$repositoryPath/git/blobs" `
          -Body @{
            content = $blobBase64
            encoding = 'base64'
          }
        $treeEntries += @{
          path = $relativePath
          mode = $mode
          type = 'blob'
          sha = [string]$blob.sha
        }
      }

      $tree = Invoke-GitHubJson -Method Post `
        -Path "$repositoryPath/git/trees" `
        -Body @{
          base_tree = [string]$parentCommit.tree.sha
          tree = $treeEntries
        }
      if ([string]$tree.sha -ne $localTree) {
        throw "A arvore criada pela API difere do commit local: $($tree.sha)."
      }

      $metadataRaw = Invoke-GitText -Arguments @(
        'show', '-s',
        '--format=%an%x00%ae%x00%aI%x00%cn%x00%ce%x00%cI%x00%B',
        $localHead
      )
      $metadata = $metadataRaw.Split([char]0, 7)
      if ($metadata.Count -ne 7) {
        throw 'Nao foi possivel ler os metadados do commit local.'
      }
      $message = $metadata[6].TrimEnd("`r", "`n")
      $commit = Invoke-GitHubJson -Method Post `
        -Path "$repositoryPath/git/commits" `
        -Body @{
          message = $message
          tree = [string]$tree.sha
          parents = @($localParent)
          author = @{
            name = $metadata[0]
            email = $metadata[1]
            date = $metadata[2]
          }
          committer = @{
            name = $metadata[3]
            email = $metadata[4]
            date = $metadata[5]
          }
        }
      $publishedHead = [string]$commit.sha
      Invoke-GitHubJson -Method Patch `
        -Path "$repositoryPath/git/refs/heads/$encodedBranch" `
        -Body @{ sha = $publishedHead; force = $false } | Out-Null
    }

    if ($publishedHead -ne $localHead) {
      git fetch origin $Branch | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw 'O commit foi publicado, mas a branch local nao conseguiu atualizar.'
      }
      git update-ref "refs/heads/$Branch" $publishedHead $localHead
      if ($LASTEXITCODE -ne 0) {
        throw 'O commit foi publicado, mas a referencia local nao conseguiu atualizar.'
      }
      $localHead = $publishedHead
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($Tag)) {
    $encodedTag = [Uri]::EscapeDataString($Tag)
    $tagPath = "$repositoryPath/git/ref/tags/$encodedTag"
    $remoteTag = Get-GitHubRefOrNull -Path $tagPath
    if ($null -eq $remoteTag) {
      Write-Host "Criando a tag $Tag pela API oficial do GitHub..."
      Invoke-GitHubJson -Method Post `
        -Path "$repositoryPath/git/refs" `
        -Body @{ ref = "refs/tags/$Tag"; sha = $publishedHead } | Out-Null
    } elseif ([string]$remoteTag.object.sha -ne $publishedHead) {
      throw "A tag $Tag ja existe no GitHub apontando para outro commit."
    }
  }

  Write-Host 'Branch e tag publicadas pela API do GitHub.'
} finally {
  if ($credential) { $credential.Clear() }
  Remove-Variable credentialLines -ErrorAction SilentlyContinue
  Remove-Variable GitHubHeaders -Scope Script -ErrorAction SilentlyContinue
}
