# Module: build
# Description: Rebuild the synthesis-only RV32 board candidate from WSL sources and licensed Pango tools.
param(
    [Parameter(Mandatory=$true)][string]$PdsHome,
    [Parameter(Mandatory=$true)][string]$DdrIpArchive,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$Distribution = 'Ubuntu-22.04',
    [string]$WslUser = '',
    [string]$CrossCompile = '',
    [ValidateSet('full','lite')][string]$SocProfile = 'full',
    [ValidateSet(0,1)][int]$LocalTcmEnable = 0
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CrossCompile)) {
    if ([string]::IsNullOrWhiteSpace($env:RISCV_TOOL_ROOT)) {
        throw 'Set RISCV_TOOL_ROOT or pass -CrossCompile.'
    }
    $CrossCompile = (Join-Path $env:RISCV_TOOL_ROOT 'riscv64-unknown-elf-')
}
. (Join-Path $PSScriptRoot 'wsl_helpers.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$root = [IO.Path]::GetFullPath($WorkRoot)
$pdsRoot = (Resolve-Path -LiteralPath $PdsHome).Path.TrimEnd('\')
$archive = (Resolve-Path -LiteralPath $DdrIpArchive).Path
if ($root.StartsWith('\\') -or $root -match '[^\x00-\x7f{}]') { throw 'WorkRoot must be a new native Windows drive directory with an ASCII path.' }
if ($root -eq $pdsRoot -or $root.StartsWith($pdsRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'WorkRoot must be outside the PDS installation.' }
if (Test-Path -LiteralPath $root) { throw 'WorkRoot must not exist; preserve prior results.' }
foreach ($tool in @('pds_shell.exe','ip_tar.exe','ip_generate.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $pdsRoot "bin\$tool"))) { throw "Missing Pango tool: $tool" }
}
$options = @(Get-PangoWslOptions $Distribution $WslUser)
$wslRepo = ConvertTo-PangoWslPath $repo $Distribution $WslUser
$wslRoot = ConvertTo-PangoWslPath $root $Distribution $WslUser
if ($wslRoot -eq $wslRepo -or $wslRoot.StartsWith($wslRepo.TrimEnd('/')+'/')) { throw 'WorkRoot must be outside the checkout.' }
New-Item -ItemType Directory -Path $root | Out-Null
$logRoot = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logRoot | Out-Null
Write-Output 'RUN WSL toolchain and production 115200 UART loader'
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'env', "CROSS_COMPILE=$CrossCompile", 'LOADER_BAUD=115200', 'LOADER_QUIET_MS=100', 'bash', 'scripts/loader/build.sh', '32')) -Log (Join-Path $logRoot 'loader.log')
Write-Output 'RUN isolated HMIC_S 1.10 generation from checked-in board configuration'
& (Join-Path $PSScriptRoot 'generate_ddr_ip.ps1') -ReferenceIdf (Join-Path $repo 'ip\pango\mes2l676_200hp_ddr3.idf') -IpArchive $archive -WorkRoot (Join-Path $root 'ddr-ip') -PdsHome $pdsRoot -UseWslPython -Distribution $Distribution -WslUser $WslUser
Write-Output 'RUN WSL staging into native Windows PDS directory'
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'python3', 'scripts/pango/prepare_project.py', '--xlen', '32', '--soc-profile', $SocProfile, '--local-tcm', "$LocalTcmEnable", '--ip-dir', "$wslRoot/ddr-ip/candidate/ddr3_test", '--output', "$wslRoot/soc-rv32")) -Log (Join-Path $logRoot 'staging.log')
$project = Join-Path $root 'soc-rv32'
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'python3', 'scripts/pango/verify_synthesis.py', "$wslRoot/soc-rv32", '--staging-only')) -Log (Join-Path $logRoot 'staging-verification.log')
$manifest = Get-Content -LiteralPath (Join-Path $project 'manifest.json') -Raw | ConvertFrom-Json
$profileId = if ($SocProfile -eq 'lite') { 1 } else { 0 }
if ($manifest.schema_version -ne 3 -or $manifest.xlen -ne 32 -or
    $manifest.mul -ne 0 -or $manifest.div -ne 1 -or
    $manifest.soc_profile -cne $SocProfile -or $manifest.soc_profile_id -ne $profileId -or
    $manifest.local_tcm_enable -ne $LocalTcmEnable -or
    $manifest.dma_wide_enable -ne 1 -or $manifest.ddr_data_bits -ne 256 -or
    $manifest.cache_block_enable -ne 1 -or $manifest.dma_block_enable -ne 1 -or
    $manifest.core_issue_width -ne 1) {
    throw 'Staged manifest does not match the requested board configuration.'
}
Write-Output 'RUN native PDS ADS compile and synthesis (RV32 DSP/SRT)'
& (Join-Path $PSScriptRoot 'memory_gate.ps1') -LogDirectory $logRoot -Phase 'synthesis'
Invoke-PangoLogged -Executable (Join-Path $pdsRoot 'bin\pds_shell.exe') -Arguments @('-work_dir', $project, '-project_name', 'soc_rv32', '-file', (Join-Path $project 'synthesize.tcl')) -Log (Join-Path $logRoot 'synthesis.log')
if (-not (Select-String -LiteralPath (Join-Path $logRoot 'synthesis.log') -SimpleMatch 'Executing : synthesize -ads -selected_syn_tool_opt 2 successfully.' -Quiet)) { throw 'Missing successful synthesis marker.' }
Write-Output 'RUN strict full-image TCM INIT and staged-byte checks'
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'python3', 'scripts/pango/check_tcm_init.py', "$wslRoot/soc-rv32")) -Log (Join-Path $logRoot 'tcm-init.log')
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'python3', 'scripts/pango/verify_synthesis.py', "$wslRoot/soc-rv32")) -Log (Join-Path $logRoot 'verification.log')
Get-Content -LiteralPath (Join-Path $logRoot 'tcm-init.log')
Get-Content -LiteralPath (Join-Path $logRoot 'verification.log')
$gitHead = & wsl.exe @options --cd $wslRepo --exec git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot read source revision.' }
$gitState = & wsl.exe @options --cd $wslRepo --exec git status --porcelain --untracked-files=normal
if ($LASTEXITCODE -ne 0) { throw 'Cannot read source state.' }
$receipt = [ordered]@{
    status = 'PASS synthesis and strict TCM INIT; no timing closure or board claim'
    git_head = ($gitHead | Select-Object -Last 1).Trim()
    source_clean = -not [bool]$gitState
    source_status = @($gitState)
    distribution = $Distribution
    cross_compile = $CrossCompile
    pds_home = $pdsRoot
    ddr_ip_archive_sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLower()
    board_config_sha256 = (Get-FileHash -LiteralPath (Join-Path $repo 'ip\pango\mes2l676_200hp_ddr3.idf') -Algorithm SHA256).Hash.ToLower()
    manifest_schema_version = $manifest.schema_version
    xlen = $manifest.xlen
    mul_impl = $manifest.mul
    div_impl = $manifest.div
    soc_profile = $manifest.soc_profile
    soc_profile_id = $manifest.soc_profile_id
    local_tcm_enable = $manifest.local_tcm_enable
    dma_wide_enable = $manifest.dma_wide_enable
    ddr_data_bits = $manifest.ddr_data_bits
    cache_block_enable = $manifest.cache_block_enable
    dma_block_enable = $manifest.dma_block_enable
    core_issue_width = $manifest.core_issue_width
    soc_presence = $manifest.soc_presence
    slow_presence = $manifest.slow_presence
    soc_user_clock_hz = $manifest.soc_clock_hz
    target_soc_clock_hz = 100000000
    work_root = $root
    synthesis_summary = 'soc-rv32/synthesis-summary.json'
}
[IO.File]::WriteAllText((Join-Path $root 'build-receipt.json'), ($receipt | ConvertTo-Json -Depth 6))
Write-Output "PASS reproducible synthesis evidence: $root"
Write-Output 'No place/route, bitstream generation, JTAG or programming commands were run.'
