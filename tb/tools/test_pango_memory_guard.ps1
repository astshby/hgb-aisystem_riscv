# Module: test_pango_memory_guard
# Description: Exercise exact thresholds, failed queries and preserved rejection receipts without PDS.
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\scripts\pango\memory_guard.ps1')
$script:passed = 0
function Check {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL $Name" }
    $script:passed++
    Write-Output "PASS $Name"
}
function Check-Throws {
    param([scriptblock]$Action, [string]$Name)
    $caught = $false
    try { $null = & $Action } catch { $caught = $true }
    Check $caught $Name
}
$floor = [uint64](6GB)
foreach ($case in @(
    @($floor, $floor, $true, 'exact-threshold'),
    @(($floor - 1), $floor, $false, 'physical-one-byte-short'),
    @($floor, ($floor - 1), $false, 'commit-one-byte-short'),
    @(($floor + 1), ($floor + 1), $true, 'both-above-threshold'),
    @(12GB, 0, $false, 'physical-free-commit-full'),
    @(0, 12GB, $false, 'commit-free-physical-full')
)) {
    $counters = [pscustomobject]@{AvailableBytes=$case[0]; CommittedBytes=16GB; CommitLimit=(16GB + $case[1])}
    $result = Get-PangoMemoryDecision $counters
    Check ($result.allowed -eq $case[2]) $case[3]
}
$healthy = [pscustomobject]@{AvailableBytes=12GB; CommittedBytes=16GB; CommitLimit=23GB}
Check (-not (Get-PangoMemoryDecision $healthy 6 8).allowed) 'higher-phase-floor-retained'
Check-Throws { Get-PangoMemoryDecision $healthy 5.999 6 } 'cannot-weaken-physical-floor'
Check-Throws { Get-PangoMemoryDecision $healthy 6 5.999 } 'cannot-weaken-commit-floor'
Check-Throws { Get-PangoMemoryDecision ([pscustomobject]@{AvailableBytes=12GB; CommitLimit=32GB}) } 'missing-counter'
Check-Throws { Get-PangoMemoryDecision ([pscustomobject]@{AvailableBytes=-1; CommittedBytes=16GB; CommitLimit=32GB}) } 'negative-counter'
Check-Throws { Get-PangoMemoryDecision ([pscustomobject]@{AvailableBytes=12GB; CommittedBytes=33GB; CommitLimit=32GB}) } 'invalid-commit-accounting'

# Mock only the counter query. The production gate and receipt path remain active.
$script:mockCounters = $healthy
$script:queryFails = $false
function Get-CimInstance {
    [CmdletBinding()]param([string]$ClassName)
    if ($ClassName -ne 'Win32_PerfFormattedData_PerfOS_Memory') { throw 'Unexpected counter query.' }
    if ($script:queryFails) { throw 'Injected query failure.' }
    return $script:mockCounters
}
$testRoot = Join-Path $OutputDirectory ([guid]::NewGuid().ToString('N'))
$null = Assert-PangoMemoryAvailable $testRoot 'fixture'
$script:mockCounters = [pscustomobject]@{AvailableBytes=12GB; CommittedBytes=16GB; CommitLimit=21GB}
Check-Throws { Assert-PangoMemoryAvailable $testRoot 'fixture' } 'live-gate-rejects-low-commit'
$script:queryFails = $true
Check-Throws { Assert-PangoMemoryAvailable $testRoot 'fixture' } 'query-failure-closes-gate'
$receipts = @(Get-ChildItem -LiteralPath $testRoot -Filter '*.json' | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
})
Check ($receipts.Count -eq 3) 'repeated-phase-keeps-all-receipts'
Check (@($receipts | Where-Object {$_.allowed}).Count -eq 1) 'only-valid-query-allowed'
Check (@($receipts | Where-Object {$_.query_error -eq 'Injected query failure.'}).Count -eq 1) 'query-error-receipt-preserved'
Write-Output "PASS memory guard: $script:passed checks; no PDS invoked"
