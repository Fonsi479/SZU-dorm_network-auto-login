#!/bin/zsh
set -euo pipefail

LABEL="com.szu-netlogin.dorm-drcom"
DOMAIN="gui/$(id -u)"
TARGET_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

launchctl bootout "${DOMAIN}" "${TARGET_PLIST}" >/dev/null 2>&1 || true
rm -f "${TARGET_PLIST}"

echo "已卸载：${LABEL}"
echo "项目文件和 config.yaml 都没有删除。"
