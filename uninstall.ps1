[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$ConfigOnly,
    [switch]$Restore,
    [switch]$Full,
    [switch]$Runtime,
    [switch]$PurgeData
)

$ErrorActionPreference = "Stop"
$CLAUDE_NPM_PACKAGE_NAME = "@anthropic-ai/claude-code"
$CONFIG_DIR = "$env:USERPROFILE\.claude-bootstrap"
$ENV_FILE = "$CONFIG_DIR\env.ps1"
$ENV_CMD_FILE = "$CONFIG_DIR\env.cmd"
$WRAPPER_DIR = "$CONFIG_DIR\bin"
$CLAUDE_WRAPPER = "$WRAPPER_DIR\claude.cmd"
$INSTALL_STATE_FILE = "$CONFIG_DIR\install-state.json"
$CLAUDE_DATA_DIR = "$env:USERPROFILE\.claude"
$CLAUDE_SETTINGS_JSON = "$CLAUDE_DATA_DIR\settings.json"
$PROFILE_MARKER_BEGIN = "# >>> claude-bootstrap >>>"
$PROFILE_MARKER_END = "# <<< claude-bootstrap <<<"
$MANAGED_ENV_KEYS = @(
    "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
    "ANTHROPIC_CUSTOM_MODEL_OPTION", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
    "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DISABLE_UPDATES"
)

function Write-SafeHost {
    param([AllowNull()][object]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    $text = if ($null -eq $Message) { "" } else { [string]$Message }
    try { Microsoft.PowerShell.Utility\Write-Host $text -ForegroundColor $Color }
    catch { [Console]::Out.WriteLine($text) }
}
function Write-Utf8NoBomFile {
    param([string]$Path, [AllowNull()][string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $(if ($null -eq $Content) { "" } else { $Content }), $encoding)
}
function Get-TextFileInfo {
    param([string]$Path)
    $bytes = if (Test-Path $Path) { [System.IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
    $offset = 0
    $withPreamble = $false
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) {
        $encoding = New-Object System.Text.UTF32Encoding($false, $true); $offset = 4; $withPreamble = $true
    } elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = New-Object System.Text.UTF32Encoding($true, $true); $offset = 4; $withPreamble = $true
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object System.Text.UTF8Encoding($true); $offset = 3; $withPreamble = $true
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $offset = 2; $withPreamble = $true
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = New-Object System.Text.UnicodeEncoding($true, $true); $offset = 2; $withPreamble = $true
    } elseif ($bytes.Length -eq 0 -and $Path -match '[\\/]WindowsPowerShell[\\/]') {
        $encoding = New-Object System.Text.UTF8Encoding($true); $withPreamble = $true
    } elseif ($Path -match '[\\/]WindowsPowerShell[\\/]') {
        try {
            $encoding = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$encoding.GetString($bytes)
        } catch {
            try { $encoding = [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) }
            catch { $encoding = [System.Text.Encoding]::Default }
        }
    } else {
        $encoding = New-Object System.Text.UTF8Encoding($false)
    }
    $text = if ($bytes.Length -gt $offset) { $encoding.GetString($bytes, $offset, $bytes.Length - $offset) } else { "" }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } elseif ($text.Contains("`r")) { "`r" } else { "`r`n" }
    return [pscustomobject]@{ Text = $text; Encoding = $encoding; WithPreamble = $withPreamble; NewLine = $newline }
}

function Write-TextFilePreservingEncoding {
    param([string]$Path, [AllowNull()][string]$Text, $Info)
    $body = $Info.Encoding.GetBytes($(if ($null -eq $Text) { "" } else { $Text }))
    $preamble = if ($Info.WithPreamble) { $Info.Encoding.GetPreamble() } else { [byte[]]@() }
    $output = New-Object byte[] ($preamble.Length + $body.Length)
    if ($preamble.Length) { [Array]::Copy($preamble, 0, $output, 0, $preamble.Length) }
    if ($body.Length) { [Array]::Copy($body, 0, $output, $preamble.Length, $body.Length) }
    [System.IO.File]::WriteAllBytes($Path, $output)
}
function info { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-SafeHost ("[INFO]  " + ($Message -join " ")) Blue }
function success { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-SafeHost ("[OK]    " + ($Message -join " ")) Green }
function warn { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-SafeHost ("[WARN]  " + ($Message -join " ")) Yellow }
function fatal { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-SafeHost ("[ERROR] " + ($Message -join " ")) Red; exit 1 }
function need_cmd { param([string]$Name) return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }
function confirm { param([string]$Prompt) return (Read-Host -Prompt "$Prompt [y/N]") -match '^[Yy]$' }

function Get-StringSha256 {
    param([AllowNull()][string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($null -eq $Value) { "" } else { $Value }))
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-NodeRuntimeInventoryHash {
    param([AllowNull()][string]$Root)
    if (-not $Root -or -not (Test-Path $Root) -or -not (need_cmd node)) { return $null }
    $oldRoot = $env:CLAUDE_BOOTSTRAP_RUNTIME_ROOT
    try {
        $env:CLAUDE_BOOTSTRAP_RUNTIME_ROOT = $Root
        $script = @'
const crypto = require('crypto'), fs = require('fs'), path = require('path');
const root = process.env.CLAUDE_BOOTSTRAP_RUNTIME_ROOT, entries = [];
const visit = (absolute, relative) => {
  for (const item of fs.readdirSync(absolute, { withFileTypes: true })) {
    const rel = (relative ? `${relative}/${item.name}` : item.name).replace(/\\/g, '/');
    const full = path.join(absolute, item.name);
    if (rel === 'node_modules/@anthropic-ai') { if (item.isDirectory()) visit(full, rel); continue; }
    if (/^node_modules\/@anthropic-ai\/claude-code(?:\/|$)/.test(rel)) continue;
    if (/^claude(?:\.cmd|\.ps1)?$/i.test(rel)) continue;
    if (item.isDirectory()) { entries.push(`d:${rel}`); visit(full, rel); }
    else if (item.isSymbolicLink()) entries.push(`l:${rel}:${fs.readlinkSync(full)}`);
    else entries.push(`f:${rel}:${crypto.createHash('sha256').update(fs.readFileSync(full)).digest('hex')}`);
  }
};
visit(root, '');
process.stdout.write(crypto.createHash('sha256').update(entries.sort().join('\n')).digest('hex'));
'@
        return ((& node -e $script 2>$null) -join "").Trim()
    } finally {
        if ($null -ne $oldRoot) { $env:CLAUDE_BOOTSTRAP_RUNTIME_ROOT = $oldRoot }
        else { Remove-Item env:CLAUDE_BOOTSTRAP_RUNTIME_ROOT -ErrorAction SilentlyContinue }
    }
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-HasProperty {
    param($Object, [string]$Name)
    return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Set-ObjectProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Remove-ObjectProperty {
    param($Object, [string]$Name)
    if ($Object -and $Object.PSObject.Properties[$Name]) { $Object.PSObject.Properties.Remove($Name) }
}

function Test-ValuesEqual {
    param($Left, $Right)
    return (($Left | ConvertTo-Json -Compress -Depth 10) -eq ($Right | ConvertTo-Json -Compress -Depth 10))
}

function Get-InstallState {
    if (-not (Test-Path $INSTALL_STATE_FILE)) { return $null }
    try {
        $state = Get-Content $INSTALL_STATE_FILE -Raw | ConvertFrom-Json
        if ($state.owner -eq "claude-bootstrap" -and $state.schemaVersion -eq 1) { return $state }
    } catch {}
    warn "安装状态文件无效，将按旧安装保守处理：$INSTALL_STATE_FILE"
    return $null
}

function Get-ManagedEnvValues {
    $values = [ordered]@{}
    if (-not (Test-Path $ENV_FILE)) { return [pscustomobject]@{ Managed = $false; Values = $values } }
    $firstLine = Get-Content $ENV_FILE -TotalCount 1 -ErrorAction SilentlyContinue
    if ($firstLine -notmatch 'Generated by claude-bootstrap') {
        warn "环境文件缺少生成标记，将保留：$ENV_FILE"
        return [pscustomobject]@{ Managed = $false; Values = $values }
    }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ENV_FILE, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        warn "环境文件无法安全解析，将保留：$ENV_FILE"
        return [pscustomobject]@{ Managed = $false; Values = $values }
    }
    $assignments = @()
    foreach ($statement in @($ast.EndBlock.Statements)) {
        if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $assignments += $statement
            continue
        }
        if ($statement.Extent.Text -match '^Remove-Item env:(ANTHROPIC_AUTH_TOKEN|ANTHROPIC_API_KEY) -ErrorAction SilentlyContinue$') {
            $values[$Matches[1]] = ""
            continue
        }
        warn "环境文件包含非预期命令，将保留且不会执行：$ENV_FILE"
        return [pscustomobject]@{ Managed = $false; Values = $values }
    }
    foreach ($assignment in $assignments) {
        $name = $assignment.Left.Extent.Text -replace '^\$env:', ''
        if ($name -notin $MANAGED_ENV_KEYS) {
            warn "环境文件包含非预期变量，将保留：$ENV_FILE"
            return [pscustomobject]@{ Managed = $false; Values = [ordered]@{} }
        }
        try {
            $valueAst = if ($assignment.Right -is [System.Management.Automation.Language.CommandExpressionAst]) {
                $assignment.Right.Expression
            } else { $assignment.Right }
            $values[$name] = [string]$valueAst.SafeGetValue()
        }
        catch {
            warn "环境文件包含无法安全解析的值，将保留：$ENV_FILE"
            return [pscustomobject]@{ Managed = $false; Values = [ordered]@{} }
        }
    }
    return [pscustomobject]@{ Managed = $true; Values = $values }
}

function Invoke-SettingsCleanup {
    param([bool]$IsPreview, $EnvInfo, $State)
    if (-not (Test-Path $CLAUDE_SETTINGS_JSON)) { return $true }
    try { $data = Get-Content $CLAUDE_SETTINGS_JSON -Raw | ConvertFrom-Json }
    catch { warn "settings.json 不是有效 JSON，将保留：$CLAUDE_SETTINGS_JSON"; return $false }
    if ($null -eq $data) { warn "settings.json 结构无效，将保留。"; return $false }
    $settingsEnv = Get-PropertyValue $data "env"
    if ($null -eq $settingsEnv) { $settingsEnv = [pscustomobject]@{} }
    $changed = $false

    if ($State -and $State.settings -and $State.settings.managed) {
        foreach ($property in $State.settings.managed.PSObject.Properties) {
            $name = $property.Name
            $entry = $property.Value
            if (-not (Test-HasProperty $settingsEnv $name)) { continue }
            $current = Get-PropertyValue $settingsEnv $name
            $matches = $false
            if ($entry.secret) {
                $matches = $entry.writtenHash -and (Get-StringSha256 ([string]$current)) -eq $entry.writtenHash
            } elseif (Test-HasProperty $entry "writtenValue") {
                $matches = Test-ValuesEqual $current $entry.writtenValue
            }
            if (-not $matches) { Write-SafeHost "[保留] settings.json env.$name 已被修改或归属不明"; continue }
            if ($entry.originalKnown -and $entry.originalPresent -and -not $entry.secret) {
                Write-SafeHost "[恢复] settings.json env.$name"
                if (-not $IsPreview) { Set-ObjectProperty $settingsEnv $name $entry.originalValue }
            } else {
                Write-SafeHost "[删除] settings.json env.$name"
                if (-not $IsPreview) { Remove-ObjectProperty $settingsEnv $name }
                if ($entry.secret -and $entry.originalKnown -and $entry.originalPresent) {
                    Write-SafeHost "[无法确认] env.$name 安装前存在，但旧密钥未保存，无法恢复"
                }
            }
            $changed = $true
        }
        $skip = $State.settings.skipWebFetchPreflight
        if ($skip -and (Test-HasProperty $data "skipWebFetchPreflight")) {
            $current = Get-PropertyValue $data "skipWebFetchPreflight"
            if ((Test-HasProperty $skip "writtenValue") -and (Test-ValuesEqual $current $skip.writtenValue)) {
                if ($skip.originalKnown -and $skip.originalPresent) {
                    Write-SafeHost "[恢复] settings.json skipWebFetchPreflight"
                    if (-not $IsPreview) { Set-ObjectProperty $data "skipWebFetchPreflight" $skip.originalValue }
                } elseif ($skip.originalKnown) {
                    Write-SafeHost "[删除] settings.json skipWebFetchPreflight"
                    if (-not $IsPreview) { Remove-ObjectProperty $data "skipWebFetchPreflight" }
                }
                $changed = $true
            } else { Write-SafeHost "[保留] settings.json skipWebFetchPreflight 已被修改或归属不明" }
        }
    } elseif ($EnvInfo.Managed) {
        foreach ($entry in $EnvInfo.Values.GetEnumerator()) {
            if (Test-HasProperty $settingsEnv $entry.Key) {
                if ([string](Get-PropertyValue $settingsEnv $entry.Key) -eq [string]$entry.Value) {
                    Write-SafeHost "[删除] settings.json env.$($entry.Key)（旧安装兼容）"
                    if (-not $IsPreview) { Remove-ObjectProperty $settingsEnv $entry.Key }
                    $changed = $true
                } else { Write-SafeHost "[保留] settings.json env.$($entry.Key) 已被修改" }
            }
        }
        Write-SafeHost "[保留] settings.json skipWebFetchPreflight（旧安装无法确认归属）"
    } else {
        Write-SafeHost "[无法确认] 缺少有效状态和 env 文件，保留 settings.json"
    }

    if (-not $IsPreview -and $changed) {
        Set-ObjectProperty $data "env" $settingsEnv
        $tmp = "$CLAUDE_SETTINGS_JSON.tmp.$PID"
        Write-Utf8NoBomFile $tmp (($data | ConvertTo-Json -Depth 20) + "`n")
        Move-Item -LiteralPath $tmp -Destination $CLAUDE_SETTINGS_JSON -Force
    }
    return $true
}

function Get-ProfileCandidates {
    param($State)
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($State -and $State.profile.path) { $candidates.Add([string]$State.profile.path) }
    $candidates.Add([string]$PROFILE)
    $candidates.Add("$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1")
    $candidates.Add("$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1")
    return @($candidates | Where-Object { $_ } | Select-Object -Unique)
}

function Get-ProfileBlockStatus {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return "none" }
    $fileInfo = Get-TextFileInfo $Path
    $lines = @([regex]::Split($fileInfo.Text, "`r`n|`n|`r"))
    $begins = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq $PROFILE_MARKER_BEGIN) { $i } })
    $ends = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq $PROFILE_MARKER_END) { $i } })
    if ($begins.Count -eq 0 -and $ends.Count -eq 0) { return "none" }
    if ($begins.Count -eq 1 -and $ends.Count -eq 1 -and $begins[0] -lt $ends[0]) { return "valid" }
    return "invalid"
}

function Test-ProfileHasBlock {
    param([string]$Path)
    return (Get-ProfileBlockStatus $Path) -eq "valid"
}

function Remove-ProfileBlock {
    param([string]$Path)
    $status = Get-ProfileBlockStatus $Path
    if ($status -eq "invalid") { warn "profile 标记块不完整或重复，已保留文件：$Path"; return $false }
    if ($status -ne "valid") { return $true }
    $fileInfo = Get-TextFileInfo $Path
    $output = [System.Collections.Generic.List[string]]::new()
    $skip = $false
    foreach ($line in @([regex]::Split($fileInfo.Text, "`r`n|`n|`r"))) {
        if ($line -eq $PROFILE_MARKER_BEGIN) { $skip = $true; continue }
        if ($line -eq $PROFILE_MARKER_END) { $skip = $false; continue }
        if (-not $skip) { $output.Add($line) }
    }
    Write-TextFilePreservingEncoding $Path ($output -join $fileInfo.NewLine) $fileInfo
    success "已移除启动配置块：$Path"
    return $true
}

function Test-ManagedFile {
    param([string]$Path, [string]$Marker)
    return (Test-Path $Path) -and ((Get-Content $Path -Raw -ErrorAction SilentlyContinue) -match [regex]::Escape($Marker))
}

function Show-ConfigPreview {
    param($EnvInfo, $State)
    [void](Invoke-SettingsCleanup $true $EnvInfo $State)
    foreach ($path in Get-ProfileCandidates $State) {
        $status = Get-ProfileBlockStatus $path
        if ($status -eq "valid") { Write-SafeHost "[删除] profile 标记块：$path" }
        elseif ($status -eq "invalid") { Write-SafeHost "[无法确认] profile 标记块不完整或重复，保留：$path" }
    }
    if ($EnvInfo.Managed) { Write-SafeHost "[删除] $ENV_FILE" }
    elseif (Test-Path $ENV_FILE) { Write-SafeHost "[保留] $ENV_FILE（缺少生成标记）" }
    if (Test-ManagedFile $ENV_CMD_FILE "Generated by claude-bootstrap") { Write-SafeHost "[删除] $ENV_CMD_FILE" }
    elseif (Test-Path $ENV_CMD_FILE) { Write-SafeHost "[保留] $ENV_CMD_FILE（缺少生成标记）" }
    if (Test-ManagedFile $CLAUDE_WRAPPER "CLAUDE_BOOTSTRAP_WRAPPER") { Write-SafeHost "[删除] $CLAUDE_WRAPPER" }
    elseif (Test-Path $CLAUDE_WRAPPER) { Write-SafeHost "[保留] $CLAUDE_WRAPPER（缺少 wrapper 标记）" }
    if (Test-Path $INSTALL_STATE_FILE) { Write-SafeHost "[删除] $INSTALL_STATE_FILE（全部选定步骤成功后）" }
}

function Remove-CurrentManagedEnvironment {
    param($EnvInfo)
    foreach ($entry in $EnvInfo.Values.GetEnumerator()) {
        $current = [Environment]::GetEnvironmentVariable($entry.Key, "Process")
        if ($null -ne $current -and $current -eq [string]$entry.Value) {
            Remove-Item "env:$($entry.Key)" -ErrorAction SilentlyContinue
        }
    }
}

function Remove-BootstrapConfig {
    param($EnvInfo, $State)
    if (-not (Invoke-SettingsCleanup $false $EnvInfo $State)) { throw "settings.json 清理失败。" }
    foreach ($path in Get-ProfileCandidates $State) {
        if (-not (Remove-ProfileBlock $path)) { throw "profile 标记块无法安全清理，安装状态已保留。" }
    }
    if ($EnvInfo.Managed) { Remove-Item $ENV_FILE -Force -ErrorAction SilentlyContinue; success "已删除环境文件：$ENV_FILE" }
    if (Test-ManagedFile $ENV_CMD_FILE "Generated by claude-bootstrap") { Remove-Item $ENV_CMD_FILE -Force }
    if (Test-ManagedFile $CLAUDE_WRAPPER "CLAUDE_BOOTSTRAP_WRAPPER") { Remove-Item $CLAUDE_WRAPPER -Force; success "已删除 wrapper：$CLAUDE_WRAPPER" }
    Remove-CurrentManagedEnvironment $EnvInfo
    Remove-Item $INSTALL_STATE_FILE -Force -ErrorAction SilentlyContinue
    if ((Test-Path $WRAPPER_DIR) -and -not (Get-ChildItem $WRAPPER_DIR -Force -ErrorAction SilentlyContinue)) { Remove-Item $WRAPPER_DIR -Force }
    if ((Test-Path $CONFIG_DIR) -and -not (Get-ChildItem $CONFIG_DIR -Force -ErrorAction SilentlyContinue)) { Remove-Item $CONFIG_DIR -Force }
}

function Initialize-NodeRuntime {
    if (need_cmd npm) { return $true }
    $fnmExe = @(
        "$env:USERPROFILE\.fnm\fnm.exe",
        "$env:LOCALAPPDATA\fnm\fnm.exe",
        "$env:APPDATA\fnm\fnm.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $fnmExe) { return $false }
    $fnmDir = Split-Path $fnmExe -Parent
    if ($env:Path -notlike "*$fnmDir*") { $env:Path = "$fnmDir;$env:Path" }
    try { (& $fnmExe env --shell powershell 2>$null) | Out-String | Invoke-Expression } catch { return $false }
    return (need_cmd npm)
}

function Get-CurrentNpmPrefix {
    [void](Initialize-NodeRuntime)
    if (-not (need_cmd npm)) { return "" }
    return ((& npm config get prefix 2>$null) -join "").Trim()
}

function Invoke-NpmAtPrefix {
    param([string]$Prefix, [string[]]$Arguments)
    [void](Initialize-NodeRuntime)
    if (-not (need_cmd npm)) { throw "未检测到 npm。" }
    $oldPrefix = $env:npm_config_prefix
    try {
        if ($Prefix) { $env:npm_config_prefix = $Prefix } else { Remove-Item env:npm_config_prefix -ErrorAction SilentlyContinue }
        & npm @Arguments
        if ($LASTEXITCODE -ne 0) { throw "npm 命令失败，退出码：$LASTEXITCODE" }
    } finally {
        if ($null -ne $oldPrefix) { $env:npm_config_prefix = $oldPrefix }
        else { Remove-Item env:npm_config_prefix -ErrorAction SilentlyContinue }
    }
}

function Get-PackageVersionAtPrefix {
    param([string]$Prefix)
    [void](Initialize-NodeRuntime)
    if (-not (need_cmd npm)) { return "" }
    $oldPrefix = $env:npm_config_prefix
    try {
        if ($Prefix) { $env:npm_config_prefix = $Prefix }
        $json = (& npm list -g $CLAUDE_NPM_PACKAGE_NAME --depth=0 --json 2>$null) -join "`n"
        if (-not $json) { return "" }
        $data = $json | ConvertFrom-Json
        $property = if ($data.dependencies) { $data.dependencies.PSObject.Properties[$CLAUDE_NPM_PACKAGE_NAME] } else { $null }
        return $(if ($property -and $property.Value.version) { [string]$property.Value.version } else { "" })
    } catch { return "" }
    finally {
        if ($null -ne $oldPrefix) { $env:npm_config_prefix = $oldPrefix }
        else { Remove-Item env:npm_config_prefix -ErrorAction SilentlyContinue }
    }
}

function Get-InstallPrefix {
    param($State)
    if ($State -and $State.npm.installPrefix) { return [string]$State.npm.installPrefix }
    return Get-CurrentNpmPrefix
}

function Get-NpmPrefixCandidates {
    param($State)
    $candidates = [System.Collections.Generic.List[string]]::new()
    $recorded = Get-InstallPrefix $State
    if ($recorded) { $candidates.Add($recorded) }
    $current = Get-CurrentNpmPrefix
    if ($current) { $candidates.Add($current) }
    foreach ($root in @(
        "$env:USERPROFILE\.fnm",
        "$env:LOCALAPPDATA\fnm",
        "$env:APPDATA\fnm",
        "$env:USERPROFILE\.npm-global"
    )) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -LiteralPath $root -Filter package.json -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]node_modules[\\/]@anthropic-ai[\\/]claude-code[\\/]package\.json$' } |
            ForEach-Object {
                $prefix = $_.Directory.Parent.Parent.Parent.FullName
                if ($prefix) { $candidates.Add($prefix) }
            }
    }
    return @($candidates | Where-Object { $_ } | Select-Object -Unique)
}

function Remove-ClaudePackage {
    param($State)
    [void](Initialize-NodeRuntime)
    if (-not (need_cmd npm)) { throw "未检测到 npm，无法卸载 Claude Code。" }
    foreach ($prefix in Get-NpmPrefixCandidates $State) {
        info "卸载 Claude Code npm 包（prefix: $prefix）"
        Invoke-NpmAtPrefix $prefix @("uninstall", "-g", $CLAUDE_NPM_PACKAGE_NAME)
    }
}

function Restore-PackageAndDefaults {
    param($State)
    if (-not $State) { warn "缺少安装状态，将保留 npm 包并只清理配置。"; return }
    $prefix = Get-InstallPrefix $State
    if ($State.npm.packageBeforeKnown -eq $true) {
        [void](Initialize-NodeRuntime)
        if (-not (need_cmd npm)) { throw "未检测到 npm，无法恢复 Claude Code 包；安装状态将保留。" }
        $currentVersion = Get-PackageVersionAtPrefix $prefix
        if ($State.npm.installedVersion -and $currentVersion -ne [string]$State.npm.installedVersion) {
            warn "当前 Claude Code 版本已被修改（$(if ($currentVersion) {$currentVersion} else {'未安装'})），将保留。"
        } elseif ($State.npm.packageBeforePresent -and $State.npm.packageBeforeVersion) {
            info "恢复 Claude Code npm 版本：$($State.npm.packageBeforeVersion)"
            Invoke-NpmAtPrefix $prefix @("install", "-g", "$CLAUDE_NPM_PACKAGE_NAME@$($State.npm.packageBeforeVersion)")
        } else {
            Invoke-NpmAtPrefix $prefix @("uninstall", "-g", $CLAUDE_NPM_PACKAGE_NAME)
        }
    } else {
        warn "安装前 npm 包状态未知，将保留当前 Claude Code。"
    }
    if ($State.npm.prefixChanged -and $State.npm.prefixBefore) {
        [void](Initialize-NodeRuntime)
        if (-not (need_cmd npm)) { throw "未检测到 npm，无法恢复 npm prefix；安装状态将保留。" }
        $currentPrefix = Get-CurrentNpmPrefix
        if ($currentPrefix -eq $prefix) { & npm config set prefix ([string]$State.npm.prefixBefore); success "已恢复 npm prefix：$($State.npm.prefixBefore)" }
        else { warn "npm prefix 已被用户修改，将保留：$currentPrefix" }
    }
    if ($State.runtime.defaultChangedByBootstrap -and $State.runtime.defaultBeforeKnown -and (need_cmd fnm)) {
        if ($State.runtime.defaultBefore) { & fnm default ([string]$State.runtime.defaultBefore) }
        else { & fnm unalias default }
        if ($LASTEXITCODE -ne 0) { throw "无法恢复 fnm 默认 Node 设置；安装状态将保留。" }
    }
}

function Test-RuntimeHasUntrackedContent {
    param($State)
    [void](Initialize-NodeRuntime)
    $versions = if (need_cmd fnm) { ((& fnm list 2>$null) -join "`n") } else { "" }
    $managedVersions = @()
    foreach ($line in ($versions -split "`r?`n")) {
        if ($line -match 'v?(\d+)\.') {
            $managedVersions += $line
            if ($Matches[1] -ne "22") { warn "检测到额外 Node 版本：$line"; return $true }
        }
    }
    if ($managedVersions.Count -gt 1) { warn "检测到多个 Node 22 版本，无法确认归属。"; return $true }
    $expectedInventory = Get-PropertyValue $State.runtime "inventoryAfter"
    $nodeRoot = Get-PropertyValue $State.runtime "nodeRootAfter"
    $currentInventory = Get-NodeRuntimeInventoryHash ([string]$nodeRoot)
    if (-not $expectedInventory -or -not $currentInventory -or $expectedInventory -ne $currentInventory) {
        warn "Node 运行时目录内容与安装完成时的清单不一致。"
        return $true
    }
    if (need_cmd npm) {
        $json = (& npm list -g --depth=0 --json 2>$null) -join "`n"
        try {
            $deps = ($json | ConvertFrom-Json).dependencies
            foreach ($property in $deps.PSObject.Properties) {
                if ($property.Name -notin @("npm", "corepack", $CLAUDE_NPM_PACKAGE_NAME)) {
                    warn "检测到其他全局 npm 包：$($property.Name)"
                    return $true
                }
            }
        } catch { warn "无法确认全局 npm 包，保留运行时。"; return $true }
    }
    return $false
}

function Remove-ScriptRuntime {
    param($State)
    if (-not $State) { warn "缺少安装状态，不清理 Node 运行时。"; return $true }
    $managerOwned = $State.runtime.managerInstalledByBootstrap -eq $true
    $nodeOwned = $State.runtime.node22InstalledByBootstrap -eq $true
    if (-not $managerOwned -and -not $nodeOwned) { warn "没有可确认由脚本安装的 Node 运行时。"; return $true }
    if ((Read-Host -Prompt "请输入 REMOVE NODE RUNTIME 确认清理脚本安装的运行时") -ne "REMOVE NODE RUNTIME") {
        warn "未确认，保留 Node 运行时和安装状态。"; return $false
    }
    if (Test-RuntimeHasUntrackedContent $State) { warn "运行时包含后续新增内容，已保留。"; return $false }
    [void](Initialize-NodeRuntime)
    if ($nodeOwned) {
        if (-not (need_cmd fnm)) { warn "无法加载 fnm，已保留运行时和安装状态。"; return $false }
        & fnm uninstall 22
        if ($LASTEXITCODE -ne 0) { throw "fnm uninstall 22 失败。" }
    }
    if ($managerOwned -and $State.runtime.installMethod -eq "winget" -and (need_cmd winget)) {
        & winget uninstall --id Schniz.fnm --source winget --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw "winget 卸载 fnm 失败。" }
    } elseif ($managerOwned -and $State.runtime.installMethod -eq "official-script") {
        $fnmDir = "$env:USERPROFILE\.fnm"
        $entries = @(Get-ChildItem -LiteralPath $fnmDir -Force -ErrorAction SilentlyContinue)
        $hasUnknown = @($entries | Where-Object { $_.Name -ne "fnm.exe" }).Count -gt 0
        if ($hasUnknown) { warn "fnm 安装目录包含未记录文件，已保留：$fnmDir"; return $false }
        if ((Resolve-Path $fnmDir -ErrorAction SilentlyContinue).Path -eq (Join-Path $env:USERPROFILE ".fnm")) {
            Remove-Item -LiteralPath $fnmDir -Recurse -Force
        } else { warn "fnm 路径无法安全确认，已保留。"; return $false }
    } elseif ($managerOwned) {
        warn "无法确认 fnm 的安装方式，已保留管理器和安装状态。"
        return $false
    } elseif (-not $nodeOwned) {
        warn "无法定位状态中记录的 Node 运行时，已保留安装状态。"
        return $false
    }
    return $true
}

function Remove-ClaudeUserData {
    if (-not (Test-Path $CLAUDE_DATA_DIR)) { info "Claude 用户数据目录不存在：$CLAUDE_DATA_DIR"; return }
    $size = (Get-ChildItem $CLAUDE_DATA_DIR -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    warn "将永久删除 Claude 用户数据：$CLAUDE_DATA_DIR（约 $size 字节）"
    if ((Read-Host -Prompt "请输入 DELETE CLAUDE DATA 确认") -ne "DELETE CLAUDE DATA") { warn "未确认，保留 Claude 用户数据。"; return }
    $expected = Join-Path $env:USERPROFILE ".claude"
    if ((Resolve-Path $CLAUDE_DATA_DIR).Path -ne (Resolve-Path $expected).Path) { throw "用户数据路径校验失败。" }
    Remove-Item -LiteralPath $CLAUDE_DATA_DIR -Recurse -Force
    success "已删除 Claude 用户数据。"
}

function Show-Plan {
    param([string]$Mode, [bool]$CleanRuntime, [bool]$DeleteData, $EnvInfo, $State)
    Write-SafeHost "`n============================================================" Cyan
    Write-SafeHost "Claude Bootstrap 卸载预览" Cyan
    Write-SafeHost "============================================================" Cyan
    Show-ConfigPreview $EnvInfo $State
    if ($Mode -eq "restore") { Write-SafeHost "[恢复] npm 包、npm prefix 和默认 Node（仅限归属可确认且当前值未修改）" }
    elseif ($Mode -eq "full") {
        foreach ($prefix in Get-NpmPrefixCandidates $State) {
            $version = Get-PackageVersionAtPrefix $prefix
            Write-SafeHost "[删除] npm Claude Code：$(if ($version) {$version} else {'未检测到'})（prefix: $prefix）"
        }
    }
    if ($CleanRuntime) { Write-SafeHost "[高级] 清理状态确认属于脚本的 Node 运行时" }
    if ($DeleteData) { Write-SafeHost "[危险] 删除全部 Claude 用户数据：$CLAUDE_DATA_DIR" }
    Write-SafeHost "============================================================`n" Cyan
}

function Report-UnknownClaude {
    $command = Get-Command claude -ErrorAction SilentlyContinue
    if ($command -and $command.Source -ne $CLAUDE_WRAPPER) { warn "仍检测到其他渠道的 claude 命令，未自动删除：$($command.Source)" }
}

function Invoke-UninstallMode {
    param([string]$Mode, [bool]$CleanRuntime, [bool]$DeleteData)
    $envInfo = Get-ManagedEnvValues
    $state = Get-InstallState
    Show-Plan $Mode $CleanRuntime $DeleteData $envInfo $state
    if ($Mode -eq "preview") { return }
    if (-not (confirm "确认执行以上操作？")) { info "已取消。"; return }
    if ($Mode -eq "restore") { Restore-PackageAndDefaults $state }
    elseif ($Mode -eq "full") { Remove-ClaudePackage $state }
    if ($CleanRuntime -and -not (Remove-ScriptRuntime $state)) { throw "Node 运行时未清理，安装状态已保留。" }
    Remove-BootstrapConfig $envInfo $state
    if ($DeleteData) { Remove-ClaudeUserData }
    Report-UnknownClaude
    success "卸载操作完成。请重新打开终端使环境变化完全生效。"
}

function Show-AdvancedMenu {
    Write-SafeHost "`n高级清理："
    Write-SafeHost "  1) 完整卸载并清理脚本安装的 Node 运行时"
    Write-SafeHost "  2) 完整卸载并删除全部 Claude 用户数据"
    Write-SafeHost "  3) 完整卸载、清理运行时并删除用户数据"
    Write-SafeHost "  4) 返回"
    switch ((Read-Host -Prompt "请输入编号 [4]")) {
        "1" { Invoke-UninstallMode "full" $true $false }
        "2" { Invoke-UninstallMode "full" $false $true }
        "3" { Invoke-UninstallMode "full" $true $true }
        default { Show-MainMenu }
    }
}

function Show-MainMenu {
    Write-SafeHost "`n请选择操作："
    Write-SafeHost "  1) 预览将要清理的内容"
    Write-SafeHost "  2) 仅撤销 claude-bootstrap 配置 [默认]"
    Write-SafeHost "  3) 恢复安装前状态"
    Write-SafeHost "  4) 彻底卸载 Claude Code"
    Write-SafeHost "  5) 高级清理"
    Write-SafeHost "  6) 退出"
    $choice = Read-Host -Prompt "请输入编号 [2]"
    switch ($(if ($choice) { $choice } else { "2" })) {
        "1" { Invoke-UninstallMode "preview" $false $false }
        "2" { Invoke-UninstallMode "config" $false $false }
        "3" { Invoke-UninstallMode "restore" $false $false }
        "4" { Invoke-UninstallMode "full" $false $false }
        "5" { Show-AdvancedMenu }
        "6" { info "已退出。" }
        default { fatal "无效选择：$choice" }
    }
}

function Main {
    $mainModes = @($Preview, $ConfigOnly, $Restore, $Full) | Where-Object { $_ }
    if ($mainModes.Count -gt 1) { fatal "只能选择一种主操作。" }
    if (($Runtime -or $PurgeData) -and -not $Full) { fatal "-Runtime 和 -PurgeData 必须与 -Full 一起使用。" }
    if ($Preview) { Invoke-UninstallMode "preview" $false $false }
    elseif ($ConfigOnly) { Invoke-UninstallMode "config" $false $false }
    elseif ($Restore) { Invoke-UninstallMode "restore" $false $false }
    elseif ($Full) { Invoke-UninstallMode "full" ([bool]$Runtime) ([bool]$PurgeData) }
    else { Show-MainMenu }
}

Main
