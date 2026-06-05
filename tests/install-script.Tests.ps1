$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$installScript = Join-Path $repoRoot "install.ps1"
$shellScript = Join-Path $repoRoot "install.sh"
$source = [System.IO.File]::ReadAllText($installScript, [System.Text.Encoding]::UTF8)
$shellSource = [System.IO.File]::ReadAllText($shellScript, [System.Text.Encoding]::UTF8)

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

Assert-NotContains `
    -Text $source `
    -Pattern 'Invoke-WebRequest\s+-Uri\s+\$url\s+-Headers\s+@\{\s*"Authorization"' `
    -Message "Model discovery should not issue an Authorization request before checking AuthMode."

Assert-Contains `
    -Text $source `
    -Pattern 'function\s+ConvertTo-PowerShellSingleQuotedString\s*\{' `
    -Message "PowerShell env file values should be written through a single-quote escaping helper."

Assert-Contains `
    -Text $source `
    -Pattern 'Remove-Item\s+env:CLAUDE_BOOTSTRAP_SECRET' `
    -Message "Temporary CLAUDE_BOOTSTRAP_* environment variables should be cleaned after settings sync."

Assert-Contains `
    -Text $shellSource `
    -Pattern 'raw\s*=\s*raw\.replace\(/\^\\uFEFF/' `
    -Message "Shell model-list parsing should strip a UTF-8 BOM before JSON.parse."

Assert-NotContains `
    -Text $shellSource `
    -Pattern '/tmp/claude-code-models\.\$\$' `
    -Message "Shell model discovery should not use a predictable /tmp path."

Assert-Contains `
    -Text $shellSource `
    -Pattern 'grep\s+-Fq\s+--\s+"\$model"' `
    -Message "Shell gateway validation should use fixed-string grep for model names."

Assert-Contains `
    -Text $source `
    -Pattern '/v1/messages' `
    -Message "PowerShell BASE_URL prompt should tell users not to append API paths."

Assert-Contains `
    -Text $shellSource `
    -Pattern '/v1/messages' `
    -Message "Shell BASE_URL prompt should tell users not to append API paths."

Write-Host "install-script.Tests.ps1 passed"
