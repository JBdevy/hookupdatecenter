param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$ProcessTestExecutable,
    [Parameter(Mandatory)][string]$RuntimeDirectory,
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [string]$SourceDirectory
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceDirectory)) {$SourceDirectory=Split-Path -Parent $PSScriptRoot}
$Executable=(Resolve-Path -LiteralPath $Executable).Path
$ProcessTestExecutable=(Resolve-Path -LiteralPath $ProcessTestExecutable).Path
$RuntimeDirectory=(Resolve-Path -LiteralPath $RuntimeDirectory).Path
$SourceDirectory=(Resolve-Path -LiteralPath $SourceDirectory).Path
$ResultsDirectory=[IO.Path]::GetFullPath($ResultsDirectory)
$applicationDirectory=Split-Path -Parent $Executable
if($ResultsDirectory.StartsWith($applicationDirectory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
   $ResultsDirectory.Equals($applicationDirectory,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Os resultados de teste devem ficar fora da pasta do aplicativo de produção.'
}
New-Item -ItemType Directory -Force -Path $ResultsDirectory | Out-Null
$isolated=Join-Path $ResultsDirectory ('isolated-'+[Guid]::NewGuid().ToString('N'))
$testRuntime=Join-Path $isolated 'StemSeparationRuntime'
$pythonLink=Join-Path $testRuntime 'python'
$fixtureWorker=Join-Path $SourceDirectory '../WindowsNative/Tests/StemIdentityWorker.py'
$graphResults=Join-Path $ResultsDirectory 'graph'
$previousIdentity=[Environment]::GetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST','Process')
$guard=@{}

function Copy-TestFile([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    # All linked files are read-only inputs to the tests. The fixture worker is
    # always a separate copy, never a link to the production worker.
    try { New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null }
    catch { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
}
function Copy-TestApplication([string]$Source,[string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach($entry in Get-ChildItem -LiteralPath $Source) {
        if($entry.Name -eq 'StemSeparationRuntime'){continue}
        $target=Join-Path $Destination $entry.Name
        if($entry.PSIsContainer) { Copy-TestApplication $entry.FullName $target }
        else { Copy-TestFile $entry.FullName $target }
    }
}
function Invoke-CatStemTest([string]$Program,[string[]]$Arguments,[string]$Name,[int]$TimeoutSeconds) {
    $stdout=Join-Path $ResultsDirectory ($Name+'.stdout.log')
    $stderr=Join-Path $ResultsDirectory ($Name+'.stderr.log')
    # These arguments are filenames or fixed switches; a quote is not valid in
    # a Windows filename. Keep each path intact when it contains spaces.
    $argumentLine=($Arguments | ForEach-Object {
        if($_ -ne '' -and $_ -notmatch '[\s"]'){$_}
        else {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}
    }) -join ' '
    # Own the process handle. Windows PowerShell 5.1's Start-Process -PassThru
    # can otherwise return a null ExitCode after a successfully finished test.
    $process=[Diagnostics.Process]::new()
    $process.StartInfo.FileName=$Program
    $process.StartInfo.Arguments=$argumentLine
    $process.StartInfo.WorkingDirectory=$isolated
    $process.StartInfo.UseShellExecute=$false
    $process.StartInfo.CreateNoWindow=$true
    $process.StartInfo.RedirectStandardOutput=$true
    $process.StartInfo.RedirectStandardError=$true
    $outFile=[IO.File]::Open($stdout,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $errFile=[IO.File]::Open($stderr,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    $started=$false
    try {
        $started=$process.Start()
        if(-not $started){throw "Não foi possível iniciar $Name."}
        # Drain both pipes concurrently, so a noisy failure cannot fill one pipe
        # while the parent waits on the other. Logs also survive a timeout.
        $outCopy=$process.StandardOutput.BaseStream.CopyToAsync($outFile)
        $errCopy=$process.StandardError.BaseStream.CopyToAsync($errFile)
        $timedOut=-not $process.WaitForExit($TimeoutSeconds*1000)
        if($timedOut) {
            # Include the isolated Python children; never stop the user's app.
            & taskkill.exe /PID $process.Id /T /F | Out-Null
            if(-not $process.WaitForExit(5000)){throw "Não foi possível encerrar o teste isolado $Name."}
        }
        if(-not $outCopy.Wait(5000) -or -not $errCopy.Wait(5000)){throw "Os logs do teste $Name não foram concluídos."}
        [void]$outCopy.GetAwaiter().GetResult();[void]$errCopy.GetAwaiter().GetResult()
        $outFile.Flush();$errFile.Flush()
        if($timedOut){throw "$Name excedeu o limite de $TimeoutSeconds segundos. Veja $stderr."}
        $exitCode=$process.ExitCode
        if($exitCode -ne 0) {
            Get-Content -LiteralPath $stderr -Tail 40 -ErrorAction SilentlyContinue | Write-Host
            $failedReport=Join-Path $graphResults 'results.json'
            if($Name -eq 'graph' -and (Test-Path -LiteralPath $failedReport)) {
                (Get-Content -LiteralPath $failedReport -Raw | ConvertFrom-Json).failed | Write-Host
            }
            throw "$Name falhou (exit $exitCode). Veja $ResultsDirectory."
        }
    } finally {
        if($started -and -not $process.HasExited){& taskkill.exe /PID $process.Id /T /F | Out-Null}
        $outFile.Dispose();$errFile.Dispose();$process.Dispose()
    }
}

try {
    foreach($relative in @('stream_windows.py','stream.py','openvino_backend.py','runtime.json',
                           '5c90dfd2-34c22ccb.th','python/python.exe',
                           'htdemucs6-openvino.xml','htdemucs6-openvino.bin','htdemucs6-openvino.json')) {
        $path=Join-Path $RuntimeDirectory $relative
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Runtime CatStem incompleto: $path"}
        $guard[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $guard[$Executable]=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    $identity=Get-Content -LiteralPath $fixtureWorker -Raw
    if(-not $identity.Contains('Deterministic CST1 fixture')){throw 'Worker de identidade CatStem inválido.'}

    Copy-TestApplication $applicationDirectory $isolated
    New-Item -ItemType Directory -Force -Path $testRuntime | Out-Null
    # The isolated worker imports only the shared protocol's standard-library
    # code. It neither loads the model nor needs an audio device or a GPU.
    New-Item -ItemType Junction -Path $pythonLink -Target (Join-Path $RuntimeDirectory 'python') | Out-Null
    Copy-TestFile (Join-Path $RuntimeDirectory '5c90dfd2-34c22ccb.th') (Join-Path $testRuntime '5c90dfd2-34c22ccb.th')
    Copy-Item -LiteralPath (Join-Path $RuntimeDirectory 'stream.py') -Destination (Join-Path $testRuntime 'stream.py')
    Copy-Item -LiteralPath $fixtureWorker -Destination (Join-Path $testRuntime 'stream_windows.py')
    $python=Join-Path $pythonLink 'python.exe'
    $worker=Join-Path $testRuntime 'stream_windows.py'
    $model=Join-Path $testRuntime '5c90dfd2-34c22ccb.th'

    Write-Host 'CatStem: validando IPC persistente em 44100, 48000, 96000 e 192000 Hz...'
    Invoke-CatStemTest $ProcessTestExecutable @($python,$worker,$model) 'ipc' 600
    $ipc=Get-Content -LiteralPath (Join-Path $ResultsDirectory 'ipc.stdout.log') -Raw
    foreach($rate in @(44100,48000,96000,192000)) {
        if(-not $ipc.Contains("passed at $rate Hz")){throw "O teste IPC não confirmou $rate Hz."}
    }

    Write-Host 'CatStem: validando o grafo de áudio, PDC e exportação com worker isolado...'
    [Environment]::SetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST','1','Process')
    # A new report directory prevents a previous successful run from hiding a
    # crash that exits without producing its own results.json.
    if(Test-Path -LiteralPath $graphResults){Remove-Item -LiteralPath $graphResults -Recurse -Force}
    Invoke-CatStemTest (Join-Path $isolated (Split-Path -Leaf $Executable)) @('--self-test',$graphResults) 'graph' 900
    $report=Get-Content -LiteralPath (Join-Path $graphResults 'results.json') -Raw | ConvertFrom-Json
    $stemPasses=@($report.passed | Where-Object {$_ -like 'CatStem *'})
    if(-not $report.success -or $report.failed -or $stemPasses.Count -lt 2 -or
       $report.passed -notcontains 'CatStem graph fixture is isolated from the production model worker' -or
       @($report.skipped | Where-Object {$_ -like 'CatStem graph*'}).Count -ne 0) {
        throw "O grafo CatStem falhou ou foi ignorado. Veja $graphResults/results.json."
    }
    Write-Host "CatStem IPC e $($stemPasses.Count) verificações do grafo passaram: $ResultsDirectory"
} finally {
    [Environment]::SetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST',$previousIdentity,'Process')
    # Remove the junction itself before recursive cleanup, including on errors.
    # The Python directory in the production package is never traversed here.
    try {
        if(Test-Path -LiteralPath $pythonLink){[IO.Directory]::Delete($pythonLink)}
        if(Test-Path -LiteralPath $isolated){Remove-Item -LiteralPath $isolated -Recurse -Force}
    } finally {
        foreach($path in $guard.Keys) {
            if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or
               (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $guard[$path]) {
                throw "O teste alterou um arquivo de produção: $path. O pacote não pode ser publicado."
            }
        }
    }
}
