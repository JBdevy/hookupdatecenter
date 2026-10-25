param(
    [Parameter(Mandatory)][string]$Executable,
    [string]$ProcessTestExecutable,
    [Parameter(Mandatory)][string]$RuntimeDirectory,
    [Parameter(Mandatory)][string]$ResultsDirectory,
    [string]$SourceDirectory
)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceDirectory)) {$SourceDirectory=Split-Path -Parent $PSScriptRoot}
$Executable=(Resolve-Path -LiteralPath $Executable).Path
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
$offlineTest=Join-Path $SourceDirectory '../WindowsNative/StemSeparation/test_offline.py'
$offlineParityTest=Join-Path $SourceDirectory '../WindowsNative/StemSeparation/test_offline_openvino.py'
$offlineFallbackTest=Join-Path $SourceDirectory '../WindowsNative/StemSeparation/test_worker_fallback.py'
$graphResults=Join-Path $ResultsDirectory 'graph'
$previousIdentity=[Environment]::GetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST','Process')
$previousFilter=[Environment]::GetEnvironmentVariable('CATLIVE_TEST_FILTER','Process')
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
    foreach($relative in @('stream_windows.py','stream.py','openvino_backend.py','offline_openvino.py','separate.py','runtime.json',
                           '5c90dfd2-34c22ccb.th','python/python.exe',
                           'htdemucs6-openvino.xml','htdemucs6-openvino.bin','htdemucs6-openvino.json',
                           'htdemucs6-offline.xml','htdemucs6-offline.bin','htdemucs6-offline.json')) {
        $path=Join-Path $RuntimeDirectory $relative
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Runtime CatStem incompleto: $path"}
        $guard[$path]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $guard[$Executable]=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
    Copy-TestApplication $applicationDirectory $isolated
    New-Item -ItemType Directory -Force -Path $testRuntime | Out-Null
    # Runtime/model are read-only test inputs, separate from all generated media.
    New-Item -ItemType Junction -Path $pythonLink -Target (Join-Path $RuntimeDirectory 'python') | Out-Null
    Copy-TestFile (Join-Path $RuntimeDirectory '5c90dfd2-34c22ccb.th') (Join-Path $testRuntime '5c90dfd2-34c22ccb.th')
    foreach($relative in @('offline_openvino.py','openvino_backend.py',
                           'htdemucs6-offline.xml','htdemucs6-offline.bin','htdemucs6-offline.json')) {
        Copy-TestFile (Join-Path $RuntimeDirectory $relative) (Join-Path $testRuntime $relative)
    }
    Copy-Item -LiteralPath (Join-Path $RuntimeDirectory 'separate.py') -Destination (Join-Path $testRuntime 'separate.py')
    $python=Join-Path $pythonLink 'python.exe'
    $worker=Join-Path $testRuntime 'separate.py'
    $model=Join-Path $testRuntime '5c90dfd2-34c22ccb.th'
    Write-Host 'CatStem: validando liberação do acelerador antes do fallback...'
    Invoke-CatStemTest $python @('-I','-B',$offlineFallbackTest,'--worker',$worker) 'offline-fallback-lifecycle' 60
    Write-Host 'CatStem: validando cinco arquivos offline com a aceleração automática real...'
    Invoke-CatStemTest $python @('-I','-B',$offlineTest,'--worker',$worker,'--model',$model,'--output',(Join-Path $ResultsDirectory 'audio')) 'offline' 900
    $offline=Get-Content -LiteralPath (Join-Path $ResultsDirectory 'offline.stdout.log') -Raw
    if(-not $offline.Contains('OFFLINE_FIVE_STEMS_EXACT_DURATION_UNITY_OK')){throw 'A separação offline não confirmou os cinco arquivos.'}
    Write-Host 'CatStem: validando o fallback explícito pelo processador...'
    Invoke-CatStemTest $python @('-I','-B',$offlineTest,'--worker',$worker,'--model',$model,'--device','cpu','--output',(Join-Path $ResultsDirectory 'audio-cpu-fallback')) 'offline-cpu-fallback' 900
    $fallback=Get-Content -LiteralPath (Join-Path $ResultsDirectory 'offline-cpu-fallback.stdout.log') -Raw
    if(-not $fallback.Contains('OFFLINE_FIVE_STEMS_EXACT_DURATION_UNITY_OK')){throw 'O fallback offline não confirmou os cinco arquivos.'}
    Write-Host 'CatStem: comparando todas as fontes, sobreposições e fim do áudio com o modelo original...'
    Invoke-CatStemTest $python @('-I','-B',$offlineParityTest,'--runtime',$testRuntime,'--device','CPU') 'offline-full-context-parity' 900
    $parity=Get-Content -LiteralPath (Join-Path $ResultsDirectory 'offline-full-context-parity.stdout.log') -Raw
    if(-not $parity.Contains('OFFLINE_FULL_CONTEXT_ALL_SOURCES_OVERLAP_AND_TAIL_OK')){throw 'A aceleração offline não confirmou a equivalência das fontes.'}
    # Realtime insertion is removed. Validate atomic insertion below the source,
    # plus dry playback of legacy settings; never enable the old graph fixture.
    [Environment]::SetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST','','Process')
    foreach($filter in @('Audio separation','Legacy offline-only')) {
        [Environment]::SetEnvironmentVariable('CATLIVE_TEST_FILTER',$filter,'Process')
        $graphResults=Join-Path $ResultsDirectory ($filter -replace ' ','-')
        if(Test-Path -LiteralPath $graphResults){Remove-Item -LiteralPath $graphResults -Recurse -Force}
        Invoke-CatStemTest (Join-Path $isolated (Split-Path -Leaf $Executable)) @('--self-test',$graphResults) 'graph' 180
        $report=Get-Content -LiteralPath (Join-Path $graphResults 'results.json') -Raw | ConvertFrom-Json
        if(-not $report.success -or $report.failed -or @($report.passed).Count -lt 1){throw "A validação $filter falhou: $graphResults"}
    }
    Write-Host "CatStem offline e inserção das pistas passaram: $ResultsDirectory"
} finally {
    [Environment]::SetEnvironmentVariable('CATLIVE_STEM_IDENTITY_TEST',$previousIdentity,'Process')
    [Environment]::SetEnvironmentVariable('CATLIVE_TEST_FILTER',$previousFilter,'Process')
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
