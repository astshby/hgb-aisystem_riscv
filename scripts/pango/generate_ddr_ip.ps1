param(
    [Parameter(Mandatory=$true)][string]$ReferenceIdf,
    [Parameter(Mandatory=$true)][string]$IpArchive,
    [Parameter(Mandatory=$true)][string]$WorkRoot,
    [string]$PdsHome = $env:PDS_HOME,
    [string]$PythonExe = 'python',
    [switch]$UseWslPython,
    [string]$Distribution = 'Ubuntu-22.04',
    [string]$WslUser = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($PdsHome)) {
    throw 'Set PDS_HOME or pass -PdsHome; no installation path is hardcoded.'
}
. (Join-Path $PSScriptRoot 'wsl_helpers.ps1')
$root = [IO.Path]::GetFullPath($WorkRoot)
$pdsRoot = [IO.Path]::GetFullPath($PdsHome).TrimEnd('\')
if ($root -eq $pdsRoot -or $root.StartsWith($pdsRoot+'\',[StringComparison]::OrdinalIgnoreCase)) {
    throw 'WorkRoot must be outside the PDS installation.'
}
if ($root.StartsWith('\\') -or $root -match '[^\x00-\x7f]') {
    throw 'Use a local Windows path with ASCII characters; the WSL UNC IP generation lock failed in testing.'
}
$sourceIdf = (Resolve-Path -LiteralPath $ReferenceIdf).Path
if (Test-Path -LiteralPath $root) { throw 'WorkRoot must be new; preserve previous IP results.' }
$instance = Join-Path $root 'candidate\ddr3_test'
$targetIdf = Join-Path $instance 'ddr3_test.idf'
if ($sourceIdf -eq $targetIdf) { throw 'Reference and generated IDF must be separate.' }
New-Item -ItemType Directory -Force -Path $instance,(Join-Path $root 'ip-repo') | Out-Null
Copy-Item -LiteralPath $IpArchive -Destination (Join-Path $root 'ddr_ip.iar')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'mes2l676_200hp.fdc') -Destination (Join-Path $root 'board.fdc')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'import_ddr_pins.tcl') -Destination (Join-Path $root 'import_pins.tcl')
# 安装器的归档相对路径以工作目录为基准；只在新隔离目录提取，不依赖旧工程或全局 IP。
Push-Location -LiteralPath $root
try {
    Invoke-PangoLogged -Executable (Join-Path $PdsHome 'bin\ip_tar.exe') -Arguments @('-i', (Join-Path $root 'ddr_ip.iar'), '-to', (Join-Path $root 'ip-repo'), '-overwrite') -Log (Join-Path $root 'install-console.log')
} finally { Pop-Location }
[xml]$idf = Get-Content -LiteralPath $sourceIdf -Raw
if ($idf.ip_inst.header.version -ne '1.10') { throw 'This workflow is verified only for Logos2 HMIC_S 1.10.' }
foreach ($parameter in $idf.ip_inst.param_list.param) {
    if ($parameter.name -eq 'USER_PINS_CON_EN') { $parameter.value = 'true' }
    if ($parameter.name -eq 'USER_FDC_PATH') { $parameter.value = (Join-Path $root 'board.fdc').Replace('\','/') }
}
$idf.Save($targetIdf)
$models = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter index.xml | Where-Object { $_.FullName -match '[\\/]ips2l_hmic_s[\\/]ips2l_hmic_eval[\\/]ips2l_hmic_s[\\/]index\.xml$' })
if ($models.Count -ne 1) { throw 'Expected exactly one isolated HMIC_S model from the archive.' }
$model = $models[0].Directory.FullName
Invoke-PangoLogged -Executable (Join-Path $PdsHome 'bin\ip_generate.exe') -Arguments @('-i', $targetIdf, '-m', $model, '-disable-syn', '-pre', (Join-Path $root 'import_pins.tcl')) -Log (Join-Path $root 'generate-console.log')
if ($UseWslPython) {
    $options = @(Get-PangoWslOptions $Distribution $WslUser)
    $checker = ConvertTo-PangoWslPath (Join-Path $PSScriptRoot 'check_ip_dq.py') $Distribution $WslUser
    $idfPath = ConvertTo-PangoWslPath $targetIdf $Distribution $WslUser
    $fdcPath = ConvertTo-PangoWslPath (Join-Path $root 'board.fdc') $Distribution $WslUser
    Invoke-PangoLogged -Executable 'wsl.exe' -Arguments ($options + @('--exec', 'python3', $checker, $idfPath, '--fdc', $fdcPath)) -Log (Join-Path $root 'dq-check.log')
} else {
    Invoke-PangoLogged -Executable $PythonExe -Arguments @((Join-Path $PSScriptRoot 'check_ip_dq.py'), $targetIdf, '--fdc', (Join-Path $root 'board.fdc')) -Log (Join-Path $root 'dq-check.log')
}
Get-Content -LiteralPath (Join-Path $root 'dq-check.log')
Write-Output "PASS DDR IP generated and DQ metadata checked: $targetIdf"
Write-Output 'Memory timing equivalence, generated PHY constraints, synthesis/P&R and board calibration remain unverified.'
