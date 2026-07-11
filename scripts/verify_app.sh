#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_PATH="${PROJECT_ROOT}/dist/${APP_NAME}.app"
EXEC_PATH="${APP_PATH}/Contents/MacOS/${APP_NAME}"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"
MENUBAR_LOG="${PROJECT_ROOT}/logs/menubar.log"
APP_HOME="${HOME}/Library/Application Support/szu-netlogin"

fail() {
  echo "验证失败：$1" >&2
  exit 1
}

echo "项目目录：${PROJECT_ROOT}"
echo "App 路径：${APP_PATH}"

[[ -d "${APP_PATH}" ]] || fail "找不到 app，请先运行 bash scripts/build_app.sh"
[[ -f "${INFO_PLIST}" ]] || fail "找不到 Info.plist"
[[ -x "${EXEC_PATH}" ]] || fail "主程序不存在或没有执行权限：${EXEC_PATH}"
[[ -f "${APP_PATH}/Contents/Resources/scripts/install_launchagent.sh" ]] || fail "App 缺少 LaunchAgent 安装脚本"
[[ -f "${APP_PATH}/Contents/Resources/launchd/com.szu-netlogin.dorm-drcom.plist" ]] || fail "App 缺少 LaunchAgent plist 模板"

plutil -lint "${INFO_PLIST}" >/dev/null || fail "Info.plist 格式不正确"

if ! "${EXEC_PATH}" --szu-netlogin-control check-dependencies >/dev/null 2>&1; then
  fail "App 控制入口无法启动或依赖缺失"
fi

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
  mkdir -p "${APP_HOME}"
  if [[ ! -f "${APP_HOME}/config.yaml" && -f "${PROJECT_ROOT}/config.yaml" ]]; then
    cp -p "${PROJECT_ROOT}/config.yaml" "${APP_HOME}/config.yaml"
    chmod 600 "${APP_HOME}/config.yaml" 2>/dev/null || true
    echo "已把当前 config.yaml 复制到 App 配置目录：${APP_HOME}"
  fi
  launchctl setenv SZU_NETLOGIN_HOME "${APP_HOME}"
  open "${APP_PATH}"
  echo
  echo "已请求打开 App。它是菜单栏 App，请看屏幕顶部的 SZU Dorm。"
else
  echo
  echo "如需启动 App：scripts/verify_app.sh --launch"
fi
