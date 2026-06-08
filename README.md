<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://cdn.jsdelivr.net/npm/simple-icons@13.0.0/icons/anthropic.svg">
    <img src="https://cdn.jsdelivr.net/npm/simple-icons@13.0.0/icons/anthropic.svg" width="72" height="72" alt="Anthropic">
  </picture>
</p>

<h1 align="center">Claude Code Bootstrap</h1>

<p align="center">
  <strong>一条命令，完成 Claude Code 环境搭建</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-333.svg?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/shell-bash%20%7C%20pwsh-4EAA25.svg?style=flat-square" alt="Shell">
  <img src="https://img.shields.io/badge/node-%3E%3D18-green.svg?style=flat-square&logo=nodedotjs&logoColor=white" alt="Node.js">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License">
</p>

---

## 一行命令安装

### Linux / macOS

```bash
bash -c 'set -euo pipefail; if ! command -v curl >/dev/null; then SUDO=sudo; [ "$(id -u)" -eq 0 ] && SUDO=; if command -v apt-get >/dev/null; then $SUDO apt-get update; $SUDO apt-get install -y curl ca-certificates; elif command -v dnf >/dev/null; then $SUDO dnf install -y curl ca-certificates; elif command -v yum >/dev/null; then $SUDO yum install -y curl ca-certificates; elif command -v apk >/dev/null; then $SUDO apk add --no-cache curl ca-certificates; elif command -v pacman >/dev/null; then $SUDO pacman -Sy --noconfirm curl ca-certificates; elif command -v zypper >/dev/null; then $SUDO zypper install -y curl ca-certificates; else echo "未检测到 curl，且无法识别包管理器，请先手动安装 curl。"; exit 1; fi; fi; curl -fsSL https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.sh | bash'
```

### Windows

```powershell
iex (irm https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.ps1)
```

> **Linux / macOS**：管道方式无法修改父 shell 环境，完成后 `source ~/.bashrc` 或重新打开终端。
>
> **Windows**：若提示 "无法加载"，先运行 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`，或使用 `powershell -ExecutionPolicy Bypass` 启动。

---

## 这是什么？

在一台**没有任何开发环境**的机器上，运行上面那一行命令即可自动完成：

- ✅ 系统依赖安装（curl、git、tar、xz / winget）
- ✅ Node.js 22 环境搭建（nvm / fnm）
- ✅ Claude Code 全局安装（npm）
- ✅ API 网关配置（BASE_URL + API Key / Auth Token）
- ✅ 动态模型列表获取
- ✅ Shell / PowerShell 环境自动注入
- ✅ Claude Code settings.json 同步

脚本会自动识别操作系统和包管理器（apt、dnf、yum、apk、pacman、zypper、winget），无需手动干预。

---

## 带配置的一行安装

如果你已经知道网关地址，可以跳过交互式输入：

### Linux / macOS

```bash
BOOTSTRAP_BASE_URL="https://api.example.com" bash -c "$(curl -fsSL https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.sh)"
```

### Windows

```powershell
$env:BOOTSTRAP_BASE_URL="https://api.example.com"; iex (irm https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.ps1)
```

---

## 配置选项

| 环境变量                                   | 默认值                             | 说明                                |
| ------------------------------------------ | ---------------------------------- | ----------------------------------- |
| `BOOTSTRAP_BASE_URL`                       | —                                 | API 网关地址                        |
| `DEFAULT_AUTH_MODE`                        | `auth_token`                       | 认证模式：`auth_token` 或 `api_key` |
| `CREATE_CLAUDE_WRAPPER`                    | `1`                                | 是否创建 wrapper 脚本               |
| `ENABLE_GATEWAY_MODEL_DISCOVERY`           | `1`                                | 是否从网关动态拉取模型列表          |
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT` | `0`                                | 子进程环境清理策略                  |
| `REQUIRED_NODE_MAJOR`                      | `22`                               | 目标 Node.js 主版本号               |
| `CLAUDE_NPM_PACKAGE`                       | `@anthropic-ai/claude-code@latest` | Claude Code npm 包名                |

---

## 执行流程

### Linux / macOS (install.sh)

```
检测平台（Linux / macOS + 架构）
        │
        ▼
检查内存（建议 ≥ 4 GB）
        │
        ▼
检测 sudo 权限
        │
        ▼
安装基础依赖（curl、git、tar、xz）
  ├─ Debian/Ubuntu → apt-get
  ├─ Fedora/RHEL   → dnf / yum
  ├─ Alpine        → apk
  ├─ Arch          → pacman
  └─ openSUSE      → zypper
        │
        ▼
安装 Node.js 22（通过 nvm）
        │
        ▼
npm install -g @anthropic-ai/claude-code
        │
        ▼
交互式配置 → 写入配置 → 连通性验证 → 打印摘要
```

### Windows (install.ps1)

```
检测平台（Windows + 架构）
        │
        ▼
检查内存（建议 ≥ 4 GB）
        │
        ▼
检测管理员权限
        │
        ▼
安装基础依赖（git，通过 winget）
        │
        ▼
安装 fnm + Node.js 22
        │
        ▼
npm install -g @anthropic-ai/claude-code
        │
        ▼
交互式配置 → 写入配置 → 连通性验证 → 打印摘要
```

---

## 生成的文件

| 路径                             | 说明                               |
| -------------------------------- | ---------------------------------- |
| `~/.claude-bootstrap/env`        | 环境变量文件（Linux/macOS）        |
| `~/.claude-bootstrap/env.ps1`    | 环境变量文件（Windows PowerShell） |
| `~/.claude-bootstrap/env.cmd`    | 环境变量文件（Windows cmd）        |
| `~/.claude-bootstrap/bin/claude` | 包装脚本                           |
| `~/.claude/settings.json`        | Claude Code 官方配置               |

---

## 支持的平台

| 操作系统             | 架构        | 脚本        | 状态              |
| -------------------- | ----------- | ----------- | ----------------- |
| Ubuntu 20.04+        | x64 / ARM64 | install.sh  | ✅                |
| Debian 11+           | x64 / ARM64 | install.sh  | ✅                |
| Fedora 38+           | x64 / ARM64 | install.sh  | ✅                |
| RHEL 7/8/9           | x64         | install.sh  | ✅                |
| Alpine 3.17+         | x64 / ARM64 | install.sh  | ✅（需先装 bash） |
| Arch Linux           | x64         | install.sh  | ✅                |
| openSUSE             | x64         | install.sh  | ✅                |
| macOS 12+            | x64 / ARM64 | install.sh  | ✅                |
| Windows 10+          | x64 / ARM64 | install.ps1 | ✅                |
| Windows Server 2019+ | x64         | install.ps1 | ✅                |

---

## 故障排查

<details>
<summary><strong>Alpine Linux：command not found: bash</strong></summary>

```bash
apk add bash
```

</details>

<details>
<summary><strong>nvm install 失败：tar 无法解压 .tar.xz</strong></summary>

脚本已自动处理，若跳过了包安装阶段：

- Debian/Ubuntu: `sudo apt install xz-utils`
- Fedora/RHEL: `sudo dnf install xz`
- Alpine: `sudo apk add xz`

</details>

<details>
<summary><strong>Windows：运行脚本提示 "无法加载文件"</strong></summary>

PowerShell 默认禁止执行脚本，使用 `-ExecutionPolicy Bypass` 运行：

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

</details>

<details>
<summary><strong>Windows：winget 找不到</strong></summary>

Windows 10 早期版本可能未安装 winget。从 Microsoft Store 安装"应用安装程序"（App Installer），或手动安装 git 和 fnm 后重新运行。

</details>

<details>
<summary><strong>Claude Code 启动时提示 bubblewrap 错误</strong></summary>

脚本默认设置 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`，避免缺少 bubblewrap 时启动失败。

</details>

<details>
<summary><strong>重新配置</strong></summary>

直接重新运行脚本——它会检测已有配置并询问是否覆盖：

```bash
bash install.sh        # Linux / macOS
```

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1   # Windows
```

</details>

---

## 安全说明

- API Key / Auth Token 写入文件时仅所有者可读写
- `~/.claude-bootstrap/` 目录设置为仅所有者可访问
- 脚本不通过命令行参数传递密钥，全部采用交互式输入（隐藏回显）或环境变量
- 建议生产环境中通过环境变量预注密钥，避免交互式输入被日志记录

---

## License

MIT

---

<p align="center">
  <sub>Built with ❤️ for Claude Code users</sub>
</p>
