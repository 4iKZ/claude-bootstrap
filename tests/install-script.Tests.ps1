$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installScript = Join-Path $repoRoot "install.ps1"
$source = Get-Content -Path $installScript -Raw

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -match $Pattern) {
        throw $Message
    }
}

Assert-Contains `
    -Text $source `
    -Pattern 'function\s+Write-LogLine\s*\{' `
    -Message "install.ps1 should use a shared Write-LogLine helper for robust PowerShell host output."

Assert-NotContains `
    -Text $source `
    -Pattern 'Write-Host\s+"[^"]*\$args' `
    -Message "Logging helpers should not interpolate the automatic `$args array directly."

Assert-Contains `
    -Text $source `
    -Pattern 'if\s*\(\s*\$_.Exception.Response\s*\)' `
    -Message "Gateway error handling should check Exception.Response before reading StatusCode."

Assert-Contains `
    -Text $source `
    -Pattern 'raw\s*=\s*raw\.replace\(/\^\\uFEFF/' `
    -Message "Node model-list parsing should strip a UTF-8 BOM before JSON.parse."

Write-Host "install-script.Tests.ps1 passed"
