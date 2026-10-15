# Module: build
# Description: Rebuild the synthesis-only RV32 board candidate from WSL sources and licensed Pango tools.
param(
    [Parameter(Mandatory=$true)][string]$PdsHome,
    [Parameter(Mandatory=$true)][string]$DdrIpArchive,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$Distribution = 'Ubuntu-22.04',
    [string]$WslUser = '',
    [string]$CrossCompile = '/usr/bin/riscv64-linux-gnu-'
)
$ErrorActionPreference = 'Stop'
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
Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--cd', $wslRepo, '--exec', 'python3', 'scripts/pango/prepare_project.py', '--xlen', '32', '--ip-dir', "$wslRoot/ddr-ip/candidate/ddr3_test", '--output', "$wslRoot/soc-rv32")) -Log (Join-Path $logRoot 'staging.log')
$project = Join-Path $root 'soc-rv32'
Write-Output 'RUN native PDS ADS compile and synthesis (RV32 DSP/SRT)'
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
    xlen = 32
    mul_impl = 0
    div_impl = 1
    soc_user_clock_hz = 125000000
    target_soc_clock_hz = 100000000
    work_root = $root
    synthesis_summary = 'soc-rv32/synthesis-summary.json'
}
[IO.File]::WriteAllText((Join-Path $root 'build-receipt.json'), ($receipt | ConvertTo-Json -Depth 6))
Write-Output "PASS reproducible synthesis evidence: $root"
Write-Output 'No place/route, bitstream generation, JTAG or programming commands were run.'
