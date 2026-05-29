#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_PATH="${PROJECT_ROOT}/dist/${APP_NAME}.app"
EXEC_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
MENUBAR_LOG="${PROJECT_ROOT}/logs/menubar.log"

fail() {
  echo "验证失败：$1" >&2
  exit 1
}

echo "项目目录：${PROJECT_ROOT}"
echo "App 路径：${APP_PATH}"

[[ -d "${APP_PATH}" ]] || fail "找不到 app，请先运行 bash scripts/build_app.sh"
[[ -f "${INFO_PLIST}" ]] || fail "找不到 Info.plist"
[[ -x "${EXEC_PATH}" ]] || fail "主程序不存在或没有执行权限：${EXEC_PATH}"

plutil -lint "${INFO_PLIST}" >/dev/null || fail "Info.plist 格式不正确"

echo "App 包检查：通过"

if xattr -p com.apple.quarantine "${APP_PATH}" >/dev/null 2>&1; then
  echo "提醒：App 带有 macOS 隔离标记，首次打开可能需要在 系统设置 -> 隐私与安全性 允许。"
else
  echo "macOS 隔离标记：未发现"
fi

if [[ -f "${MENUBAR_LOG}" ]]; then
  echo
  echo "最近菜单栏日志："
  tail -n 12 "${MENUBAR_LOG}"
else
  echo
  echo "还没有菜单栏日志：${MENUBAR_LOG}"
fi

if [[ "${1:-}" == "--launch" ]]; then
  launchctl setenv SZU_NETLOGIN_HOME "${PROJECT_ROOT}"
  open "${APP_PATH}"
  echo
  echo "已请求打开 App。它是菜单栏 App，请看屏幕顶部的 SZU Dorm。"
else
  echo
  echo "如需启动 App：scripts/verify_app.sh --launch"
fi
