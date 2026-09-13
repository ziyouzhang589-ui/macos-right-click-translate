#!/bin/zsh
# 编译并安装中英快译到 ~/Applications，交给 launchd 常驻。可重复运行，用于更新。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="中英快译.app"
LABEL="com.local.bilingual-translator"
INSTALL_DIR="$HOME/Applications"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || { print "需要 macOS 15 或更新版本。"; exit 1; }
xcode-select -p >/dev/null 2>&1 || { print "缺少 Xcode 命令行工具，请先运行：xcode-select --install"; exit 1; }

"$ROOT/scripts/create-signing-cert.sh"

print "== 测试 =="
"$ROOT/app/test.sh"
print "== 编译 =="
"$ROOT/app/build.sh"

print "== 安装 =="
# 先停掉旧版：launchd 托管的实例用 bootout，否则会被立刻拉起。
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
pkill -f "$INSTALL_DIR/$APP_NAME" 2>/dev/null || true
sleep 1

mkdir -p "$INSTALL_DIR"
if [[ -d "$INSTALL_DIR/$APP_NAME" ]]; then
  mv "$INSTALL_DIR/$APP_NAME" "$HOME/.Trash/中英快译-旧版-$(date +%Y%m%d%H%M%S).app"
fi
cp -R "$ROOT/app/.build/$APP_NAME" "$INSTALL_DIR/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME"

if [[ -f "$AGENT" ]]; then
  # 已装过：重新交给 launchd。
  launchctl bootstrap "$GUI" "$AGENT"
else
  # 首次安装：应用启动时会自己写入 launchd 任务并弹出辅助功能授权引导。
  open "$INSTALL_DIR/$APP_NAME"
fi

sleep 5
LOG="$HOME/Library/Logs/BilingualTranslator.log"
if tail -5 "$LOG" 2>/dev/null | grep -q "监听已装上"; then
  print "安装完成，右键翻译已启用。"
else
  print "安装完成。请到 系统设置 → 隐私与安全性 → 辅助功能 打开「中英快译」，打开后立即生效，无需重启。"
fi
