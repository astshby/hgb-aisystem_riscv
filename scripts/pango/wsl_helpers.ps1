# Module: wsl_helpers
# Description: Argument-based Windows/WSL invocation for the offline Pango build.
function Get-PangoWslOptions {
    param([string]$Distribution, [string]$WslUser)
    $options = @('-d', $Distribution)
    if ($WslUser) { $options += @('-u', $WslUser) }
    return $options
}

function ConvertTo-PangoWslPath {
    param([string]$Path, [string]$Distribution, [string]$WslUser)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -match '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\(.*)$') {
        if ($Matches[1] -ne $Distribution) { throw "Repository belongs to WSL distribution $($Matches[1]), not $Distribution." }
        return '/' + $Matches[2].Replace('\', '/')
    }
    $options = @(Get-PangoWslOptions $Distribution $WslUser)
    $converted = & wsl.exe @options --exec wslpath -u $full.Replace('\', '/')
    if ($LASTEXITCODE -ne 0 -or -not $converted) { throw "Cannot convert Windows path: $full" }
    return ($converted | Select-Object -Last 1).Trim()
}

function Invoke-PangoLogged {
    param([string]$Executable, [string[]]$Arguments, [string]$Log)
    $null = Get-Command $Executable -ErrorAction Stop
    # Windows PowerShell 将原生 stderr 包装成 ErrorRecord；保留原始退出码而非因警告提前终止。
    $previous = $ErrorActionPreference
    $previousExtensions = $env:PATHEXT
    # Some launch environments supply only .CPL. Limit the executable repair to
    # this process and its PDS children; never change user/machine environment.
    if (@($env:PATHEXT -split ';') -notcontains '.EXE') {
        $env:PATHEXT = '.EXE;' + $env:PATHEXT
    }
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = $null
        & $Executable @Arguments 2>&1 | Out-File -LiteralPath $Log -Encoding utf8
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
        $env:PATHEXT = $previousExtensions
    }
    if ($null -eq $code -or $code -ne 0) {
        Get-Content -LiteralPath $Log -Tail 30
        throw "$Executable exited $code; see $Log"
    }
}
