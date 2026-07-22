# Claude Code Bootstrap for Windows v1.2
# Target: Windows 10+ / Windows Server 2019+
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# Or:
#   $env:BOOTSTRAP_BASE_URL="https://your-gateway.example.com"; powershell -ExecutionPolicy Bypass -File install.ps1

#Requires -Version 5.1

# Self-healing UTF-8 encoding for Windows PowerShell 5.1
# -File: PS 5.1 reads source as ANSI (Chinese garbled); we re-read as UTF-8
# irm|iex: $MyInvocation is empty, so this block is skipped (content is already correct)
if ($PSVersionTable.PSVersion.Major -le 5 -and $MyInvocation.MyCommand.Path -and $env:_CLBS_RERUN -ne '1') {
    $bytes = [System.IO.File]::ReadAllBytes($MyInvocation.MyCommand.Path)
    if ($bytes.Length -gt 0 -and $bytes[0] -ne 0xEF) {
        $env:_CLBS_RERUN = '1'
        $scriptBlock = [ScriptBlock]::Create([System.Text.Encoding]::UTF8.GetString($bytes))
        & $scriptBlock @args
        Remove-Item env:_CLBS_RERUN -ErrorAction SilentlyContinue
        exit
    }
}

$ErrorActionPreference = "Stop"

#######################################
# Defaults. Adjust these as needed.
#######################################
$BOOTSTRAP_BASE_URL         = if (Test-Path env:BOOTSTRAP_BASE_URL) { $env:BOOTSTRAP_BASE_URL } else { "" }
$DEFAULT_AUTH_MODE          = if (Test-Path env:DEFAULT_AUTH_MODE) { $env:DEFAULT_AUTH_MODE } else { "auth_token" }
$CREATE_CLAUDE_WRAPPER      = if (Test-Path env:CREATE_CLAUDE_WRAPPER) { $env:CREATE_CLAUDE_WRAPPER } else { "1" }
$ENABLE_GATEWAY_MODEL_DISCOVERY = if (Test-Path env:ENABLE_GATEWAY_MODEL_DISCOVERY) { $env:ENABLE_GATEWAY_MODEL_DISCOVERY } else { "1" }
$CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT = if (Test-Path env:CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT) { $env:CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT } else { "0" }
$REQUIRED_NODE_MAJOR        = if (Test-Path env:REQUIRED_NODE_MAJOR) { $env:REQUIRED_NODE_MAJOR } else { "22" }
$NODE_DIST_MIRROR_FALLBACK  = if ((Test-Path env:NODE_DIST_MIRROR_FALLBACK) -and -not [string]::IsNullOrWhiteSpace($env:NODE_DIST_MIRROR_FALLBACK)) { $env:NODE_DIST_MIRROR_FALLBACK } else { "https://npmmirror.com/mirrors/node" }
$CLAUDE_CODE_TARGET_VERSION = "2.1.142"
$CLAUDE_NPM_PACKAGE_NAME    = "@anthropic-ai/claude-code"
$CLAUDE_NPM_PACKAGE         = "@anthropic-ai/claude-code@$CLAUDE_CODE_TARGET_VERSION"
$MODEL_MENU_MAX_DISPLAY     = if (Test-Path env:MODEL_MENU_MAX_DISPLAY) { [int]$env:MODEL_MENU_MAX_DISPLAY } else { 30 }
$DYNAMIC_MODEL_DISCOVERY    = if (Test-Path env:DYNAMIC_MODEL_DISCOVERY) { $env:DYNAMIC_MODEL_DISCOVERY } else { "1" }

# Fallback model menu. Runtime will prefer models returned by $ANTHROPIC_BASE_URL/v1/models.
$MODELS = @(
    "claude-sonnet-4-5"
    "claude-opus-4-1"
    "claude-haiku-4-5"
    "qwen3-coder"
    "deepseek-v3.1"
    "kimi-k2"
)
$DEFAULT_MODEL_INDEX = 1
$SCRIPT:MODEL_MENU = @()
$SCRIPT:AVAILABLE_MODELS = @()

$CONFIG_DIR         = "$env:USERPROFILE\.claude-bootstrap"
$ENV_FILE           = "$CONFIG_DIR\env.ps1"
$WRAPPER_DIR        = "$CONFIG_DIR\bin"
$CLAUDE_WRAPPER     = "$WRAPPER_DIR\claude.cmd"
$CLAUDE_SETTINGS_JSON = "$env:USERPROFILE\.claude\settings.json"
$INSTALL_STATE_FILE = "$CONFIG_DIR\install-state.json"
$PROFILE_MARKER_BEGIN = "# >>> claude-bootstrap >>>"
$PROFILE_MARKER_END   = "# <<< claude-bootstrap <<<"

# ----- helpers -----------------------------------------------------------
function Write-SafeHost {
    param(
        [AllowNull()][string]$Text = "",
        [AllowNull()][object]$ForegroundColor = $null
    )

    try {
        if ($null -ne $ForegroundColor) {
            Microsoft.PowerShell.Utility\Write-Host $Text -ForegroundColor $ForegroundColor
        } else {
            Microsoft.PowerShell.Utility\Write-Host $Text
        }
    } catch {
        [Console]::Out.WriteLine($Text)
    }
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
function Set-PrivateFileAcl {
    param([string]$Path)
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
    [void]$acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-LogLine {
    param(
        [string]$Prefix,
        [ConsoleColor]$Color,
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Message
    )

    $text = ($Message | ForEach-Object {
        if ($null -eq $_) { "" } else { [string]$_ }
    }) -join " "
    Write-SafeHost "$Prefix$text" $Color
}

function ConvertTo-PowerShellSingleQuotedString {
    param([AllowNull()][string]$Value)
    return "'" + (($Value -replace "'", "''")) + "'"
}

function Get-StringSha256 {
    param([AllowNull()][string]$Value)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($(if ($null -eq $Value) { "" } else { $Value }))
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
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

function Get-InstallState {
    if (-not (Test-Path $INSTALL_STATE_FILE)) { return $null }
    try {
        $state = Get-Content $INSTALL_STATE_FILE -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($state.owner -eq "claude-bootstrap" -and $state.schemaVersion -eq 1) { return $state }
    } catch {
        warn "安装状态文件无效，将按旧安装保守处理：$INSTALL_STATE_FILE"
        return $null
    }
}

function Save-InstallState {
    param([Parameter(Mandatory = $true)]$State)
    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null
    $tmp = "$INSTALL_STATE_FILE.tmp.$PID"
    Write-Utf8NoBomFile $tmp (($State | ConvertTo-Json -Depth 12) + "`n")
    Move-Item -LiteralPath $tmp -Destination $INSTALL_STATE_FILE -Force
    Set-PrivateFileAcl $INSTALL_STATE_FILE
}

function New-ManagedSettingState {
    param($EnvObject, [string]$Name, [bool]$Known, [switch]$Secret)
    $present = $false
    $value = $null
    if ($Known -and $EnvObject) {
        $property = $EnvObject.PSObject.Properties[$Name]
        if ($property) {
            $present = $true
            if (-not $Secret) { $value = $property.Value }
        }
    }
    $entry = [ordered]@{ originalKnown = $Known; originalPresent = $(if ($Known) { $present } else { $null }) }
    if ($Secret) { $entry.secret = $true }
    elseif ($present) { $entry.originalValue = $value }
    return $entry
}

function Initialize-InstallState {
    if (Test-Path $INSTALL_STATE_FILE) {
        if (-not (Get-InstallState)) { fatal "已有安装状态文件无效或版本不受支持，请先检查：$INSTALL_STATE_FILE" }
        return
    }

    $adopted = Test-Path $ENV_FILE
    $settingsExisted = Test-Path $CLAUDE_SETTINGS_JSON
    $settingsValid = $true
    $settings = $null
    if ($settingsExisted) {
        try { $settings = Get-Content $CLAUDE_SETTINGS_JSON -Raw | ConvertFrom-Json }
        catch { $settingsValid = $false }
    }
    $known = (-not $adopted) -and $settingsValid
    $settingsEnv = if ($settings -and $settings.env) { $settings.env } else { [pscustomobject]@{} }
    $managed = [ordered]@{}
    foreach ($name in @(
        "ANTHROPIC_BASE_URL", "ANTHROPIC_MODEL", "ANTHROPIC_CUSTOM_MODEL_OPTION",
        "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB", "DISABLE_UPDATES"
    )) {
        $managed[$name] = New-ManagedSettingState $settingsEnv $name $known
    }
    foreach ($name in @("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY")) {
        $managed[$name] = New-ManagedSettingState $settingsEnv $name $known -Secret
    }

    $skipEntry = [ordered]@{ originalKnown = $known; originalPresent = $null }
    if ($known) {
        $skipProperty = if ($settings) { $settings.PSObject.Properties["skipWebFetchPreflight"] } else { $null }
        $skipEntry.originalPresent = $null -ne $skipProperty
        if ($skipProperty) { $skipEntry.originalValue = $skipProperty.Value }
    }

    $fnmBefore = Load-Fnm
    $node22Before = $false
    if ($fnmBefore) {
        $node22Before = ((& fnm list 2>$null) -join "`n") -match '(?m)\bv?22\.'
    }
    $nodeBefore = if (need_cmd node) { (& node -v 2>$null) -join "" } else { $null }
    $defaultBefore = Get-FnmDefaultVersion
    $prefixBefore = if (need_cmd npm) { Get-NpmGlobalBin } else { $null }
    $packageVersion = if (need_cmd npm) { Get-InstalledClaudeNpmVersion } else { "" }

    $state = [ordered]@{
        schemaVersion = 1
        owner = "claude-bootstrap"
        platform = "windows"
        adoptedExistingInstall = $adopted
        profile = [ordered]@{ path = $null; existedBefore = $null }
        settings = [ordered]@{
            path = $CLAUDE_SETTINGS_JSON
            existedBefore = $settingsExisted
            validBefore = $settingsValid
            managed = $managed
            skipWebFetchPreflight = $skipEntry
        }
        npm = [ordered]@{
            prefixBefore = $prefixBefore
            prefixChanged = $false
            installPrefix = $null
            packageBeforeKnown = -not $adopted
            packageBeforePresent = $(if ($adopted) { $null } else { -not [string]::IsNullOrEmpty($packageVersion) })
            packageBeforeVersion = $(if ($adopted -or [string]::IsNullOrEmpty($packageVersion)) { $null } else { $packageVersion })
            installedVersion = $null
        }
        runtime = [ordered]@{
            manager = "fnm"
            managerExistedBefore = $(if ($adopted) { $null } else { $fnmBefore })
            managerInstalledByBootstrap = $false
            installMethod = $null
            node22ExistedBefore = $(if ($adopted) { $null } else { $node22Before })
                node22InstalledByBootstrap = $false
                nodeVersionBefore = $(if ($adopted) { $null } else { $nodeBefore })
                defaultBeforeKnown = -not $adopted
                defaultBefore = $(if ($adopted) { $null } else { $defaultBefore })
            defaultChangedByBootstrap = $false
        }
    }
    Save-InstallState $state
}

function Update-InstallRuntimeState {
    $state = Get-InstallState
    if (-not $state) { return }
    $prefix = if (need_cmd npm) { Get-NpmGlobalBin } else { $null }
    $version = if (need_cmd npm) { Get-InstalledClaudeNpmVersion } else { "" }
    $fnmNow = Load-Fnm
    $node22Now = $false
    if ($fnmNow) { $node22Now = ((& fnm list 2>$null) -join "`n") -match '(?m)\bv?22\.' }
    $defaultAfter = Get-FnmDefaultVersion
    $nodeRoot = Get-FnmNodeRoot
    $state.npm.installPrefix = $prefix
    $state.npm.installedVersion = $(if ($version) { $version } else { $null })
    $state.npm.prefixChanged = [bool]($state.npm.prefixBefore -and $prefix -and $state.npm.prefixBefore -ne $prefix)
    if ($null -eq $state.runtime.PSObject.Properties["nodeRootAfter"] -or -not $state.runtime.nodeRootAfter) {
        $state.runtime | Add-Member -NotePropertyName nodeRootAfter -NotePropertyValue $nodeRoot -Force
    }
    if ($null -eq $state.runtime.PSObject.Properties["inventoryAfter"] -or -not $state.runtime.inventoryAfter) {
        $state.runtime | Add-Member -NotePropertyName inventoryAfter -NotePropertyValue (Get-NodeRuntimeInventoryHash $nodeRoot) -Force
    }
    $state.runtime.managerInstalledByBootstrap = [bool]($state.runtime.managerExistedBefore -eq $false -and $fnmNow)
    if ($state.runtime.managerInstalledByBootstrap -and $global:FNM_INSTALL_METHOD -and -not $state.runtime.installMethod) {
        $state.runtime.installMethod = $global:FNM_INSTALL_METHOD
    }
    $state.runtime.node22InstalledByBootstrap = [bool]($state.runtime.node22ExistedBefore -eq $false -and $node22Now)
    $state.runtime | Add-Member -NotePropertyName defaultAfter -NotePropertyValue $defaultAfter -Force
    $state.runtime.defaultChangedByBootstrap = [bool]($state.runtime.defaultBeforeKnown -and $defaultAfter -and $state.runtime.defaultBefore -ne $defaultAfter)
    Save-InstallState $state
}

function Update-InstallProfileState {
    param([string]$Path, [bool]$ExistedBefore)
    $state = Get-InstallState
    if (-not $state) { return }
    if (-not $state.profile.path) { $state.profile.path = $Path }
    if ($null -eq $state.profile.existedBefore) { $state.profile.existedBefore = $ExistedBefore }
    Save-InstallState $state
}

function Update-InstallSettingsState {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret, [string]$Model)
    $state = Get-InstallState
    if (-not $state) { return }
    $values = [ordered]@{
        ANTHROPIC_BASE_URL = $BaseUrl
        ANTHROPIC_MODEL = $Model
        ANTHROPIC_CUSTOM_MODEL_OPTION = $Model
        CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = $ENABLE_GATEWAY_MODEL_DISCOVERY
        CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = $CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT
        DISABLE_UPDATES = "1"
    }
    foreach ($entry in $values.GetEnumerator()) {
        $state.settings.managed.PSObject.Properties[$entry.Key].Value | Add-Member -NotePropertyName writtenValue -NotePropertyValue $entry.Value -Force
    }
    $authKey = if ($AuthMode -eq "api_key") { "ANTHROPIC_API_KEY" } else { "ANTHROPIC_AUTH_TOKEN" }
    $otherKey = if ($authKey -eq "ANTHROPIC_API_KEY") { "ANTHROPIC_AUTH_TOKEN" } else { "ANTHROPIC_API_KEY" }
    $state.settings.managed.PSObject.Properties[$authKey].Value | Add-Member -NotePropertyName writtenHash -NotePropertyValue (Get-StringSha256 $Secret) -Force
    $state.settings.managed.PSObject.Properties[$otherKey].Value | Add-Member -NotePropertyName deletedByBootstrap -NotePropertyValue $true -Force
    $state.settings.skipWebFetchPreflight | Add-Member -NotePropertyName writtenValue -NotePropertyValue $true -Force
    Save-InstallState $state
}

function Update-InstallModelState {
    param([string]$Model)
    $state = Get-InstallState
    if (-not $state) { return }
    foreach ($name in @("ANTHROPIC_MODEL", "ANTHROPIC_CUSTOM_MODEL_OPTION")) {
        $state.settings.managed.PSObject.Properties[$name].Value | Add-Member -NotePropertyName writtenValue -NotePropertyValue $Model -Force
    }
    Save-InstallState $state
}

function info    { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-LogLine "[INFO]  " Blue @Message }
function success { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-LogLine "[OK]    " Green @Message }
function warn    { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-LogLine "[WARN]  " Yellow @Message }
function fatal   { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Message) Write-LogLine "[ERROR] " Red @Message; exit 1 }

function need_cmd {
    param([string]$Name)
    return (Get-Command $Name -ErrorAction SilentlyContinue) -ne $null
}

function confirm {
    param(
        [string]$Prompt,
        [string]$Default = "Y"
    )
    if ($Default -eq "Y") {
        $reply = Read-Host -Prompt "$Prompt [Y/n]"
        return [string]::IsNullOrEmpty($reply) -or $reply -match '^[Yy]'
    } else {
        $reply = Read-Host -Prompt "$Prompt [y/N]"
        return $reply -match '^[Yy]'
    }
}

function Read-Secret {
    param([string]$Prompt)
    while ($true) {
        $secure1 = Read-Host -Prompt $Prompt -AsSecureString
        $ptr1 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure1)
        try   { $value1 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr1) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr1) }
        if ([string]::IsNullOrEmpty($value1)) {
            warn "API Key / Auth Token 不能为空。"
            continue
        }
        $secure2 = Read-Host -Prompt "请再次输入确认：" -AsSecureString
        $ptr2 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure2)
        try   { $value2 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr2) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr2) }
        if ($value1 -ne $value2) {
            warn "两次输入不一致，请重新输入。"
            continue
        }
        return $value1
    }
}

$global:arch = ""
$global:FNM_INSTALL_METHOD = $null

# ----- platform -----------------------------------------------------------
function Test-Platform {
    if ($env:OS -ne "Windows_NT") {
        fatal "当前脚本只支持 Windows。"
    }

    switch -Regex ([System.Environment]::OSVersion.Version.Major) {
        { $_ -ge 10 } { break }        # Windows 10/11, Server 2019/2022
        default       { warn "当前 Windows 版本较旧，Claude Code 仅官方支持 Windows 10+。脚本会继续。" }
    }

    switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { $global:arch = "x64" }
        "ARM64" { $global:arch = "arm64" }
        default {
            if ([Environment]::Is64BitOperatingSystem) { $global:arch = "x64" }
            else { fatal "不支持的 CPU 架构。Claude Code 需要 x64 或 ARM64。" }
        }
    }

    success "检测到系统：Windows / $($global:arch)"
}

# ----- memory -------------------------------------------------------------
function Test-Memory {
    try {
        $totalMemBytes = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
    } catch {
        try {
            $totalMemBytes = (Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory
        } catch {
            warn "无法获取内存信息，跳过内存检查。"
            return
        }
    }
    $memMB = [math]::Floor($totalMemBytes / 1MB)
    if ($memMB -lt 4096) {
        warn "当前内存约 ${memMB}MB，Claude Code 官方建议至少 4GB RAM。脚本会继续。"
    }
}

# ----- admin --------------------------------------------------------------
# On Windows, winget can install user-scope packages without admin.
# We detect admin status and prefer machine-scope only when already elevated.
$global:isAdmin = $false
function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $global:isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($global:isAdmin) {
        warn "当前以管理员身份运行。如非必要，建议以普通用户身份运行以使用用户级安装。"
    } else {
        success "以普通用户身份运行，将使用用户级安装（无需管理员权限）。"
    }
}

# ----- basic deps ---------------------------------------------------------
function Install-BasicDeps {
    # git 是最关键的基础依赖
    $missing = @()
    if (-not (need_cmd git)) { $missing += "Git.Git" }

    if ($missing.Count -eq 0) {
        return
    }

    info "准备安装基础依赖：$($missing -join ', ')"

    # Check for winget
    if (need_cmd winget) {
        foreach ($pkg in $missing) {
            info "winget install $pkg"
            winget install --id $pkg --source winget --accept-source-agreements --accept-package-agreements
        }
        # Refresh PATH after winget installs (winget may have updated system/user PATH)
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        # Winget can be slow; give it a moment and verify
        $stillMissing = @()
        if (-not (need_cmd git)) { $stillMissing += "git" }
        if ($stillMissing.Count -gt 0) {
            warn "winget 安装后仍无法找到：$($stillMissing -join ', ')。请手动安装后重新运行脚本。"
            warn "Git 下载地址：https://git-scm.com/download/win"
            exit 1
        }
        success "基础依赖已就绪"
    } else {
        fatal "未检测到 winget。请手动安装以下依赖后重新运行脚本：$($missing -join ', ')。Git 下载地址：https://git-scm.com/download/win"
    }
}

# ----- fnm (Fast Node Manager, nvm equivalent on Windows) ------------------
function Load-Fnm {
    $fnmExe = "$env:LOCALAPPDATA\fnm\fnm.exe"
    if (-not (Test-Path $fnmExe)) {
        $fnmExe = "$env:APPDATA\fnm\fnm.exe"
    }
    if (-not (Test-Path $fnmExe)) {
        $fnmExe = "$env:USERPROFILE\.fnm\fnm.exe"
    }
    if (Test-Path $fnmExe) {
        # Ensure fnm's directory is on PATH
        $fnmDir = Split-Path $fnmExe -Parent
        if ($env:Path -notlike "*$fnmDir*") {
            $env:Path = "$fnmDir;$env:Path"
        }
        return $true
    }
    return $false
}

function Get-FnmDefaultVersion {
    if (-not (Load-Fnm)) { return $null }
    $value = ((& fnm default 2>$null) -join "").Trim()
    if ($LASTEXITCODE -eq 0 -and $value -match 'v?(\d+(?:\.\d+){0,2})') { return $Matches[1] }
    return $null
}

function Get-FnmNodeRoot {
    if (-not (Load-Fnm)) { return $null }
    $candidate = ((& fnm exec "--using=$REQUIRED_NODE_MAJOR" node "-p" "process.execPath" 2>$null) -join "").Trim().Trim('"')
    if ($LASTEXITCODE -ne 0 -or -not $candidate -or -not (Test-Path $candidate)) { return $null }
    if (Test-Path $candidate -PathType Leaf) { return Split-Path $candidate -Parent }
    return $candidate
}

function Install-Fnm {
    if (Load-Fnm) {
        return
    }

    info "安装 fnm (Fast Node Manager)"
    if (need_cmd winget) {
        $global:FNM_INSTALL_METHOD = "winget"
        winget install --id Schniz.fnm --source winget --accept-source-agreements --accept-package-agreements
        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        $global:FNM_INSTALL_METHOD = "official-script"
        # Fallback: direct download via PowerShell
        info "通过 fnm 官方脚本安装"
        $installScript = "$env:TEMP\fnm-install.ps1"
        Invoke-WebRequest -Uri "https://fnm.vercel.app/install" -OutFile $installScript -UseBasicParsing
        & $installScript --install-dir "$env:USERPROFILE\.fnm" --skip-shell
        Remove-Item $installScript -Force -ErrorAction SilentlyContinue
        $env:Path = "$env:USERPROFILE\.fnm;$env:Path"
    }

    if (-not (Load-Fnm)) {
        fatal "fnm 安装后仍无法加载，请重新打开终端后重试。"
    }
    success "fnm 安装完成"
}

# ----- Node.js 22 via fnm -------------------------------------------------
function Get-NodeMajor {
    $ver = (& node -v 2>$null) -replace '^v(\d+).*', '$1'
    return $ver
}

function Test-NodeDistMirror {
    param([string]$Mirror)
    $indexUrl = "$($Mirror.TrimEnd('/'))/index.tab"
    try {
        Invoke-WebRequest -Uri $indexUrl -Headers @{ Range = "bytes=0-0" } -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Select-FnmNodeDistMirror {
    $officialMirror = "https://nodejs.org/dist"
    $fallbackMirror = $NODE_DIST_MIRROR_FALLBACK.TrimEnd('/')

    if ((Test-Path env:FNM_NODE_DIST_MIRROR) -and -not [string]::IsNullOrWhiteSpace($env:FNM_NODE_DIST_MIRROR)) {
        $env:FNM_NODE_DIST_MIRROR = $env:FNM_NODE_DIST_MIRROR.TrimEnd('/')
        info "使用用户指定的 Node.js 下载源：$env:FNM_NODE_DIST_MIRROR"
        return
    }

    info "检测 Node.js 官方下载源：$officialMirror"
    if (Test-NodeDistMirror $officialMirror) {
        $env:FNM_NODE_DIST_MIRROR = $officialMirror
        info "Node.js 官方下载源可用。"
        return
    }

    warn "Node.js 官方下载源不可用，尝试国内镜像：$fallbackMirror"
    if (Test-NodeDistMirror $fallbackMirror) {
        $env:FNM_NODE_DIST_MIRROR = $fallbackMirror
        success "已切换 Node.js 下载源：$env:FNM_NODE_DIST_MIRROR"
        return
    }

    $env:FNM_NODE_DIST_MIRROR = $officialMirror
    warn "官方源和国内镜像均未通过连通性检测，将继续尝试官方源并保留 fnm 的详细错误输出。"
}

function Install-NodeWithMirrorFallback {
    $userMirror = if ((Test-Path env:FNM_NODE_DIST_MIRROR) -and -not [string]::IsNullOrWhiteSpace($env:FNM_NODE_DIST_MIRROR)) { $env:FNM_NODE_DIST_MIRROR } else { "" }
    $fallbackMirror = $NODE_DIST_MIRROR_FALLBACK.TrimEnd('/')

    Select-FnmNodeDistMirror
    & fnm install $REQUIRED_NODE_MAJOR
    if ($LASTEXITCODE -eq 0) { return }

    if (-not $userMirror -and $env:FNM_NODE_DIST_MIRROR.TrimEnd('/') -ne $fallbackMirror) {
        warn "当前 Node.js 下载源安装失败，尝试国内镜像：$fallbackMirror"
        if (Test-NodeDistMirror $fallbackMirror) {
            $env:FNM_NODE_DIST_MIRROR = $fallbackMirror
            & fnm install $REQUIRED_NODE_MAJOR
            if ($LASTEXITCODE -eq 0) { return }
        }
    }

    fatal "fnm install $REQUIRED_NODE_MAJOR 失败。请查看上方 fnm 输出。"
}

function Enable-Node22 {
    $currentMajor = ""
    if (need_cmd node) {
        $currentMajor = Get-NodeMajor
        info "检测到 Node.js：$(node -v)"
        if ($currentMajor -eq $REQUIRED_NODE_MAJOR) {
            success "Node.js $REQUIRED_NODE_MAJOR 已安装"
            return
        }
        if ([int]$currentMajor -gt [int]$REQUIRED_NODE_MAJOR) {
            if (confirm "检测到 Node.js $(node -v)，高于目标版本 ${REQUIRED_NODE_MAJOR}，是否继续使用当前版本？" "Y") {
                return
            }
        } elseif ([int]$currentMajor -ge 18) {
            if (-not (confirm "检测到 Node.js $(node -v)，Claude Code 可用但不是 ${REQUIRED_NODE_MAJOR}，是否安装/切换到 Node.js ${REQUIRED_NODE_MAJOR}？" "Y")) {
                return
            }
        } else {
            warn "当前 Node.js $(node -v) 低于 Claude Code npm 包要求的 Node.js 18，将安装 Node.js ${REQUIRED_NODE_MAJOR}。"
        }
    } else {
        info "未检测到 Node.js，将安装 Node.js ${REQUIRED_NODE_MAJOR}。"
    }

    Install-Fnm
    info "通过 fnm 安装 Node.js $REQUIRED_NODE_MAJOR"
    Install-NodeWithMirrorFallback
    fnm default $REQUIRED_NODE_MAJOR
    fnm use $REQUIRED_NODE_MAJOR
    success "Node.js 已就绪：$(node -v)，npm：$(npm -v)"
}

# ----- npm global path -----------------------------------------------------
function Get-NpmGlobalBin {
    $prefix = (& npm config get prefix 2>$null) -replace '\s+', ''
    if ($prefix -and $prefix -ne "undefined") {
        return $prefix
    }
    return $null
}

function Enable-NpmGlobalPath {
    if (-not (need_cmd npm)) {
        fatal "未检测到 npm。"
    }
    $prefix = Get-NpmGlobalBin
    if (-not $prefix) {
        fatal "无法获取 npm 全局 prefix。"
    }

    # On Windows + fnm, npm global prefix is typically under fnm's node dir (user-writable).
    # If it happens to be in a protected system path, switch to user-level.
    if ($prefix -match '^[A-Z]:\\Program Files' -or $prefix -match '^[A-Z]:\\Program Files \(x86\)') {
        warn "npm 全局目录在系统保护路径：${prefix}。将改为用户级目录 $env:USERPROFILE\.npm-global。"
        $newPrefix = "$env:USERPROFILE\.npm-global"
        New-Item -ItemType Directory -Path $newPrefix -Force | Out-Null
        npm config set prefix $newPrefix
        $env:Path = "$newPrefix;$env:Path"
    } else {
        $env:Path = "$prefix;$env:Path"
    }
}

# ----- find real claude binary --------------------------------------------
function Find-RealClaudeBin {
    # First: check npm global bin
    $npmPrefix = Get-NpmGlobalBin
    if ($npmPrefix) {
        $candidate = Join-Path $npmPrefix "claude.cmd"
        if ((Test-Path $candidate) -and $candidate -ne $CLAUDE_WRAPPER) {
            return $candidate
        }
    }

    # Second: search PATH, but skip our own wrapper
    $pathDirs = $env:Path -split ';'
    foreach ($dir in $pathDirs) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $candidate = Join-Path $dir.Trim() "claude.cmd"
        if ((Test-Path $candidate) -and $candidate -ne $CLAUDE_WRAPPER) {
            $content = Get-Content $candidate -Raw -ErrorAction SilentlyContinue
            if ($content -and $content -notmatch 'CLAUDE_BOOTSTRAP_WRAPPER') {
                return $candidate
            }
        }
    }
    return $null
}

function Clear-ClaudeNpmTempDirs {
    $npmRoot = (& npm root -g 2>$null) -join "`n"
    $npmRoot = $npmRoot.Trim()
    if (-not $npmRoot) { return }

    $scopeDir = Join-Path $npmRoot "@anthropic-ai"
    if (-not (Test-Path $scopeDir)) { return }

    Get-ChildItem -LiteralPath $scopeDir -Force -Directory -Filter ".claude-code-*" -ErrorAction SilentlyContinue | ForEach-Object {
        warn "清理 Claude Code npm 临时目录：$($_.FullName)"
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstalledClaudeNpmVersion {
    $json = (& npm list -g $CLAUDE_NPM_PACKAGE_NAME --depth=0 --json 2>$null) -join "`n"
    if (-not $json) { return "" }

    try {
        $data = $json | ConvertFrom-Json
        if (-not $data.dependencies) { return "" }
        $dep = $data.dependencies.PSObject.Properties[$CLAUDE_NPM_PACKAGE_NAME].Value
        if ($dep -and $dep.version) {
            return [string]$dep.version
        }
    } catch {
        return ""
    }
    return ""
}

function Install-ClaudeNpmPackage {
    Clear-ClaudeNpmTempDirs
    npm install -g $CLAUDE_NPM_PACKAGE
    if ($LASTEXITCODE -eq 0) { return }

    warn "Claude Code npm 安装失败，清理旧包和 npm 临时目录后重试一次。"
    npm uninstall -g $CLAUDE_NPM_PACKAGE_NAME | Out-Null
    Clear-ClaudeNpmTempDirs
    npm install -g $CLAUDE_NPM_PACKAGE
    if ($LASTEXITCODE -ne 0) {
        fatal "Claude Code npm 安装失败，请查看 npm 日志。"
    }
}

# ----- install Claude Code ------------------------------------------------
function Install-ClaudeCode {
    Enable-NpmGlobalPath

    $realClaude = Find-RealClaudeBin
    if ($realClaude) {
        $currentVersion = Get-InstalledClaudeNpmVersion
        if ($currentVersion -eq $CLAUDE_CODE_TARGET_VERSION) {
            success "Claude Code 已安装：$currentVersion (npm)"
            $global:CLAUDE_BOOTSTRAP_REAL_BIN = $realClaude
            return
        }
        if ($currentVersion) {
            warn "Claude Code 版本不匹配：当前 $currentVersion (npm)，目标 $CLAUDE_CODE_TARGET_VERSION，将重新安装。"
        } else {
            warn "Claude Code 已安装但无法从 npm 识别版本，目标 $CLAUDE_CODE_TARGET_VERSION，将重新安装。"
        }
    }

    info "安装 Claude Code：npm install -g $CLAUDE_NPM_PACKAGE"
    Install-ClaudeNpmPackage

    $npmPrefix = Get-NpmGlobalBin
    if ($npmPrefix) {
        $env:Path = "$npmPrefix;$env:Path"
    }

    $realClaude = Find-RealClaudeBin
    if (-not $realClaude) {
        fatal "Claude Code 安装完成，但真实 claude 命令仍不在 PATH。请检查 npm 全局目录：${npmPrefix}。"
    }
    $global:CLAUDE_BOOTSTRAP_REAL_BIN = $realClaude
    $installedVersion = Get-InstalledClaudeNpmVersion
    if ($installedVersion -ne $CLAUDE_CODE_TARGET_VERSION) {
        $displayVersion = $installedVersion
        if (-not $displayVersion) { $displayVersion = "unknown" }
        fatal "Claude Code 安装后版本不符合预期：$displayVersion，目标 $CLAUDE_CODE_TARGET_VERSION。"
    }
    success "Claude Code 安装成功：$installedVersion (npm)"
}

# ----- profile -------------------------------------------------------------
function Select-ProfileFile {
    if (-not (Test-Path $PROFILE)) {
        $profileDir = Split-Path $PROFILE -Parent
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        New-Item -ItemType File -Path $PROFILE -Force | Out-Null
    }
    info "将更新 PowerShell 配置文件：$PROFILE"
    return $PROFILE
}

function Remove-OldProfileBlock {
    param([string]$File)
    if (-not (Test-Path $File)) { return }

    $fileInfo = Get-TextFileInfo $File
    $lines = @([regex]::Split($fileInfo.Text, "`r`n|`n|`r"))
    $beginIndexes = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq $PROFILE_MARKER_BEGIN) { $i } })
    $endIndexes = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq $PROFILE_MARKER_END) { $i } })
    if ($beginIndexes.Count -eq 0 -and $endIndexes.Count -eq 0) { return }
    if ($beginIndexes.Count -ne 1 -or $endIndexes.Count -ne 1 -or $beginIndexes[0] -ge $endIndexes[0]) {
        fatal "PowerShell profile 中的 claude-bootstrap 标记块不完整或重复，请手动修复后重试：$File"
    }
    $result = @()
    $skip = $false
    foreach ($line in $lines) {
        if ($line -eq $PROFILE_MARKER_BEGIN) { $skip = $true; continue }
        if ($line -eq $PROFILE_MARKER_END)   { $skip = $false; continue }
        if (-not $skip) { $result += $line }
    }
    Write-TextFilePreservingEncoding $File ($result -join $fileInfo.NewLine) $fileInfo
}

function Write-ProfileBlock {
    $profileExistedBefore = Test-Path $PROFILE
    $profile = Select-ProfileFile
    Update-InstallProfileState $profile $profileExistedBefore
    Remove-OldProfileBlock $profile

    $npmPrefix = Get-NpmGlobalBin

    $block = @"

$PROFILE_MARKER_BEGIN
`$env:Path = `"`$env:USERPROFILE\.claude-bootstrap\bin;`$env:USERPROFILE\.local\bin;`$env:Path`"
"@
    if ($npmPrefix) {
        $block += @"

`$env:Path = `"$npmPrefix;`$env:Path`"
"@
    }
    # fnm initialization (fnm env --shell powershell equivalent)
    $block += @"

if (Test-Path `"`$env:USERPROFILE\.fnm\fnm.exe`") { & `"`$env:USERPROFILE\.fnm\fnm.exe`" env --shell powershell --use-on-cd | Invoke-Expression }
if (Test-Path `"`$env:LOCALAPPDATA\fnm\fnm.exe`") { & `"`$env:LOCALAPPDATA\fnm\fnm.exe`" env --shell powershell --use-on-cd | Invoke-Expression }
if (Test-Path `"`$env:APPDATA\fnm\fnm.exe`")       { & `"`$env:APPDATA\fnm\fnm.exe`" env --shell powershell --use-on-cd | Invoke-Expression }
if (Test-Path `"`$env:USERPROFILE\.claude-bootstrap\env.ps1`") { . `"`$env:USERPROFILE\.claude-bootstrap\env.ps1`" }
$PROFILE_MARKER_END
"@
    $fileInfo = Get-TextFileInfo $profile
    $normalizedBlock = [regex]::Replace($block, "`r`n|`n|`r", $fileInfo.NewLine)
    Write-TextFilePreservingEncoding $profile ($fileInfo.Text + $normalizedBlock) $fileInfo
    success "已写入启动配置：$profile"
}

# ----- auth / model --------------------------------------------------------
function Read-ApiSecret {
    return Read-Secret "请输入 API Key / Auth Token"
}

function Choose-AuthMode {
    Write-SafeHost ""
    Write-SafeHost "请选择认证变量："
    Write-SafeHost "  1) ANTHROPIC_AUTH_TOKEN  作为 Authorization: Bearer <token> 发送，通常适合内部中转站 [默认]"
    Write-SafeHost "  2) ANTHROPIC_API_KEY     作为 X-Api-Key 发送，通常适合原生 Anthropic API"
    $choice = Read-Host -Prompt "请输入编号 [1]"
    if ([string]::IsNullOrEmpty($choice)) { $choice = "1" }
    switch ($choice) {
        "1" { return "auth_token" }
        "2" { return "api_key" }
        default { warn "无效选择，使用默认 ANTHROPIC_AUTH_TOKEN。"; return "auth_token" }
    }
}

function Fetch-ModelIdsFromGateway {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret)

    if ($DYNAMIC_MODEL_DISCOVERY -ne "1") {
        return $null
    }
    if (-not (need_cmd curl)) {
        warn "未检测到 curl，无法动态拉取模型列表，将使用内置模型列表。"
        return $null
    }
    if (-not (need_cmd node)) {
        warn "未检测到 node，无法解析 /v1/models 响应，将使用内置模型列表。"
        return $null
    }

    $url = "$BaseUrl/v1/models"
    $tmpFile = [System.IO.Path]::GetTempFileName()

    info "拉取真实可用模型列表：GET $url"
    try {
        $headers = @{}
        if ($AuthMode -eq "auth_token") {
            $headers["Authorization"] = "Bearer $Secret"
        } else {
            $headers["X-Api-Key"] = $Secret
        }
        $response = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        [System.IO.File]::WriteAllText($tmpFile, $response.Content, [System.Text.Encoding]::UTF8)
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode) {
            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                warn "/v1/models 返回 HTTP ${statusCode}，认证可能失败，无法拉取模型列表。"
            } elseif ($statusCode -eq 404 -or $statusCode -eq 405) {
                warn "网关可能不支持 /v1/models，无法动态拉取模型列表，将使用内置模型列表。"
            } else {
                warn "/v1/models 返回 HTTP ${statusCode}，无法动态拉取模型列表，将使用内置模型列表。"
            }
        } else {
            warn "模型列表拉取失败，将使用内置模型列表。"
        }
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Parse JSON with Node.js (same JS logic as Linux script)
    $nodeScript = @"
const fs = require('fs');
const file = process.argv[2];
let raw = '';
try {
  raw = fs.readFileSync(file, 'utf8');
} catch {
  process.exit(2);
}
raw = raw.replace(/^\uFEFF/, '');
let json;
try {
  json = JSON.parse(raw);
} catch {
  process.exit(3);
}

function collect(value, out) {
  if (!value) return;
  if (Array.isArray(value)) {
    for (const item of value) collect(item, out);
    return;
  }
  if (typeof value === 'object') {
    const id = value.id || value.name || value.model;
    if (typeof id === 'string' && id.trim()) out.push(id.trim());
    return;
  }
  if (typeof value === 'string' && value.trim()) out.push(value.trim());
}

let out = [];
if (Array.isArray(json)) collect(json, out);
else if (json && Array.isArray(json.data)) collect(json.data, out);
else if (json && Array.isArray(json.models)) collect(json.models, out);
else if (json && Array.isArray(json.result)) collect(json.result, out);
else collect(json, out);

const seen = new Set();
for (const id of out) {
  if (!seen.has(id)) {
    seen.add(id);
    console.log(id);
  }
}
"@
    $scriptFile = [System.IO.Path]::GetTempFileName() + ".js"
    [System.IO.File]::WriteAllText($scriptFile, $nodeScript, [System.Text.Encoding]::UTF8)

    $output = & node $scriptFile $tmpFile 2>$null
    $nodeRc = $LASTEXITCODE

    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue

    if ($nodeRc -ne 0 -or -not $output) {
        return $null
    }

    $models = $output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    return $models
}

function Prepare-ModelMenu {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret)

    $SCRIPT:AVAILABLE_MODELS = @()
    $SCRIPT:MODEL_MENU = @()

    $remoteModels = Fetch-ModelIdsFromGateway $BaseUrl $AuthMode $Secret
    if ($remoteModels -and $remoteModels.Count -gt 0) {
        $SCRIPT:AVAILABLE_MODELS = @($remoteModels)
        success "已从网关获取 $($remoteModels.Count) 个可用模型。"
        $SCRIPT:MODEL_MENU = @($remoteModels)
    } else {
        warn "未获取到真实模型列表，使用脚本内置兜底模型列表。"
        $SCRIPT:MODEL_MENU = @($MODELS)
    }
}

function Filter-ModelMenuIfNeeded {
    $count = $SCRIPT:MODEL_MENU.Count
    if ($count -le $MODEL_MENU_MAX_DISPLAY) { return }

    Write-SafeHost ""
    Write-SafeHost "检测到模型数量较多：$count 个。"
    $keyword = Read-Host -Prompt "请输入筛选关键词，例如 claude、sonnet、qwen、code；直接回车显示前 $MODEL_MENU_MAX_DISPLAY 个"
    if ([string]::IsNullOrEmpty($keyword)) { return }

    $lowerKeyword = $keyword.ToLower()
    $filtered = $SCRIPT:MODEL_MENU | Where-Object { $_.ToLower() -like "*$lowerKeyword*" }
    if ($filtered.Count -gt 0) {
        $SCRIPT:MODEL_MENU = @($filtered)
        success "筛选后剩余 $($filtered.Count) 个模型。"
    } else {
        warn "没有模型匹配关键词：${keyword}。将显示前 $MODEL_MENU_MAX_DISPLAY 个模型，并保留手动输入选项。"
    }
}

function Choose-Model {
    if ($SCRIPT:MODEL_MENU.Count -eq 0) {
        $SCRIPT:MODEL_MENU = @($MODELS)
    }

    Filter-ModelMenuIfNeeded

    $totalCount = $SCRIPT:MODEL_MENU.Count
    $displayCount = if ($totalCount -gt $MODEL_MENU_MAX_DISPLAY) { $MODEL_MENU_MAX_DISPLAY } else { $totalCount }

    Write-SafeHost ""
    Write-SafeHost "请选择模型："
    for ($i = 0; $i -lt $displayCount; $i++) {
        $n = $i + 1
        if ($n -eq $DEFAULT_MODEL_INDEX) {
            Write-SafeHost "  $n) $($SCRIPT:MODEL_MENU[$i])  [默认]"
        } else {
            Write-SafeHost "  $n) $($SCRIPT:MODEL_MENU[$i])"
        }
    }
    if ($totalCount -gt $displayCount) {
        Write-SafeHost "  ... 已隐藏 $($totalCount - $displayCount) 个模型；可选择手动输入模型名，或重新运行脚本用关键词筛选。"
    }
    $manualNum = $displayCount + 1
    Write-SafeHost "  $manualNum) 手动输入模型名"

    $choice = Read-Host -Prompt "请输入编号 [$DEFAULT_MODEL_INDEX]"
    if ([string]::IsNullOrEmpty($choice)) { $choice = "$DEFAULT_MODEL_INDEX" }

    if ($choice -match '^\d+$') {
        $num = [int]$choice
        if ($num -ge 1 -and $num -le $displayCount) {
            return $SCRIPT:MODEL_MENU[$num - 1]
        } elseif ($num -eq $manualNum) {
            $custom = Read-Host -Prompt "请输入模型名"
            if ([string]::IsNullOrEmpty($custom)) { fatal "模型名不能为空。" }
            return $custom
        }
    }

    $defaultModel = $SCRIPT:MODEL_MENU[$DEFAULT_MODEL_INDEX - 1]
    warn "无效选择，使用默认模型：$defaultModel"
    return $defaultModel
}

# ----- config --------------------------------------------------------------
function Test-BaseUrlFormat {
    param([string]$Url)
    if ($Url -notmatch '^https?://') {
        fatal "BASE_URL 必须以 http:// 或 https:// 开头。当前值：$Url"
    }
}

function Ask-BaseUrl {
    $url = $BOOTSTRAP_BASE_URL
    if ([string]::IsNullOrEmpty($url)) {
        $url = Read-Host -Prompt "请输入 ANTHROPIC_BASE_URL（API 网关根地址，不需要追加 /v1、/v1/messages 或其他路径），例如 https://api.example.com"
    } else {
        $maybe = Read-Host -Prompt "ANTHROPIC_BASE_URL 使用 ${url}（只需要网关根地址，不需要追加 /v1、/v1/messages 或其他路径），是否修改？直接回车表示不修改"
        if (-not [string]::IsNullOrEmpty($maybe)) {
            $url = $maybe
        }
    }
    if ([string]::IsNullOrEmpty($url)) {
        fatal "ANTHROPIC_BASE_URL 不能为空。"
    }
    $url = $url.TrimEnd('/')
    Test-BaseUrlFormat $url
    return $url
}

function Write-EnvFile {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret, [string]$Model)

    New-Item -ItemType Directory -Path $CONFIG_DIR -Force | Out-Null

    $lines = @(
        "# Generated by claude-bootstrap-v1.2.ps1. Do not commit this file."
        "`$env:ANTHROPIC_BASE_URL = $(ConvertTo-PowerShellSingleQuotedString $BaseUrl)"
    )
    if ($AuthMode -eq "auth_token") {
        $lines += "`$env:ANTHROPIC_AUTH_TOKEN = $(ConvertTo-PowerShellSingleQuotedString $Secret)"
        $lines += "Remove-Item env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue"
    } else {
        $lines += "`$env:ANTHROPIC_API_KEY = $(ConvertTo-PowerShellSingleQuotedString $Secret)"
        $lines += "Remove-Item env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue"
    }
    $lines += "`$env:ANTHROPIC_MODEL = $(ConvertTo-PowerShellSingleQuotedString $Model)"
    $lines += "`$env:ANTHROPIC_CUSTOM_MODEL_OPTION = $(ConvertTo-PowerShellSingleQuotedString $Model)"
    $lines += "`$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = $(ConvertTo-PowerShellSingleQuotedString $ENABLE_GATEWAY_MODEL_DISCOVERY)"
    $lines += "`$env:CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = $(ConvertTo-PowerShellSingleQuotedString $CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT)"
    $lines += "`$env:DISABLE_UPDATES = $(ConvertTo-PowerShellSingleQuotedString "1")"

    $lines -join "`r`n" | Set-Content $ENV_FILE -Encoding UTF8
    success "已写入环境变量：$ENV_FILE"
}

function Write-ClaudeSettingsJson {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret, [string]$Model)

    $settingsDir = Split-Path $CLAUDE_SETTINGS_JSON -Parent
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

    try {
        $env:CLAUDE_BOOTSTRAP_SETTINGS_FILE        = $CLAUDE_SETTINGS_JSON
        $env:CLAUDE_BOOTSTRAP_BASE_URL             = $BaseUrl
        $env:CLAUDE_BOOTSTRAP_AUTH_MODE            = $AuthMode
        $env:CLAUDE_BOOTSTRAP_SECRET               = $Secret
        $env:CLAUDE_BOOTSTRAP_MODEL                = $Model
        $env:CLAUDE_BOOTSTRAP_GATEWAY_MODEL_DISCOVERY = $ENABLE_GATEWAY_MODEL_DISCOVERY
        $env:CLAUDE_BOOTSTRAP_ENV_SCRUB            = $CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT

        $nodeScript = @'
const fs = require('fs');
const path = require('path');
const file = process.env.CLAUDE_BOOTSTRAP_SETTINGS_FILE;
let data = {};
try {
  if (fs.existsSync(file)) {
    const raw = fs.readFileSync(file, 'utf8').trim();
    if (raw) data = JSON.parse(raw);
  }
} catch (err) {
  const backup = file + '.bak.' + Date.now();
  fs.copyFileSync(file, backup);
  data = {};
  console.error(`[WARN] Existing settings.json is not valid JSON. Backed up to ${backup}`);
}
if (!data || typeof data !== 'object' || Array.isArray(data)) data = {};
const env = data.env && typeof data.env === 'object' && !Array.isArray(data.env) ? data.env : {};
env.ANTHROPIC_BASE_URL = process.env.CLAUDE_BOOTSTRAP_BASE_URL;
if (process.env.CLAUDE_BOOTSTRAP_AUTH_MODE === 'auth_token') {
  env.ANTHROPIC_AUTH_TOKEN = process.env.CLAUDE_BOOTSTRAP_SECRET;
  delete env.ANTHROPIC_API_KEY;
} else {
  env.ANTHROPIC_API_KEY = process.env.CLAUDE_BOOTSTRAP_SECRET;
  delete env.ANTHROPIC_AUTH_TOKEN;
}
env.ANTHROPIC_MODEL = process.env.CLAUDE_BOOTSTRAP_MODEL;
env.ANTHROPIC_CUSTOM_MODEL_OPTION = process.env.CLAUDE_BOOTSTRAP_MODEL;
env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = process.env.CLAUDE_BOOTSTRAP_GATEWAY_MODEL_DISCOVERY || '1';
env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = process.env.CLAUDE_BOOTSTRAP_ENV_SCRUB || '0';
env.DISABLE_UPDATES = '1';
data.skipWebFetchPreflight = true;
data.env = env;
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
'@
        $nodeScript | node
    } finally {
        Remove-Item env:CLAUDE_BOOTSTRAP_SETTINGS_FILE -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_AUTH_MODE -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_SECRET -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_MODEL -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_GATEWAY_MODEL_DISCOVERY -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_ENV_SCRUB -ErrorAction SilentlyContinue
    }
    Update-InstallSettingsState $BaseUrl $AuthMode $Secret $Model
    success "已同步 Claude Code 官方配置：$CLAUDE_SETTINGS_JSON"
}

function Update-ModelInEnvFile {
    param([string]$Model)

    $modelLine = "`$env:ANTHROPIC_MODEL = $(ConvertTo-PowerShellSingleQuotedString $Model)"
    $customLine = "`$env:ANTHROPIC_CUSTOM_MODEL_OPTION = $(ConvertTo-PowerShellSingleQuotedString $Model)"
    $modelSeen = $false
    $customSeen = $false
    $outputLines = @()

    foreach ($line in @(Get-Content $ENV_FILE -ErrorAction Stop)) {
        if ($line -match '^\s*\$env:ANTHROPIC_MODEL\s*=') {
            if (-not $modelSeen) { $outputLines += $modelLine }
            $modelSeen = $true
            continue
        }
        if ($line -match '^\s*\$env:ANTHROPIC_CUSTOM_MODEL_OPTION\s*=') {
            if (-not $customSeen) { $outputLines += $customLine }
            $customSeen = $true
            continue
        }
        $outputLines += $line
    }

    if (-not $modelSeen) { $outputLines += $modelLine }
    if (-not $customSeen) { $outputLines += $customLine }
    $outputLines -join "`r`n" | Set-Content $ENV_FILE -Encoding UTF8
    success "已更新环境变量中的模型：$Model"
}

function Update-ModelInClaudeSettingsJson {
    param([string]$Model)

    $settingsDir = Split-Path $CLAUDE_SETTINGS_JSON -Parent
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null

    try {
        $env:CLAUDE_BOOTSTRAP_SETTINGS_FILE = $CLAUDE_SETTINGS_JSON
        $env:CLAUDE_BOOTSTRAP_MODEL = $Model
        $nodeScript = @'
const fs = require('fs');
const path = require('path');
const file = process.env.CLAUDE_BOOTSTRAP_SETTINGS_FILE;
let data = {};
try {
  if (fs.existsSync(file)) {
    const raw = fs.readFileSync(file, 'utf8').trim();
    if (raw) data = JSON.parse(raw);
  }
} catch (err) {
  const backup = file + '.bak.' + Date.now();
  fs.copyFileSync(file, backup);
  data = {};
  console.error(`[WARN] Existing settings.json is not valid JSON. Backed up to ${backup}`);
}
if (!data || typeof data !== 'object' || Array.isArray(data)) data = {};
const env = data.env && typeof data.env === 'object' && !Array.isArray(data.env) ? data.env : {};
env.ANTHROPIC_MODEL = process.env.CLAUDE_BOOTSTRAP_MODEL;
env.ANTHROPIC_CUSTOM_MODEL_OPTION = process.env.CLAUDE_BOOTSTRAP_MODEL;
data.env = env;
fs.mkdirSync(path.dirname(file), { recursive: true });
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n');
'@
        $nodeScript | node
        if ($LASTEXITCODE -ne 0) {
            fatal "更新 Claude Code settings.json 中的模型失败。"
        }
    } finally {
        Remove-Item env:CLAUDE_BOOTSTRAP_SETTINGS_FILE -ErrorAction SilentlyContinue
        Remove-Item env:CLAUDE_BOOTSTRAP_MODEL -ErrorAction SilentlyContinue
    }
    Update-InstallModelState $Model
    success "已同步 Claude Code 官方配置中的模型：$Model"
}

function Sync-SettingsFromExistingEnv {
    if (-not (Test-Path $ENV_FILE)) { return }

    # Dot-source the env file to load variables
    . $ENV_FILE

    $baseUrl  = $env:ANTHROPIC_BASE_URL
    $model    = if ($env:ANTHROPIC_MODEL) { $env:ANTHROPIC_MODEL } else { $env:ANTHROPIC_CUSTOM_MODEL_OPTION }
    $authMode = ""
    $secret   = ""

    if ($env:ANTHROPIC_AUTH_TOKEN) {
        $authMode = "auth_token"
        $secret   = $env:ANTHROPIC_AUTH_TOKEN
    } elseif ($env:ANTHROPIC_API_KEY) {
        $authMode = "api_key"
        $secret   = $env:ANTHROPIC_API_KEY
    }

    if ($baseUrl -and $model -and $authMode -and $secret) {
        Write-ClaudeSettingsJson $baseUrl $authMode $secret $model
    } else {
        warn "已有 env 文件信息不完整，无法同步到 ${CLAUDE_SETTINGS_JSON}。"
    }
}

function Choose-ExistingConfigAction {
    Write-SafeHost ""
    Write-SafeHost "请选择操作："
    Write-SafeHost "  1) 保留现有配置  [默认]"
    Write-SafeHost "  2) 仅切换模型"
    Write-SafeHost "  3) 重新配置全部"
    $choice = Read-Host -Prompt "请输入编号 [1]"
    switch ($choice) {
        "2" { return "switch_model" }
        "3" { return "reconfigure" }
        default { return "keep" }
    }
}

function Switch-ModelFromExistingConfig {
    . $ENV_FILE

    $baseUrl = $env:ANTHROPIC_BASE_URL
    $currentModel = if ($env:ANTHROPIC_MODEL) { $env:ANTHROPIC_MODEL } else { $env:ANTHROPIC_CUSTOM_MODEL_OPTION }
    $authMode = ""
    $secret = ""

    if ($env:ANTHROPIC_AUTH_TOKEN) {
        $authMode = "auth_token"
        $secret = $env:ANTHROPIC_AUTH_TOKEN
    } elseif ($env:ANTHROPIC_API_KEY) {
        $authMode = "api_key"
        $secret = $env:ANTHROPIC_API_KEY
    }

    if (-not $baseUrl -or -not $currentModel -or -not $authMode -or -not $secret) {
        warn "已有配置缺少 BASE_URL、认证信息或当前模型，无法仅切换模型。请重新运行并选择“重新配置全部”。"
        return $false
    }

    success "当前模型：$currentModel"
    Prepare-ModelMenu $baseUrl $authMode $secret
    $SCRIPT:MODEL_MENU = @($currentModel) + @($SCRIPT:MODEL_MENU | Where-Object { $_ -ne $currentModel })
    $newModel = Choose-Model

    Update-ModelInEnvFile $newModel
    Update-ModelInClaudeSettingsJson $newModel
    $env:ANTHROPIC_MODEL = $newModel
    $env:ANTHROPIC_CUSTOM_MODEL_OPTION = $newModel
    if ($newModel -eq $currentModel) {
        success "模型保持不变：$currentModel"
    } else {
        success "模型已从 $currentModel 切换为 $newModel"
    }
    info "请重新启动 Claude Code 使新模型生效。"
    return $true
}

function New-ClaudeWrapper {
    if ($CREATE_CLAUDE_WRAPPER -ne "1") { return }

    $realClaude = $global:CLAUDE_BOOTSTRAP_REAL_BIN
    if (-not $realClaude -or -not (Test-Path $realClaude)) {
        $realClaude = Find-RealClaudeBin
    }
    if (-not $realClaude) {
        warn "无法定位真实 claude 二进制，跳过 claude wrapper 创建。"
        return
    }

    New-Item -ItemType Directory -Path $WRAPPER_DIR -Force | Out-Null

    # Create claude.cmd wrapper
    $wrapperContent = @"
@echo off
REM CLAUDE_BOOTSTRAP_WRAPPER
set "REAL_CLAUDE_BIN=$realClaude"

REM Load fnm environment
if exist "%USERPROFILE%\.fnm\fnm.exe" (
    for /f "tokens=*" %%i in ('"%USERPROFILE%\.fnm\fnm.exe" env --shell cmd --use-on-cd 2^>nul') do %%i
)
if exist "%LOCALAPPDATA%\fnm\fnm.exe" (
    for /f "tokens=*" %%i in ('"%LOCALAPPDATA%\fnm\fnm.exe" env --shell cmd --use-on-cd 2^>nul') do %%i
)
if exist "%APPDATA%\fnm\fnm.exe" (
    for /f "tokens=*" %%i in ('"%APPDATA%\fnm\fnm.exe" env --shell cmd --use-on-cd 2^>nul') do %%i
)

REM Source bootstrap env if present
if exist "%USERPROFILE%\.claude-bootstrap\env.cmd" call "%USERPROFILE%\.claude-bootstrap\env.cmd"

if not exist "%REAL_CLAUDE_BIN%" (
    echo [ERROR] real claude binary not found: %REAL_CLAUDE_BIN%
    echo Please rerun install.ps1.
    exit /b 1
)
"%REAL_CLAUDE_BIN%" %*
"@
    $wrapperContent -replace "`r`n", "`r`n" | Set-Content $CLAUDE_WRAPPER -Encoding ASCII

    # Also create an env.cmd for cmd.exe compatibility
    $envCmd = "$CONFIG_DIR\env.cmd"
    if (Test-Path $ENV_FILE) {
        $psEnv = Get-Content $ENV_FILE -Raw
        # Convert $env:KEY = 'VALUE' to set KEY=VALUE
        $cmdLines = @("@echo off", "REM Generated by claude-bootstrap-v1.2.ps1")
        $psEnv -split "`r?`n" | ForEach-Object {
            if ($_ -match "^\`$env:(\w+)\s*=\s*'(.*)'") {
                $cmdValue = $Matches[2] -replace "''", "'"
                $cmdValue = $cmdValue -replace '%', '%%' -replace '"', '^"'
                $cmdLines += "set `"$($Matches[1])=$cmdValue`""
            }
        }
        $cmdLines -join "`r`n" | Set-Content $envCmd -Encoding ASCII
    }

    success "已创建 claude wrapper：$CLAUDE_WRAPPER"
}

# ----- gateway validation --------------------------------------------------
function Test-Gateway {
    param([string]$BaseUrl, [string]$AuthMode, [string]$Secret, [string]$Model)

    if (-not (need_cmd curl)) {
        warn "未检测到 curl，跳过网关验证。"
        return
    }

    $url = "$BaseUrl/v1/models"
    $tmpFile = [System.IO.Path]::GetTempFileName()

    info "验证网关连通性：GET $url"
    try {
        $headers = @{}
        if ($AuthMode -eq "auth_token") {
            $headers["Authorization"] = "Bearer $Secret"
        } else {
            $headers["X-Api-Key"] = $Secret
        }
        $response = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
        $httpCode = $response.StatusCode
        $body = $response.Content

        if ($httpCode -eq 200) {
            success "网关认证通过，/v1/models 返回 HTTP ${httpCode}。"
            if ($body -match [regex]::Escape($Model)) {
                success "模型列表中检测到当前模型：$Model"
            } else {
                warn "模型列表中未直接匹配到 ${Model}。若你们的中转站使用映射模型名，可忽略。"
            }
        } else {
            warn "网关返回 HTTP ${httpCode}。响应已忽略，脚本会继续。"
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }
        if ($statusCode) {
            if ($statusCode -eq 401 -or $statusCode -eq 403) {
                warn "网关返回 HTTP ${statusCode}，API Key/Auth Token 可能不可用。"
                if (confirm "是否重新输入 Key 并重写配置？" "Y") {
                    $newSecret = Read-ApiSecret
                    Write-EnvFile $BaseUrl $AuthMode $newSecret $Model
                    Write-ClaudeSettingsJson $BaseUrl $AuthMode $newSecret $Model
                    Test-Gateway $BaseUrl $AuthMode $newSecret $Model
                }
            } elseif ($statusCode -eq 404 -or $statusCode -eq 405) {
                warn "网关返回 HTTP ${statusCode}，可能不支持 /v1/models。跳过模型接口验证。"
            } else {
                warn "网关返回 HTTP ${statusCode}。响应已忽略，脚本会继续。"
            }
        } else {
            warn "网关验证请求失败。可能是网络、证书或 BASE_URL 问题。脚本会继续。"
        }
    }
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
}

# ----- main config flow ----------------------------------------------------
function Set-ClaudeConfig {
    if (Test-Path $ENV_FILE) {
        warn "检测到已有配置：$ENV_FILE"
        $existingAction = Choose-ExistingConfigAction
        switch ($existingAction) {
            "keep" {
                success "保留已有配置。"
                Sync-SettingsFromExistingEnv
                Write-ProfileBlock
                New-ClaudeWrapper
                return
            }
            "switch_model" {
                Switch-ModelFromExistingConfig | Out-Null
                return
            }
            "reconfigure" {
                info "将重新配置全部 Claude Code 设置。"
            }
        }
    }

    $baseUrl  = Ask-BaseUrl
    $authMode = Choose-AuthMode
    $secret   = Read-ApiSecret
    Prepare-ModelMenu $baseUrl $authMode $secret
    $model    = Choose-Model

    Write-EnvFile            $baseUrl $authMode $secret $model
    Write-ClaudeSettingsJson $baseUrl $authMode $secret $model
    Write-ProfileBlock
    New-ClaudeWrapper
    Test-Gateway              $baseUrl $authMode $secret $model
}

# ----- summary -------------------------------------------------------------
function Write-Summary {
    $summary = @"

============================================================
Claude Code 安装配置完成
============================================================

当前环境变量配置文件：
  $ENV_FILE

当前 Claude Code 官方配置文件：
  $CLAUDE_SETTINGS_JSON

当前 PowerShell 配置文件：
  $PROFILE

请执行以下命令让当前终端立即生效：
  . `$PROFILE

启动 Claude Code：
  claude

重新配置：
  powershell -ExecutionPolicy Bypass -File install.ps1

注意：
  - API Key/Auth Token 已写入 $ENV_FILE 和 ${CLAUDE_SETTINGS_JSON}。
  - Claude Code 固定安装 $CLAUDE_NPM_PACKAGE，并写入 DISABLE_UPDATES=1 防止自更新覆盖。
  - 默认 CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0，避免 Windows 缺少 bubblewrap 时启动失败。
  - 如果安全策略限制脚本执行，请使用 powershell -ExecutionPolicy Bypass -File install.ps1 运行。
============================================================
"@
    Write-SafeHost $summary Cyan
}

# ----- main ----------------------------------------------------------------
function Main {
    Test-Platform
    Test-Memory
    Test-Admin
    Install-BasicDeps
    Initialize-InstallState
    Enable-Node22
    Install-ClaudeCode
    Update-InstallRuntimeState
    Set-ClaudeConfig
    Write-Summary
}

Main
