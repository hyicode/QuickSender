param([string]$DevEcoHome = 'C:\Program Files\Huawei\DevEco Studio')
$ErrorActionPreference = 'Stop'
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$env:NODE_HOME = Join-Path $DevEcoHome 'tools\node'
$env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"
Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    & (Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.bat') --mode module -p product=default -p module=entry@default assembleHap --no-daemon
    $buildExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $buildExitCode
