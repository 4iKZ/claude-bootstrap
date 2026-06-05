<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://cdn.jsdelivr.net/npm/simple-icons@13.0.0/icons/anthropic.svg">
    <img src="https://cdn.jsdelivr.net/npm/simple-icons@13.0.0/icons/anthropic.svg" width="72" height="72" alt="Anthropic">
  </picture>
</p>

<h1 align="center">Claude Code Bootstrap</h1>

<p align="center">
  <strong>一条命令，完成 Claude Code 团队环境搭建</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS-333.svg?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/shell-bash-4EAA25.svg?style=flat-square&logo=gnubash&logoColor=white" alt="Shell">
  <img src="https://img.shields.io/badge/node-%3E%3D18-green.svg?style=flat-square&logo=nodedotjs&logoColor=white" alt="Node.js">
  <img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License">
</p>

---

## 这是什么？

一个面向团队的 **Claude Code 一键安装脚本**。在一台没有开发环境的 Linux / macOS 机器上，运行这个脚本即可完成：

- 系统依赖安装（curl、git、tar、xz）
- Node.js 22 环境搭建（通过 nvm）
- Claude Code 全局安装（npm）
- 团队网关配置（BASE_URL + API Key / Auth Token）
- 动态模型列表获取
- Shell 环境自动注入
- Claude Code settings.json 同步

脚本会自动识别发行版和包管理器（apt、dnf、yum、apk、pacman、zypper），无需手动干预。

---

## 快速开始

```bash
# 1. 下载脚本
curl -fsSL -o claude-bootstrap.sh \
  https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.sh

# 2. 运行
bash claude-bootstrap.sh
```

或者一行搞定：

```bash
curl -fsSL https://raw.githubusercontent.com/4iKZ/claude-bootstrap/main/install.sh | bash
```

> **注意**：管道方式下，脚本无法修改父 shell 环境。完成后请执行 `source ~/.bashrc`（或对应的 shell 配置文件），或重新打开终端。

---

## 配置选项

脚本支持通过环境变量预置团队默认值，适合批量部署：

| 环境变量                                   | 默认值                             | 说明                                               |
| ------------------------------------------ | ---------------------------------- | -------------------------------------------------- |
| `TEAM_BASE_URL`                            | —                                 | 团队网关地址，如`https://api.internal.example.com` |
| `DEFAULT_AUTH_MODE`                        | `auth_token`                       | 认证模式：`auth_token` 或 `api_key`                |
| `CREATE_CLAUDE_WRAPPER`                    | `1`                                | 是否创建`~/.claude-team/bin/claude` 包装脚本       |
| `ENABLE_GATEWAY_MODEL_DISCOVERY`           | `1`                                | 是否从网关动态拉取模型列表                         |
| `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT` | `0`                                | 子进程环境清理策略                                 |
| `NVM_VERSION`                              | `v0.40.3`                          | nvm 版本                                           |
| `REQUIRED_NODE_MAJOR`                      | `22`                               | 目标 Node.js 主版本号                              |
| `CLAUDE_NPM_PACKAGE`                       | `@anthropic-ai/claude-code@latest` | Claude Code npm 包名                               |

示例——预填网关地址和认证模式：

```bash
TEAM_BASE_URL="https://api.internal.example.com" \
DEFAULT_AUTH_MODE="api_key" \
  bash install.sh
```

---

## 执行流程

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
交互式配置
  ├─ 输入团队网关 BASE_URL
  ├─ 选择认证模式（Auth Token / API Key）
  ├─ 输入密钥
  ├─ 动态拉取可用模型列表（或使用内置兜底列表）
  └─ 选择默认模型
        │
        ▼
写入配置文件
  ├─ ~/.claude-team/env              (环境变量)
  ├─ ~/.claude/settings.json         (Claude Code 官方配置)
  └─ ~/.bashrc / ~/.zshrc            (PATH 注入)
        │
        ▼
连通性验证 → 打印摘要
```

---

## 生成的文件

| 路径                        | 说明                                |
| --------------------------- | ----------------------------------- |
| `~/.claude-team/env`        | 团队网关环境变量（chmod 600）       |
| `~/.claude-team/bin/claude` | 包装脚本，启动时自动加载团队环境    |
| `~/.claude/settings.json`   | Claude Code 官方配置，同步 env 内容 |
| `~/.nvm/`                   | nvm 及 Node.js 安装目录             |

---

## 支持的平台

| 操作系统      | 架构        | 状态                   |
| ------------- | ----------- | ---------------------- |
| Ubuntu 20.04+ | x64 / ARM64 | ✅ 完全支持            |
| Debian 11+    | x64 / ARM64 | ✅ 完全支持            |
| Fedora 38+    | x64 / ARM64 | ✅ 完全支持            |
| RHEL 7/8/9    | x64         | ✅ 支持                |
| Alpine 3.17+  | x64 / ARM64 | ✅ 支持（需先装 bash） |
| Arch Linux    | x64         | ✅ 支持                |
| openSUSE      | x64         | ✅ 支持                |
| macOS 12+     | x64 / ARM64 | ✅ 完全支持            |
| Windows       | —          | ❌ 不支持              |

---

## 故障排查

<details>
<summary><strong>Alpine Linux：command not found: bash</strong></summary>

Alpine 默认不含 bash。先执行：

```bash
apk add bash
```

然后重新运行脚本。

</details>

<details>
<summary><strong>缺少基础依赖且无 sudo</strong></summary>

脚本会提示具体缺少的包名。请手动安装后再运行，或切换到有 root 权限的用户。

</details>

<details>
<summary><strong>nvm install 失败：tar 无法解压 .tar.xz</strong></summary>

缺少 xz 解压工具。脚本已自动处理，但若你跳过了包安装阶段，可手动安装：

- Debian/Ubuntu: `sudo apt install xz-utils`
- Fedora/RHEL: `sudo dnf install xz`
- Alpine: `sudo apk add xz`

</details>

<details>
<summary><strong>Claude Code 启动时提示 bubblewrap 错误</strong></summary>

脚本默认设置 `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0`。若仍有问题，检查 `~/.claude-team/env` 是否已正确 source。

</details>

<details>
<summary><strong>重新配置</strong></summary>

直接重新运行脚本即可——它会检测已有配置并询问是否覆盖：

```bash
bash install.sh
```

</details>

---

## 安全说明

- API Key / Auth Token 写入文件时自动设置 `chmod 600`（仅所有者可读写）
- `~/.claude-team/` 目录设置为 `chmod 700`
- 脚本不通过命令行参数传递密钥，全部采用交互式输入（隐藏回显）或环境变量
- 建议生产环境中通过环境变量预注密钥，避免交互式输入被日志记录

---

## License

MIT

---

<p align="center">
  <sub>Built with ❤️ for Claude Code teams</sub>
</p>
