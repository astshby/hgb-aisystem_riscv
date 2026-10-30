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
function Assert-InputHashes($Root, $Files) {
    $prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    foreach ($item in $Files.PSObject.Properties) {
        $path = [IO.Path]::GetFullPath((Join-Path $Root $item.Name))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $item.Value) {
            throw "Frozen PDS input missing or changed: $($item.Name)"
        }
    }
}
function Assert-InteractiveInputs {
    $manifestPath = Join-Path $projectRoot 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.firmware_manifest_version -ne 1) { return }
    $coremark = $manifest.firmware_role -ceq 'coremark-interactive'
    $yolo = $manifest.firmware_role -ceq 'yolo-interactive'
    if ((-not ($coremark -or $yolo)) -or $manifest.firmware.elf -cne 'program.elf' -or
        $manifest.firmware.build_config.xlen -ne $manifest.xlen -or
        ($coremark -and ($manifest.firmware.build_config.test_iterations -ne 0 -or
            @($manifest.firmware.source_sha256.PSObject.Properties).Count -ne 20)) -or
        ($yolo -and ($manifest.firmware.build_config.hdmi -ne 1 -or
            $manifest.firmware.build_config.baud -ne 115200 -or
            $manifest.firmware.build_config.application -cne 'yolox-tiny-full-network' -or
            @($manifest.firmware.source_sha256.PSObject.Properties).Count -ne 27 -or
            -not $manifest.npu_enable -or -not $manifest.video_enable -or $manifest.board_clock_profile -ne 10))) {
        throw 'Invalid production interactive firmware identity.'
    }
    Assert-InputHashes $projectRoot $manifest.files
    if ($Phase -eq 'implementation') {
        if ($ImplementationScript -cne 'implement_cdc.tcl') { throw 'Interactive implementation requires native CDC binding.' }
        $receiptPath = Join-Path $projectRoot 'cdc-scope-receipt.json'
        if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'Missing native CDC scope receipt; audit and bind this synthesis first.' }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($receipt.schema -ne 1 -or $receipt.input_manifest -cne 'manifest.json' -or
            (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $receipt.input_manifest_sha256) {
            throw 'Native CDC binding belongs to different frozen inputs.'
        }
        Assert-InputHashes $projectRoot $receipt.files
    }
    Write-Output "PASS frozen interactive firmware: $($manifest.firmware.firmware_id); RV$($manifest.xlen)"
}
if ([IO.Path]::GetExtension($projectPath) -ne '.pds') { throw 'Project must name a staged .pds file.' }
if ($Phase -eq 'implementation' -and -not (Test-Path -LiteralPath $projectPath)) {
    throw 'Implementation requires the synthesized .pds file.'
}
if ($Phase -eq 'synthesis' -and (Test-Path -LiteralPath $projectPath)) {
    throw 'Synthesis requires a fresh project; refusing to replace an existing .pds file.'
}
Assert-InteractiveInputs
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
$inputManifestPath = Join-Path $projectRoot 'manifest.json'
if (Test-Path -LiteralPath $inputManifestPath) {
    $inputManifest = Get-Content -LiteralPath $inputManifestPath -Raw | ConvertFrom-Json
    if ($inputManifest.firmware_manifest_version -eq 1) {
        $receiptPath = Join-Path $LogDirectory "$Phase-$name-input.json"
        if (Test-Path -LiteralPath $receiptPath) { throw 'Preserve the existing phase input receipt.' }
        [ordered]@{
            schema = 1; phase = $Phase; project = $projectPath; script = $scriptName
            executable = $executable; arguments = $arguments; log = $log
            input_manifest_sha256 = (Get-FileHash -LiteralPath $inputManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
            source_commit = $inputManifest.source_commit; source_branch = $inputManifest.source_branch
            firmware_role = $inputManifest.firmware_role; firmware_id = $inputManifest.firmware.firmware_id
            xlen = $inputManifest.xlen; synthesis_strategy = $inputManifest.synthesis_strategy
            started_utc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    }
}
Push-Location -LiteralPath $projectRoot
try {
    Invoke-PangoLogged -Executable $executable -Arguments $arguments -Log $log
} finally { Pop-Location }
Write-Output "PASS PDS process exit: $Phase; inspect completion markers and reports in $log"
