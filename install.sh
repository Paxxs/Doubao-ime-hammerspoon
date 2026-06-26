#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_INIT="$SCRIPT_DIR/init.lua"
TARGET_DIR="$HOME/.hammerspoon"
TARGET_INIT="$TARGET_DIR/init.lua"
FORCE_REPLACE=0
SKIP_BREW_INSTALL="${SKIP_BREW_INSTALL:-0}"

print_help() {
  cat <<'EOF'
用法：
  ./install.sh
  ./install.sh --force
  ./install.sh --help

说明：
  1. 使用 Homebrew 安装 Hammerspoon
  2. 将当前项目中的 init.lua 拷贝到 ~/.hammerspoon/init.lua
  3. 如果目标位置已有不同内容的脚本，默认会询问你是否替换

参数：
  --force    发现已有不同脚本时直接替换
  --help     显示帮助信息
EOF
}

info() {
  printf '[信息] %s\n' "$1"
}

warn() {
  printf '[提示] %s\n' "$1"
}

error() {
  printf '[错误] %s\n' "$1" >&2
}

confirm_replace() {
  local answer
  printf '检测到 %s 已存在且内容不同，是否替换？[y/N] ' "$TARGET_INIT"
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

backup_existing_file() {
  local backup_path
  backup_path="${TARGET_INIT}.bak.$(date '+%Y%m%d-%H%M%S')"
  cp "$TARGET_INIT" "$backup_path"
  info "已备份原有配置到：$backup_path"
}

install_hammerspoon() {
  if [[ "$SKIP_BREW_INSTALL" == "1" ]]; then
    warn "已跳过 brew 安装步骤（SKIP_BREW_INSTALL=1）"
    return 0
  fi

  if ! command -v brew >/dev/null 2>&1; then
    error '未检测到 Homebrew，请先安装 Homebrew：https://brew.sh/'
    exit 1
  fi

  info '开始使用 Homebrew 安装 Hammerspoon...'
  brew install --cask hammerspoon
}

copy_init_lua() {
  mkdir -p "$TARGET_DIR"

  if [[ ! -f "$TARGET_INIT" ]]; then
    cp "$SOURCE_INIT" "$TARGET_INIT"
    info "已复制初始化脚本到：$TARGET_INIT"
    return 0
  fi

  if cmp -s "$SOURCE_INIT" "$TARGET_INIT"; then
    info "目标位置已经存在相同内容的脚本，无需替换：$TARGET_INIT"
    return 0
  fi

  if [[ "$FORCE_REPLACE" -eq 1 ]]; then
    warn '检测到已有不同配置，因指定了 --force，将直接替换。'
    backup_existing_file
    cp "$SOURCE_INIT" "$TARGET_INIT"
    info "已替换初始化脚本：$TARGET_INIT"
    return 0
  fi

  if confirm_replace; then
    backup_existing_file
    cp "$SOURCE_INIT" "$TARGET_INIT"
    info "已替换初始化脚本：$TARGET_INIT"
  else
    warn '你选择了保留现有脚本，本次不会覆盖 ~/.hammerspoon/init.lua'
  fi
}

print_usage_notes() {
  cat <<'EOF'

安装完成。接下来请这样使用：

1. 打开 Hammerspoon。
2. 第一次运行时，根据系统提示为 Hammerspoon 授予“辅助功能”权限。
3. 在 Hammerspoon 菜单中选择 “Reload Config” 重新加载配置。
4. 在豆包输入法设置里，把“语音唤起方式”设为 Fn（地球键）。
5. 使用：按一下右 Command 切到豆包 → 按 Fn 说话 → 再按 Fn 结束 → 再按一下右 Command 切回原输入法。
   （脚本只负责切输入法；语音由豆包的 Fn 触发。）

如果没有生效，请检查：
- 豆包输入法已经安装并可正常使用。
- 豆包设置里语音唤起方式已设为 Fn。
- 当前 init.lua 中的输入法 ID 与你本机的豆包输入法一致。
- Hammerspoon 已获得“辅助功能”权限。
EOF
}

main() {
  case "${1:-}" in
    --force)
      FORCE_REPLACE=1
      ;;
    --help)
      print_help
      exit 0
      ;;
    "")
      ;;
    *)
      error "不支持的参数：$1"
      print_help
      exit 1
      ;;
  esac

  if [[ ! -f "$SOURCE_INIT" ]]; then
    error "未找到源初始化脚本：$SOURCE_INIT"
    exit 1
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    error '该脚本仅支持在 macOS 上运行。'
    exit 1
  fi

  info '开始安装 Doubao IME Hammerspoon 配置...'
  install_hammerspoon
  copy_init_lua
  print_usage_notes
}

main "${1:-}"
