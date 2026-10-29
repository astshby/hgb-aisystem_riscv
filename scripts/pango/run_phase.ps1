# Module: run_phase
# Description: Run one native PDS phase with a fresh log and physical/commit preflight.
param(
    [Parameter(Mandatory=$true)][string]$Project,
    [Parameter(Mandatory=$true)][string]$LogDirectory,
    [Parameter(Mandatory=$true)][ValidateSet('synthesis', 'implementation')][string]$Phase,
    [string]$PdsHome = $env:PDS_HOME,
    [ValidateSet('implement_cdc.tcl', 'implement.tcl')]
    [string]$ImplementationScript = 'implement_cdc.tcl'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'wsl_helpers.ps1')
$projectPath = [IO.Path]::GetFullPath($Project)
$projectRoot = Split-Path -Parent $projectPath
$name = [IO.Path]::GetFileNameWithoutExtension($projectPath)
if ([IO.Path]::GetExtension($projectPath) -ne '.pds') { throw 'Project must name a staged .pds file.' }
if ($Phase -eq 'implementation' -and -not (Test-Path -LiteralPath $projectPath)) {
    throw 'Implementation requires the synthesized .pds file.'
}
if ($Phase -eq 'synthesis' -and (Test-Path -LiteralPath $projectPath)) {
    throw 'Synthesis requires a fresh project; refusing to replace an existing .pds file.'
}
if ([string]::IsNullOrWhiteSpace($PdsHome)) { throw 'Set PDS_HOME or pass -PdsHome.' }
$executable = Join-Path $PdsHome 'bin\pds_shell.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Missing pds_shell.exe.' }
if (Get-Process pds_shell -ErrorAction SilentlyContinue) { throw 'Another PDS process is active.' }
$null = New-Item -ItemType Directory -Force -Path $LogDirectory
$log = Join-Path $LogDirectory "$Phase-$name.log"
if (Test-Path -LiteralPath $log) { throw 'Preserve the existing run log; use a fresh directory.' }
$scriptName = if ($Phase -eq 'synthesis') { 'synthesize.tcl' } else { $ImplementationScript }
$scriptPath = Join-Path $projectRoot $scriptName
if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing $scriptName" }
& (Join-Path $PSScriptRoot 'memory_gate.ps1') -LogDirectory $LogDirectory -Phase $Phase
$env:HGB_PDS_PROJECT = $projectPath.Replace('\', '/')
if ($Phase -eq 'synthesis') {
    $arguments = @('-work_dir', $projectRoot, '-project_name', $name, '-file', $scriptPath)
} else {
    # -project_name creates a new project with -force, even when the file exists.
    # The implementation Tcl opens the synthesized project; do not create it again.
    $arguments = @('-file', $scriptPath)
    $backup = Join-Path $LogDirectory "before-implementation-$name.pds"
    if (Test-Path -LiteralPath $backup) { throw 'Preserve the prior native project snapshot.' }
    Copy-Item -LiteralPath $projectPath -Destination $backup
}
Push-Location -LiteralPath $projectRoot
try {
    Invoke-PangoLogged -Executable $executable -Arguments $arguments -Log $log
} finally { Pop-Location }
Write-Output "PASS PDS process exit: $Phase; inspect completion markers and reports in $log"
