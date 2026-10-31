param(
    [string]$Version,
    [string]$Message,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$repositoryRoot=Split-Path $PSScriptRoot
Set-Location -LiteralPath $repositoryRoot
if(-not (Get-Command git -ErrorAction SilentlyContinue)){throw 'Git não encontrado no PATH.'}
if(-not (Get-Command node -ErrorAction SilentlyContinue)){throw 'Node.js não encontrado no PATH. Instale o Node.js 22 antes de publicar.'}
$githubCommand=Get-Command gh -ErrorAction SilentlyContinue
$githubCLI=if($githubCommand){$githubCommand.Source}else{Join-Path $env:ProgramFiles 'GitHub CLI/gh.exe'}
$githubCache=Join-Path $env:LOCALAPPDATA 'CatLiveBuild/tools/gh/bin/gh.exe'
if(-not (Test-Path -LiteralPath $githubCLI) -and (Test-Path -LiteralPath $githubCache)){$githubCLI=$githubCache}
if(-not (Test-Path -LiteralPath $githubCLI)){throw 'Instale GitHub CLI (gh) e entre com gh auth login antes de publicar.'}
$branch=(& git branch --show-current).Trim()
if($LASTEXITCODE -or -not $branch){throw 'Selecione uma branch antes de publicar.'}
if(-not $Version){$Version=Read-Host 'Versão do CatLive [1.25]';if(-not $Version){$Version='1.25'}}
$Version=$Version -replace '^v',''
if($Version -notmatch '^[0-9]+\.[0-9]{2}$'){throw 'Use a versão X.XX, por exemplo 1.25.'}
$repository='JBdevy/hookupdatecenter'
$workflow='catlive-macos-pkg.yml'
$files=@('JarasLive','.github/workflows/catlive-macos-pkg.yml','build catlive.bat','build catlive windows.bat','build catlive macos.command','scripts/publish-catlive-desktop.ps1','scripts/test-catlive-desktop-release.cjs','scripts/codesign-with-retry.py','scripts/test-codesign-retry.py')
& git status --short -- @files
if($LASTEXITCODE){throw 'Não foi possível consultar as alterações do CatLive.'}
& node scripts/test-catlive-desktop-release.cjs
if($LASTEXITCODE){throw 'A validação local do fluxo de release falhou.'}
if($ValidateOnly){Write-Host "Pré-verificação concluída. Nenhum commit, push ou build iniciado. Versão: $Version";exit 0}
& $githubCLI auth status
if($LASTEXITCODE){
    Write-Host 'Este computador precisa entrar no GitHub para enviar o código e iniciar o build.'
    & $githubCLI auth login --hostname github.com --git-protocol https --web --scopes workflow
    if($LASTEXITCODE){throw 'O login no GitHub não foi concluído. Nenhum commit ou build foi iniciado.'}
}
if(-not $Message){$Message=Read-Host 'Mensagem do commit'}
if([string]::IsNullOrWhiteSpace($Message)){throw 'Informe uma mensagem para o commit.'}
& git add -A -- @files
if($LASTEXITCODE){throw 'Falha ao preparar as alterações.'}
& git -c core.whitespace=blank-at-eol,blank-at-eof,space-before-tab,cr-at-eol diff --cached --check -- @files
if($LASTEXITCODE){throw 'Corrija os erros de formatação indicados pelo Git.'}
& git diff --cached --quiet -- @files
if($LASTEXITCODE -eq 1){
    & git commit --only -m $Message -- @files
    if($LASTEXITCODE){throw 'Falha ao criar o commit do CatLive.'}
}elseif($LASTEXITCODE -ne 0){throw 'Falha ao verificar as alterações preparadas.'}
& git push origin $branch
if($LASTEXITCODE){throw 'O push falhou. Nenhum build foi disparado e nenhum push foi forçado.'}
& $githubCLI workflow run $workflow --repo $repository --ref $branch -f "version=$Version"
if($LASTEXITCODE){throw 'O código foi enviado, mas não foi possível iniciar o workflow. Consulte o GitHub Actions.'}
Write-Host "Build macOS + Windows $Version iniciado."
Write-Host "https://github.com/$repository/actions/workflows/$workflow"
Write-Host "Os dois instaladores serão publicados na release catlive-v$Version após os testes."
