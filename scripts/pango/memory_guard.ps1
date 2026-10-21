# Module: memory_guard
# Description: Validate Windows physical and commit headroom before each PDS phase.
function Get-PangoMemoryDecision {
    param(
        [Parameter(Mandatory=$true)]$Counters,
        [ValidateRange(6, 1048576)][double]$MinimumPhysicalGiB = 6,
        [ValidateRange(6, 1048576)][double]$MinimumCommitGiB = 6
    )
    foreach ($minimum in @($MinimumPhysicalGiB, $MinimumCommitGiB)) {
        if ([double]::IsNaN($minimum) -or [double]::IsInfinity($minimum) -or $minimum -lt 6.0) {
            throw 'Memory thresholds must be finite and at least 6 GiB.'
        }
    }
    foreach ($name in @('AvailableBytes', 'CommittedBytes', 'CommitLimit')) {
        $property = $Counters.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value -or
            "$($property.Value)" -notmatch '^\d+$') {
            throw "Missing or invalid Windows memory counter: $name"
        }
    }
    $available = [uint64]$Counters.AvailableBytes
    $committed = [uint64]$Counters.CommittedBytes
    $limit = [uint64]$Counters.CommitLimit
    if ($limit -eq 0 -or $committed -gt $limit) { throw 'Invalid Windows commit accounting.' }
    $freeCommit = $limit - $committed
    $physicalFloor = [uint64][math]::Ceiling($MinimumPhysicalGiB * 1GB)
    $commitFloor = [uint64][math]::Ceiling($MinimumCommitGiB * 1GB)
    # Compare exact bytes: rounding must not admit a value below 6 GiB.
    return [pscustomobject][ordered]@{
        available_physical_bytes = $available
        committed_bytes = $committed
        commit_limit_bytes = $limit
        available_commit_bytes = $freeCommit
        minimum_physical_bytes = $physicalFloor
        minimum_commit_bytes = $commitFloor
        allowed = ($available -ge $physicalFloor -and $freeCommit -ge $commitFloor)
    }
}

function Assert-PangoMemoryAvailable {
    param(
        [Parameter(Mandatory=$true)][string]$LogDirectory,
        [Parameter(Mandatory=$true)][string]$Phase,
        [ValidateRange(6, 1048576)][double]$MinimumPhysicalGiB = 6,
        [ValidateRange(6, 1048576)][double]$MinimumCommitGiB = 6
    )
    $receipt = [ordered]@{ timestamp = (Get-Date -Format o); phase = $Phase; allowed = $false }
    $failure = $null
    try {
        $counters = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $decision = Get-PangoMemoryDecision $counters $MinimumPhysicalGiB $MinimumCommitGiB
        foreach ($property in $decision.PSObject.Properties) { $receipt[$property.Name] = $property.Value }
    } catch {
        $failure = $_.Exception.Message
        $receipt['query_error'] = $failure
    }
    # Keep every receipt, including a failed query; never replace prior evidence.
    $null = New-Item -ItemType Directory -Force -Path $LogDirectory
    $safePhase = $Phase -replace '[^a-zA-Z0-9_-]', '_'
    $path = Join-Path $LogDirectory ("memory-{0}-{1}.json" -f $safePhase, [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($path, (($receipt | ConvertTo-Json -Depth 4) + [Environment]::NewLine))
    if ($failure) { throw "Windows memory query failed; PDS not started: $failure; $path" }
    if (-not $receipt.allowed) { throw "Insufficient physical/commit headroom; PDS phase not started; $path" }
    Write-Output ("PASS memory {0}: physical={1:F3} GiB commit={2:F3} GiB; {3}" -f
        $Phase, ($receipt.available_physical_bytes / 1GB), ($receipt.available_commit_bytes / 1GB), $path)
}
