# Module: test_pango_native_launch
# Description: Exercise actual native launch, logging and exit status with a restricted PATHEXT.
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\pango\wsl_helpers.ps1')
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh test directory.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory
$native = Join-Path $env:SystemRoot 'System32\cmd.exe'
$original = $env:PATHEXT
$passed = 0
Push-Location -LiteralPath $env:SystemRoot
try {
    foreach ($extensions in @('.CPL', '.exe;.CPL', '')) {
        $env:PATHEXT = $extensions
        $before = $env:PATHEXT
        $log = Join-Path $OutputDirectory ("success-$passed.log")
        Invoke-PangoLogged -Executable $native -Arguments @('/d','/c','echo native-entry-pass') -Log $log
        if ((Get-Content -LiteralPath $log -Raw).Trim() -ne 'native-entry-pass') { throw 'Native stdout was lost.' }
        if ($env:PATHEXT -cne $before) { throw 'PATHEXT was not restored after success.' }
        $passed++
    }
    $env:PATHEXT = '.CPL'
    $log = Join-Path $OutputDirectory 'nonzero.log'
    $caught = $null
    try {
        Invoke-PangoLogged -Executable $native -Arguments @('/d','/c','echo native-error 1>&2 & exit /b 7') -Log $log
    } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch 'exited 7') { throw 'Nonzero exit was accepted or lost.' }
    if ((Get-Content -LiteralPath $log -Raw) -notmatch 'native-error') { throw 'Native stderr was lost.' }
    if ($env:PATHEXT -cne '.CPL') { throw 'PATHEXT was not restored after failure.' }
    $passed++
    $caught = $null
    try {
        Invoke-PangoLogged -Executable (Join-Path $OutputDirectory 'missing.exe') -Arguments @() -Log (Join-Path $OutputDirectory 'missing.log')
    } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $env:PATHEXT -cne '.CPL') { throw 'Missing executable was accepted or changed the environment.' }
    $passed++
    $entry = Join-Path $PSScriptRoot '..\..\scripts\pango\run_phase.ps1'
    $fixture = Join-Path $OutputDirectory 'existing.pds'
    [IO.File]::WriteAllText($fixture, 'preserve-existing-project')
    $caught = $null
    try {
        & $entry -Project $fixture -LogDirectory (Join-Path $OutputDirectory 'refused-synthesis') -Phase synthesis -PdsHome 'unused'
    } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch 'refusing to replace' -or
        [IO.File]::ReadAllText($fixture) -cne 'preserve-existing-project') { throw 'Existing native project was not protected.' }
    $passed++
    $caught = $null
    try {
        & $entry -Project (Join-Path $OutputDirectory 'missing.pds') -LogDirectory (Join-Path $OutputDirectory 'refused-implementation') -Phase implementation -PdsHome 'unused'
    } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch 'requires the synthesized') { throw 'Missing implementation project was accepted.' }
    $passed++
} finally { $env:PATHEXT = $original; Pop-Location }
Write-Output "PASS native PDS launcher: $passed PASS, 0 SKIP"
