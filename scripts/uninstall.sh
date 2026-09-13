#!/bin/zsh
# 卸载中英快译。应用移入废纸篓而非直接删除，可回滚。
set -euo pipefail

LABEL="com.local.bilingual-translator"
APP="$HOME/Applications/中英快译.app"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "$APP" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
[[ -d "$APP" ]] && mv "$APP" "$HOME/.Trash/中英快译-$(date +%Y%m%d%H%M%S).app"
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Logs/BilingualTranslator.log"
defaults delete "$LABEL" >/dev/null 2>&1 || true

print "已卸载。签名证书仍保留在登录钥匙串中，如需删除："
print "  security delete-certificate -c \"BilingualTranslator Local Code Signing\""
