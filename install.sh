#!/usr/bin/env bash
set -Eeuo pipefail

# Claude Code Bootstrap v1.2
# Target: Linux / macOS only. Windows is intentionally not supported.
# Usage:
#   bash claude-bootstrap-v1.2.sh
# Or:
#   TEAM_BASE_URL="https://your-gateway.example.com" bash claude-bootstrap-v1.2.sh

#######################################
# Defaults. Adjust these as needed.
#######################################
TEAM_BASE_URL="${TEAM_BASE_URL:-}"                    # Example: https://api.internal.example.com
DEFAULT_AUTH_MODE="${DEFAULT_AUTH_MODE:-auth_token}"  # auth_token | api_key
CREATE_CLAUDE_WRAPPER="${CREATE_CLAUDE_WRAPPER:-1}"   # 1 creates ~/.claude-code/bin/claude wrapper
ENABLE_GATEWAY_MODEL_DISCOVERY="${ENABLE_GATEWAY_MODEL_DISCOVERY:-1}"
CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT="${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT:-0}"
NVM_VERSION="${NVM_VERSION:-v0.40.3}"
REQUIRED_NODE_MAJOR="${REQUIRED_NODE_MAJOR:-22}"
CLAUDE_NPM_PACKAGE="${CLAUDE_NPM_PACKAGE:-@anthropic-ai/claude-code@latest}"
MODEL_MENU_MAX_DISPLAY="${MODEL_MENU_MAX_DISPLAY:-30}"
DYNAMIC_MODEL_DISCOVERY="${DYNAMIC_MODEL_DISCOVERY:-1}"

# Fallback model menu. Runtime will prefer models returned by $ANTHROPIC_BASE_URL/v1/models.
MODELS=(
  "claude-sonnet-4-5"
  "claude-opus-4-1"
  "claude-haiku-4-5"
  "qwen3-coder"
  "deepseek-v3.1"
  "kimi-k2"
)
DEFAULT_MODEL_INDEX=1
MODEL_MENU=()
AVAILABLE_MODELS=()

CONFIG_DIR="$HOME/.claude-code"
ENV_FILE="$CONFIG_DIR/env"
WRAPPER_DIR="$CONFIG_DIR/bin"
CLAUDE_WRAPPER="$WRAPPER_DIR/claude"
CLAUDE_SETTINGS_JSON="$HOME/.claude/settings.json"
PROFILE_MARKER_BEGIN="# >>> claude-code bootstrap >>>"
PROFILE_MARKER_END="# <<< claude-code bootstrap <<<"

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
fatal() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

read_user_input() {
  if [[ -t 0 ]]; then
    read "$@"
  elif [[ -r /dev/tty ]]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-Y}"
  local reply=""
  if [[ "$default" == "Y" ]]; then
    read_user_input -r -p "$prompt [Y/n]: " reply || true
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
  else
    read_user_input -r -p "$prompt [y/N]: " reply || true
    [[ "$reply" =~ ^[Yy]$ ]]
  fi
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

os_name=""
os_id=""
os_like=""
arch=""
sudo_cmd=""
profile_file=""

check_platform() {
  case "$(uname -s)" in
    Darwin)
      os_name="macos"
      os_id="macos"
      os_like="darwin"
      ;;
    Linux)
      os_name="linux"
      if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-linux}"
        os_like="${ID_LIKE:-}"
      else
        os_id="linux"
        os_like=""
      fi
      ;;
    *)
      fatal "当前脚本只支持 Linux / macOS，不支持 $(uname -s)。"
      ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) fatal "不支持的 CPU 架构：$(uname -m)。Claude Code 需要 x64 或 ARM64。" ;;
  esac

  success "检测到系统：$os_name / $os_id / $arch"
}

check_memory() {
  local mem_mb=""
  if [[ "$os_name" == "linux" && -r /proc/meminfo ]]; then
    mem_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo)
  elif [[ "$os_name" == "macos" ]] && need_cmd sysctl; then
    mem_mb=$(($(sysctl -n hw.memsize) / 1024 / 1024))
  fi
  if [[ -n "${mem_mb:-}" && "$mem_mb" -lt 4096 ]]; then
    warn "当前内存约 ${mem_mb}MB，Claude Code 官方建议至少 4GB RAM。脚本会继续执行。"
  fi
}

setup_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    sudo_cmd=""
    warn "当前是 root 用户。脚本会继续。"
    return
  fi
  if need_cmd sudo; then
    sudo_cmd="sudo"
    if $sudo_cmd -v >/dev/null 2>&1; then
      success "sudo 权限可用"
    else
      warn "sudo 权限不可用。后续如需安装系统依赖，可能会失败。"
    fi
  else
    sudo_cmd=""
    warn "未检测到 sudo。后续如需安装系统依赖，可能会失败。"
  fi
}

install_basic_deps_linux() {
  local missing=()
  need_cmd curl || missing+=(curl)
  need_cmd git || missing+=(git)
  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi

  info "准备安装基础依赖：${missing[*]}"
  if [[ -z "$sudo_cmd" && "$(id -u)" -ne 0 ]]; then
    fatal "缺少基础依赖 ${missing[*]}，且当前用户无 sudo/root 权限，无法自动安装。"
  fi

  if need_cmd apt-get; then
    $sudo_cmd apt-get update
    $sudo_cmd apt-get install -y "${missing[@]}" ca-certificates xz-utils
  elif need_cmd dnf; then
    $sudo_cmd dnf install -y "${missing[@]}" ca-certificates xz
  elif need_cmd yum; then
    $sudo_cmd yum install -y "${missing[@]}" ca-certificates xz
  elif need_cmd apk; then
    $sudo_cmd apk add --no-cache "${missing[@]}" ca-certificates xz
  elif need_cmd pacman; then
    $sudo_cmd pacman -Sy --noconfirm "${missing[@]}" ca-certificates xz
  elif need_cmd zypper; then
    $sudo_cmd zypper install -y "${missing[@]}" ca-certificates xz
  else
    fatal "无法识别包管理器。请手动安装：${missing[*]}。"
  fi
}

install_basic_deps() {
  if ! need_cmd bash; then
    if [[ -f /etc/alpine-release ]]; then
      fatal "Alpine Linux 默认不含 bash。请先执行：apk add bash"
    else
      fatal "未检测到 bash。"
    fi
  fi
  need_cmd tar || fatal "未检测到 tar，无法解压 Node.js 归档。请先安装 tar。"
  if [[ "$os_name" == "linux" ]]; then
    install_basic_deps_linux
  else
    need_cmd curl || fatal "macOS 未检测到 curl。"
    if ! need_cmd git; then
      warn "macOS 未检测到 git。nvm 安装可能触发 Xcode Command Line Tools 安装提示。"
    fi
  fi
}

load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    return 0
  fi
  return 1
}

install_nvm() {
  if load_nvm; then
    return
  fi
  info "安装 nvm $NVM_VERSION"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  load_nvm || fatal "nvm 安装后仍无法加载，请重新打开终端后重试。"
}

node_major() {
  node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'
}

ensure_node22() {
  local current_major=""
  if need_cmd node; then
    current_major="$(node_major)"
    info "检测到 Node.js：$(node -v)"
    if [[ "$current_major" == "$REQUIRED_NODE_MAJOR" ]]; then
      success "Node.js $REQUIRED_NODE_MAJOR 已安装"
      return
    fi
    if [[ "$current_major" -gt "$REQUIRED_NODE_MAJOR" ]]; then
      if confirm "检测到 Node.js $(node -v)，高于目标版本 $REQUIRED_NODE_MAJOR，是否继续使用当前版本？" "Y"; then
        return
      fi
    elif [[ "$current_major" -ge 18 ]]; then
      if ! confirm "检测到 Node.js $(node -v)，Claude Code 可用但不是 $REQUIRED_NODE_MAJOR，是否安装/切换到 Node.js $REQUIRED_NODE_MAJOR？" "Y"; then
        return
      fi
    else
      warn "当前 Node.js $(node -v) 低于 Claude Code npm 包要求的 Node.js 18，将安装 Node.js $REQUIRED_NODE_MAJOR。"
    fi
  else
    info "未检测到 Node.js，将安装 Node.js $REQUIRED_NODE_MAJOR。"
  fi

  install_nvm
  info "通过 nvm 安装/切换 Node.js $REQUIRED_NODE_MAJOR"
  nvm install "$REQUIRED_NODE_MAJOR"
  nvm alias default "$REQUIRED_NODE_MAJOR" >/dev/null
  nvm use "$REQUIRED_NODE_MAJOR" >/dev/null
  success "Node.js 已就绪：$(node -v)，npm：$(npm -v)"
}

npm_global_bin() {
  local prefix
  prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "$prefix" && "$prefix" != "undefined" ]]; then
    printf '%s/bin' "$prefix"
  else
    return 1
  fi
}

ensure_npm_global_path() {
  need_cmd npm || fatal "未检测到 npm。"
  local prefix bin
  prefix="$(npm config get prefix)"
  bin="$prefix/bin"

  if [[ ! -w "$prefix" && "$prefix" =~ ^/(usr|opt|usr/local) ]]; then
    warn "npm 全局目录不可写：$prefix。将改为用户级目录 $HOME/.npm-global。"
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    export PATH="$HOME/.npm-global/bin:$PATH"
  else
    export PATH="$bin:$PATH"
  fi
}

find_real_claude_bin() {
  local candidate=""
  local npm_bin=""
  npm_bin="$(npm_global_bin || true)"

  if [[ -n "$npm_bin" && -x "$npm_bin/claude" && "$npm_bin/claude" != "$CLAUDE_WRAPPER" ]]; then
    printf '%s' "$npm_bin/claude"
    return 0
  fi

  local old_ifs="$IFS"
  IFS=':'
  for dir in $PATH; do
    candidate="$dir/claude"
    if [[ -x "$candidate" && "$candidate" != "$CLAUDE_WRAPPER" ]]; then
      if ! grep -q 'CLAUDE_TEAM_WRAPPER' "$candidate" 2>/dev/null; then
        IFS="$old_ifs"
        printf '%s' "$candidate"
        return 0
      fi
    fi
  done
  IFS="$old_ifs"
  return 1
}

install_claude_code() {
  ensure_npm_global_path

  local real_claude=""
  real_claude="$(find_real_claude_bin || true)"
  if [[ -n "$real_claude" ]]; then
    success "Claude Code 已安装：$($real_claude --version 2>/dev/null || printf 'version unknown')"
    export CLAUDE_TEAM_REAL_BIN="$real_claude"
    return
  fi

  info "安装 Claude Code：npm install -g $CLAUDE_NPM_PACKAGE"
  npm install -g "$CLAUDE_NPM_PACKAGE"

  local bin
  bin="$(npm_global_bin || true)"
  if [[ -n "$bin" ]]; then
    export PATH="$bin:$PATH"
  fi

  real_claude="$(find_real_claude_bin || true)"
  [[ -n "$real_claude" ]] || fatal "Claude Code 安装完成，但真实 claude 命令仍不在 PATH。请检查 npm 全局 bin 目录：${bin:-unknown}。"
  export CLAUDE_TEAM_REAL_BIN="$real_claude"
  success "Claude Code 安装成功：$($real_claude --version 2>/dev/null || printf 'version unknown')"
}

select_profile_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) profile_file="$HOME/.zshrc" ;;
    bash)
      if [[ "$os_name" == "macos" ]]; then
        profile_file="$HOME/.bash_profile"
      else
        profile_file="$HOME/.bashrc"
      fi
      ;;
    fish)
      warn "Fish shell 不支持 Bash 配置文件语法，无法自动注入环境变量。"
      info "安装完成后，请将以下内容添加到 ~/.config/fish/config.fish："
      info ""
      info "  fish_add_path \$HOME/.claude-code/bin \$HOME/.local/bin"
      info "  if test -f \$HOME/.claude-code/env; bass source \$HOME/.claude-code/env; end"
      info ""
      warn "nvm 在 fish 中需额外工具（如 bass 或 nvm.fish），请参考 nvm 文档。"
      profile_file="$HOME/.bashrc"
      ;;
    *)
      if [[ -f "$HOME/.zshrc" ]]; then
        profile_file="$HOME/.zshrc"
      else
        profile_file="$HOME/.bashrc"
      fi
      ;;
  esac
  touch "$profile_file"
  info "将更新 shell 配置文件：$profile_file"
}

remove_old_profile_block() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v begin="$PROFILE_MARKER_BEGIN" -v end="$PROFILE_MARKER_END" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    skip != 1 {print}
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_profile_block() {
  select_profile_file
  remove_old_profile_block "$profile_file"

  local npm_bin=""
  npm_bin="$(npm_global_bin || true)"

  {
    printf '\n%s\n' "$PROFILE_MARKER_BEGIN"
    printf 'export PATH="$HOME/.claude-code/bin:$HOME/.local/bin:$PATH"\n'
    if [[ -n "$npm_bin" ]]; then
      printf 'export PATH="%s:$PATH"\n' "$npm_bin"
    fi
    printf '[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"\n'
    printf '[ -f "$HOME/.claude-code/env" ] && . "$HOME/.claude-code/env"\n'
    printf '%s\n' "$PROFILE_MARKER_END"
  } >> "$profile_file"

  success "已写入启动配置：$profile_file"
}

read_api_secret() {
  local value="" value2=""
  while true; do
    printf "请输入 API Key / Auth Token：" >&2
    if read_user_input -r -s value; then
      printf "\n" >&2
    else
      read_user_input -r value
    fi
    if [[ -z "$value" ]]; then
      warn "API Key 不能为空。"
      continue
    fi
    printf "请再次输入确认：" >&2
    if read_user_input -r -s value2; then
      printf "\n" >&2
    else
      read_user_input -r value2
    fi
    if [[ "$value" != "$value2" ]]; then
      warn "两次输入不一致，请重新输入。"
      continue
    fi
    printf '%s' "$value"
    return
  done
}

choose_auth_mode() {
  local choice=""
  printf "\n请选择认证变量：\n" >&2
  printf "  1) ANTHROPIC_AUTH_TOKEN  作为 Authorization: Bearer <token> 发送，通常适合 API 网关 / 中转服务 [默认]\n" >&2
  printf "  2) ANTHROPIC_API_KEY     作为 X-Api-Key 发送，通常适合原生 Anthropic API\n" >&2
  printf "请输入编号 [1]: " >&2
  read_user_input -r choice || true
  choice="${choice:-1}"
  case "$choice" in
    1) printf 'auth_token' ;;
    2) printf 'api_key' ;;
    *) warn "无效选择，使用默认 ANTHROPIC_AUTH_TOKEN。"; printf 'auth_token' ;;
  esac
}

fetch_model_ids_from_gateway() {
  local base_url="$1"
  local auth_mode="$2"
  local secret="$3"
  local url="$base_url/v1/models"
  local tmp code rc
  local curl_args=()

  if [[ "$DYNAMIC_MODEL_DISCOVERY" != "1" ]]; then
    return 1
  fi
  if ! need_cmd curl; then
    warn "未检测到 curl，无法动态拉取模型列表，将使用内置模型列表。"
    return 1
  fi
  if ! need_cmd node; then
    warn "未检测到 node，无法解析 /v1/models 响应，将使用内置模型列表。"
    return 1
  fi

  tmp="$(mktemp)"
  if [[ "$auth_mode" == "auth_token" ]]; then
    curl_args=(-H "Authorization: Bearer $secret")
  else
    curl_args=(-H "X-Api-Key: $secret")
  fi

  info "拉取真实可用模型列表：GET $url" >&2
  set +e
  code="$(curl -sS -m 15 -o "$tmp" -w '%{http_code}' "${curl_args[@]}" "$url")"
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "模型列表拉取失败，将使用内置模型列表。"
    rm -f "$tmp"
    return 1
  fi

  case "$code" in
    200|201|202) ;;
    401|403)
      warn "/v1/models 返回 HTTP $code，认证可能失败，无法拉取模型列表。"
      rm -f "$tmp"
      return 1
      ;;
    404|405)
      warn "网关可能不支持 /v1/models，无法动态拉取模型列表，将使用内置模型列表。"
      rm -f "$tmp"
      return 1
      ;;
    *)
      warn "/v1/models 返回 HTTP $code，无法动态拉取模型列表，将使用内置模型列表。"
      rm -f "$tmp"
      return 1
      ;;
  esac

  node - "$tmp" <<'NODE'
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
NODE
  local node_rc=$?
  rm -f "$tmp"
  return "$node_rc"
}

prepare_model_menu() {
  local base_url="$1"
  local auth_mode="$2"
  local secret="$3"
  local line=""
  local models_tmp=""
  AVAILABLE_MODELS=()
  MODEL_MENU=()

  models_tmp="$(mktemp)"
  if fetch_model_ids_from_gateway "$base_url" "$auth_mode" "$secret" > "$models_tmp"; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && AVAILABLE_MODELS+=("$line")
    done < "$models_tmp"
  fi
  rm -f "$models_tmp" 2>/dev/null || true

  if [[ ${#AVAILABLE_MODELS[@]} -gt 0 ]]; then
    success "已从网关获取 ${#AVAILABLE_MODELS[@]} 个可用模型。"
    MODEL_MENU=("${AVAILABLE_MODELS[@]}")
  else
    warn "未获取到真实模型列表，使用脚本内置兜底模型列表。"
    MODEL_MENU=("${MODELS[@]}")
  fi
}

filter_model_menu_if_needed() {
  local count="${#MODEL_MENU[@]}"
  local keyword=""
  local lower_keyword=""
  local model=""
  local lower_model=""
  local filtered=()

  if (( count <= MODEL_MENU_MAX_DISPLAY )); then
    return 0
  fi

  printf "
检测到模型数量较多：%d 个。
" "$count" >&2
  printf "请输入筛选关键词，例如 claude、sonnet、qwen、code；直接回车显示前 %s 个：" "$MODEL_MENU_MAX_DISPLAY" >&2
  read_user_input -r keyword || true
  keyword="${keyword:-}"

  if [[ -n "$keyword" ]]; then
    lower_keyword="$(printf '%s' "$keyword" | tr '[:upper:]' '[:lower:]')"
    for model in "${MODEL_MENU[@]}"; do
      lower_model="$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')"
      case "$lower_model" in
        *"$lower_keyword"*) filtered+=("$model") ;;
      esac
    done

    if [[ ${#filtered[@]} -gt 0 ]]; then
      MODEL_MENU=("${filtered[@]}")
      success "筛选后剩余 ${#MODEL_MENU[@]} 个模型。"
    else
      warn "没有模型匹配关键词：$keyword。将显示前 $MODEL_MENU_MAX_DISPLAY 个模型，并保留手动输入选项。"
    fi
  fi
}

choose_model() {
  local i choice="" custom=""
  local display_count=0
  local total_count=0

  if [[ ${#MODEL_MENU[@]} -eq 0 ]]; then
    MODEL_MENU=("${MODELS[@]}")
  fi

  filter_model_menu_if_needed

  if (( DEFAULT_MODEL_INDEX < 1 || DEFAULT_MODEL_INDEX > ${#MODEL_MENU[@]} )); then
    DEFAULT_MODEL_INDEX=1
  fi

  total_count="${#MODEL_MENU[@]}"
  display_count="$total_count"
  if (( display_count > MODEL_MENU_MAX_DISPLAY )); then
    display_count="$MODEL_MENU_MAX_DISPLAY"
  fi

  printf "
请选择模型：
" >&2
  for ((i=0; i<display_count; i++)); do
    local n=$((i + 1))
    if [[ "$n" -eq "$DEFAULT_MODEL_INDEX" ]]; then
      printf "  %d) %s  [默认]
" "$n" "${MODEL_MENU[$i]}" >&2
    else
      printf "  %d) %s
" "$n" "${MODEL_MENU[$i]}" >&2
    fi
  done
  if (( total_count > display_count )); then
    printf "  ... 已隐藏 %d 个模型；可选择手动输入模型名，或重新运行脚本用关键词筛选。
" "$((total_count - display_count))" >&2
  fi
  printf "  %d) 手动输入模型名
" "$(( display_count + 1 ))" >&2
  printf "请输入编号 [$DEFAULT_MODEL_INDEX]: " >&2
  read_user_input -r choice || true
  choice="${choice:-$DEFAULT_MODEL_INDEX}"

  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    if (( choice >= 1 && choice <= display_count )); then
      printf '%s' "${MODEL_MENU[$((choice - 1))]}"
      return
    elif (( choice == display_count + 1 )); then
      printf "请输入模型名：" >&2
      read_user_input -r custom
      [[ -n "$custom" ]] || fatal "模型名不能为空。"
      printf '%s' "$custom"
      return
    fi
  fi

  warn "无效选择，使用默认模型：${MODEL_MENU[$((DEFAULT_MODEL_INDEX - 1))]}"
  printf '%s' "${MODEL_MENU[$((DEFAULT_MODEL_INDEX - 1))]}"
}

validate_base_url_format() {
  local url="$1"
  [[ "$url" =~ ^https?:// ]] || fatal "BASE_URL 必须以 http:// 或 https:// 开头。当前值：$url"
}

ask_base_url() {
  local url="$TEAM_BASE_URL"
  local maybe=""
  if [[ -z "$url" ]]; then
    printf "请输入 ANTHROPIC_BASE_URL（API 网关根地址，不需要追加 /v1、/v1/messages 或其他路径），例如 https://api.example.com: " >&2
    read_user_input -r url
  else
    printf "ANTHROPIC_BASE_URL 使用 %s（只需要网关根地址，不需要追加 /v1、/v1/messages 或其他路径），是否修改？直接回车表示不修改：" "$url" >&2
    read_user_input -r maybe || true
    if [[ -n "${maybe:-}" ]]; then
      url="$maybe"
    fi
  fi
  [[ -n "$url" ]] || fatal "ANTHROPIC_BASE_URL 不能为空。"
  url="${url%/}"
  validate_base_url_format "$url"
  printf '%s' "$url"
}

write_env_file() {
  local base_url="$1"
  local auth_mode="$2"
  local secret="$3"
  local model="$4"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  local tmp
  tmp="$(mktemp)"
  {
    printf '# Generated by claude-bootstrap-v1.2.sh. Do not commit this file.\n'
    printf 'export ANTHROPIC_BASE_URL=%s\n' "$(shell_quote "$base_url")"
    if [[ "$auth_mode" == "auth_token" ]]; then
      printf 'export ANTHROPIC_AUTH_TOKEN=%s\n' "$(shell_quote "$secret")"
      printf 'unset ANTHROPIC_API_KEY\n'
    else
      printf 'export ANTHROPIC_API_KEY=%s\n' "$(shell_quote "$secret")"
      printf 'unset ANTHROPIC_AUTH_TOKEN\n'
    fi
    printf 'export ANTHROPIC_MODEL=%s\n' "$(shell_quote "$model")"
    printf 'export ANTHROPIC_CUSTOM_MODEL_OPTION=%s\n' "$(shell_quote "$model")"
    printf 'export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=%s\n' "$(shell_quote "$ENABLE_GATEWAY_MODEL_DISCOVERY")"
    printf 'export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=%s\n' "$(shell_quote "$CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT")"
  } > "$tmp"
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
  chmod 600 "$ENV_FILE"
  success "已写入环境变量：$ENV_FILE"
}

write_claude_settings_json() {
  local base_url="$1"
  local auth_mode="$2"
  local secret="$3"
  local model="$4"

  mkdir -p "$HOME/.claude"
  chmod 700 "$HOME/.claude"

  CLAUDE_TEAM_SETTINGS_FILE="$CLAUDE_SETTINGS_JSON" \
  CLAUDE_TEAM_BASE_URL="$base_url" \
  CLAUDE_TEAM_AUTH_MODE="$auth_mode" \
  CLAUDE_TEAM_SECRET="$secret" \
  CLAUDE_TEAM_MODEL="$model" \
  CLAUDE_TEAM_GATEWAY_MODEL_DISCOVERY="$ENABLE_GATEWAY_MODEL_DISCOVERY" \
  CLAUDE_TEAM_ENV_SCRUB="$CLAUDE_CODE_SUBPROCESS_ENV_SCRUB_DEFAULT" \
  node <<'NODE'
const fs = require('fs');
const path = require('path');
const file = process.env.CLAUDE_TEAM_SETTINGS_FILE;
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
env.ANTHROPIC_BASE_URL = process.env.CLAUDE_TEAM_BASE_URL;
if (process.env.CLAUDE_TEAM_AUTH_MODE === 'auth_token') {
  env.ANTHROPIC_AUTH_TOKEN = process.env.CLAUDE_TEAM_SECRET;
  delete env.ANTHROPIC_API_KEY;
} else {
  env.ANTHROPIC_API_KEY = process.env.CLAUDE_TEAM_SECRET;
  delete env.ANTHROPIC_AUTH_TOKEN;
}
env.ANTHROPIC_MODEL = process.env.CLAUDE_TEAM_MODEL;
env.ANTHROPIC_CUSTOM_MODEL_OPTION = process.env.CLAUDE_TEAM_MODEL;
env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = process.env.CLAUDE_TEAM_GATEWAY_MODEL_DISCOVERY || '1';
env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB = process.env.CLAUDE_TEAM_ENV_SCRUB || '0';
if (data.skipWebFetchPreflight === undefined) data.skipWebFetchPreflight = true;
data.env = env;
fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
fs.writeFileSync(file, JSON.stringify(data, null, 2) + '\n', { mode: 0o600 });
fs.chmodSync(file, 0o600);
NODE
  success "已同步 Claude Code 官方配置：$CLAUDE_SETTINGS_JSON"
}

sync_settings_from_existing_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    return 0
  fi
  set +u
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set -u

  local base_url="${ANTHROPIC_BASE_URL:-}"
  local model="${ANTHROPIC_MODEL:-${ANTHROPIC_CUSTOM_MODEL_OPTION:-}}"
  local auth_mode=""
  local secret=""
  if [[ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]]; then
    auth_mode="auth_token"
    secret="$ANTHROPIC_AUTH_TOKEN"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    auth_mode="api_key"
    secret="$ANTHROPIC_API_KEY"
  fi

  if [[ -n "$base_url" && -n "$model" && -n "$auth_mode" && -n "$secret" ]]; then
    write_claude_settings_json "$base_url" "$auth_mode" "$secret" "$model"
  else
    warn "已有 env 文件信息不完整，无法同步到 $CLAUDE_SETTINGS_JSON。"
  fi
}

create_claude_wrapper() {
  [[ "$CREATE_CLAUDE_WRAPPER" == "1" ]] || return 0
  local real_claude="${CLAUDE_TEAM_REAL_BIN:-}"
  if [[ -z "$real_claude" || ! -x "$real_claude" ]]; then
    real_claude="$(find_real_claude_bin || true)"
  fi
  if [[ -z "$real_claude" ]]; then
    warn "无法定位真实 claude 二进制，跳过 claude wrapper 创建。"
    return 0
  fi

  mkdir -p "$WRAPPER_DIR"
  chmod 700 "$CONFIG_DIR" "$WRAPPER_DIR"
  cat > "$CLAUDE_WRAPPER" <<WRAPPER
#!/usr/bin/env bash
# CLAUDE_TEAM_WRAPPER
set -euo pipefail
REAL_CLAUDE_BIN=$(shell_quote "$real_claude")
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"
[ -f "\$HOME/.claude-code/env" ] && . "\$HOME/.claude-code/env"
if [[ ! -x "\$REAL_CLAUDE_BIN" ]]; then
  echo "[ERROR] real claude binary not found: \$REAL_CLAUDE_BIN" >&2
  echo "Please rerun the install script." >&2
  exit 1
fi
exec "\$REAL_CLAUDE_BIN" "\$@"
WRAPPER
  chmod +x "$CLAUDE_WRAPPER"
  success "已创建 claude wrapper：$CLAUDE_WRAPPER"
}

validate_gateway() {
  local base_url="$1"
  local auth_mode="$2"
  local secret="$3"
  local model="$4"
  local url="$base_url/v1/models"
  local tmp code curl_args=()

  if ! need_cmd curl; then
    warn "未检测到 curl，跳过网关验证。"
    return 0
  fi

  tmp="$(mktemp)"
  if [[ "$auth_mode" == "auth_token" ]]; then
    curl_args=(-H "Authorization: Bearer $secret")
  else
    curl_args=(-H "X-Api-Key: $secret")
  fi

  info "验证网关连通性：GET $url"
  set +e
  code="$(curl -sS -m 15 -o "$tmp" -w '%{http_code}' "${curl_args[@]}" "$url")"
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    warn "网关验证请求失败。可能是网络、证书或 BASE_URL 问题。脚本会继续。"
    rm -f "$tmp"
    return 0
  fi

  case "$code" in
    200|201|202)
      success "网关认证通过，/v1/models 返回 HTTP $code。"
      if grep -Fq -- "$model" "$tmp" 2>/dev/null; then
        success "模型列表中检测到当前模型：$model"
      else
        warn "模型列表中未直接匹配到 $model。若 API 网关使用映射模型名，可忽略。"
      fi
      ;;
    401|403)
      warn "网关返回 HTTP $code，API Key/Auth Token 可能不可用。"
      if confirm "是否重新输入 Key 并重写配置？" "Y"; then
        local new_secret
        new_secret="$(read_api_secret)"
        write_env_file "$base_url" "$auth_mode" "$new_secret" "$model"
        write_claude_settings_json "$base_url" "$auth_mode" "$new_secret" "$model"
        validate_gateway "$base_url" "$auth_mode" "$new_secret" "$model"
      fi
      ;;
    404|405)
      warn "网关返回 HTTP $code，可能不支持 /v1/models。跳过模型接口验证。"
      ;;
    *)
      warn "网关返回 HTTP $code。响应已忽略，脚本会继续。"
      ;;
  esac
  rm -f "$tmp"
}

configure_claude() {
  if [[ -f "$ENV_FILE" ]]; then
    warn "检测到已有配置：$ENV_FILE"
    if ! confirm "是否覆盖已有 Claude Code 配置？" "N"; then
      success "保留已有配置。"
      sync_settings_from_existing_env
      write_profile_block
      create_claude_wrapper
      return
    fi
  fi

  local base_url auth_mode secret model
  base_url="$(ask_base_url)"
  auth_mode="$(choose_auth_mode)"
  secret="$(read_api_secret)"
  prepare_model_menu "$base_url" "$auth_mode" "$secret"
  model="$(choose_model)"

  write_env_file "$base_url" "$auth_mode" "$secret" "$model"
  write_claude_settings_json "$base_url" "$auth_mode" "$secret" "$model"
  write_profile_block
  create_claude_wrapper
  validate_gateway "$base_url" "$auth_mode" "$secret" "$model"
}

print_summary() {
  cat <<SUMMARY

============================================================
Claude Code 安装配置完成
============================================================

当前环境变量配置文件：
  $ENV_FILE

当前 Claude Code 官方配置文件：
  $CLAUDE_SETTINGS_JSON

当前 shell 配置文件：
  $profile_file

请执行以下命令让当前终端立即生效：
  source $profile_file
  hash -r

启动 Claude Code：
  claude


注意：
  - API Key/Auth Token 已写入 $ENV_FILE 和 $CLAUDE_SETTINGS_JSON，并设置为 chmod 600。
  - 默认 CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=0，避免 Linux/LXC 缺少 bubblewrap 时启动失败。
  - 如果你是通过 curl | bash 执行，脚本无法直接修改父 shell 环境；建议执行 source 配置文件或重新打开终端。
============================================================
SUMMARY
}

main() {
  check_platform
  check_memory
  setup_sudo
  install_basic_deps
  ensure_node22
  install_claude_code
  configure_claude
  print_summary
}

main "$@"
