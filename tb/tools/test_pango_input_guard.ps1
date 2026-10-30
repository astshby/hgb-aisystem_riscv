# Module: test_pango_input_guard
# Description: Exercise the real phase-input guards without invoking PDS or memory tools.
param([string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('hgb-input-test-' + [Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot '..\..\scripts\pango\run_phase.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Phase entry parse error: $errors" }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($function in $functions) { . ([ScriptBlock]::Create($function.Extent.Text)) }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a fresh fixture directory.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory
$projectRoot = [IO.Path]::GetFullPath($OutputDirectory)
$passed = 0
function Write-Manifest {
    $script:manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $projectRoot 'manifest.json') -Encoding UTF8
}
function Expect-Rejection([ScriptBlock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch $Pattern) { throw "Expected '$Pattern', got '$caught'" }
    $script:passed++
}
try {
    $input = Join-Path $projectRoot 'input.hex'
    [IO.File]::WriteAllText($input, 'frozen-input')
    $sources = [ordered]@{}
    foreach ($index in 1..20) { $sources["source$index.c"] = ('0' * 64) }
    $manifest = [ordered]@{
        firmware_manifest_version = 1; firmware_role = 'coremark-interactive'; xlen = 32
        firmware = [ordered]@{
            elf = 'program.elf'; firmware_id = 'fixture-input-id'; source_sha256 = $sources
            build_config = [ordered]@{ test_iterations = 0; xlen = 32 }
        }
        files = [ordered]@{ 'input.hex' = (Get-FileHash -LiteralPath $input -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $Phase = 'synthesis'
    $ImplementationScript = 'implement_cdc.tcl'
    Write-Manifest
    Assert-InteractiveInputs
    $passed++
    $manifest.xlen = 64
    $manifest.firmware.build_config.xlen = 64
    Write-Manifest
    Assert-InteractiveInputs
    $passed++
    [IO.File]::WriteAllText($input, 'changed-input')
    Expect-Rejection { Assert-InteractiveInputs } 'Frozen PDS input'
    [IO.File]::WriteAllText($input, 'frozen-input')
    foreach ($field in @('role', 'elf', 'iterations', 'xlen', 'sources')) {
        switch ($field) {
            'role' { $manifest.firmware_role = 'loader' }
            'elf' { $manifest.firmware.elf = 'loader.elf' }
            'iterations' { $manifest.firmware.build_config.test_iterations = 2 }
            'xlen' { $manifest.firmware.build_config.xlen = 32 }
            'sources' { $null = $manifest.firmware.source_sha256.Remove('source20.c') }
        }
        Write-Manifest
        Expect-Rejection { Assert-InteractiveInputs } 'Invalid production interactive firmware'
        $manifest.firmware_role = 'coremark-interactive'
        $manifest.firmware.elf = 'program.elf'
        $manifest.firmware.build_config.test_iterations = 0
        $manifest.firmware.build_config.xlen = 64
        $manifest.firmware.source_sha256['source20.c'] = ('0' * 64)
    }
    Write-Manifest
    $Phase = 'implementation'
    Expect-Rejection { Assert-InteractiveInputs } 'Missing native CDC scope receipt'
    $receipt = [ordered]@{
        schema = 1; input_manifest = 'manifest.json'
        input_manifest_sha256 = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
        files = $manifest.files
    }
    $receiptPath = Join-Path $projectRoot 'cdc-scope-receipt.json'
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    Assert-InteractiveInputs
    $passed++
    $ImplementationScript = 'implement.tcl'
    Expect-Rejection { Assert-InteractiveInputs } 'requires native CDC binding'
    $ImplementationScript = 'implement_cdc.tcl'
    [IO.File]::AppendAllText((Join-Path $projectRoot 'manifest.json'), ' ')
    Expect-Rejection { Assert-InteractiveInputs } 'different frozen inputs'
    Write-Manifest
    [IO.File]::WriteAllText($input, 'changed-bound-input')
    Expect-Rejection { Assert-InteractiveInputs } 'Frozen PDS input'
    [IO.File]::WriteAllText($input, 'frozen-input')
    Remove-Item -LiteralPath (Join-Path $projectRoot 'manifest.json')
    Assert-InteractiveInputs
    $passed++
} finally {
    # Only this test's newly created fixture is removed; no native project is opened.
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
Write-Output "PASS phase input guards: $passed PASS, 0 SKIP; no PDS invocation"
