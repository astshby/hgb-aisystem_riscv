# Module: memory_gate
# Description: Standalone fail-closed memory preflight called by PDS Tcl.
param(
    [Parameter(Mandatory=$true)][string]$LogDirectory,
    [Parameter(Mandatory=$true)][string]$Phase
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'memory_guard.ps1')
$physical = 6.0
$commit = 6.0
if ($env:HGB_PDS_MIN_PHYSICAL_GIB) { $physical = [double]$env:HGB_PDS_MIN_PHYSICAL_GIB }
if ($env:HGB_PDS_MIN_COMMIT_GIB) { $commit = [double]$env:HGB_PDS_MIN_COMMIT_GIB }
Assert-PangoMemoryAvailable -LogDirectory $LogDirectory -Phase $Phase `
    -MinimumPhysicalGiB $physical -MinimumCommitGiB $commit
