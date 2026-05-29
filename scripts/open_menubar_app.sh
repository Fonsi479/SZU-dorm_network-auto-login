#!/bin/zsh
set -u

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_PATH="${PROJECT_ROOT}/dist/${APP_NAME}.app"
LOG_DIR="${PROJECT_ROOT}/logs"
LOG_FILE="${LOG_DIR}/menubar-open.log"
MENUBAR_LOG_FILE="${LOG_DIR}/menubar.log"
USER_LOG_DIR="${HOME}/Library/Logs/szu-netlogin"
MENUBAR_ERR_LOG_FILE="${USER_LOG_DIR}/menubar-err.log"

mkdir -p "${LOG_DIR}"
mkdir -p "${USER_LOG_DIR}"

log() {
  local message="$1"
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') ${message}"
  echo "${message}"
  echo "${line}" >> "${LOG_FILE}"
}

log "准备打开 SZU Dorm 状态栏 App。"
log "项目目录：${PROJECT_ROOT}"

export SZU_NETLOGIN_HOME="${SZU_NETLOGIN_HOME:-${PROJECT_ROOT}}"
log "使用项目目录环境变量：SZU_NETLOGIN_HOME=${SZU_NETLOGIN_HOME}"

if command -v launchctl >/dev/null 2>&1; then
  if launchctl setenv SZU_NETLOGIN_HOME "${SZU_NETLOGIN_HOME}" >> "${LOG_FILE}" 2>&1; then
    log "已写入当前 macOS 登录会话环境变量。"
  else
    log "写入 macOS 登录会话环境变量失败，将继续尝试打开。"
  fi
else
  log "未找到 launchctl，将只使用当前脚本环境变量。"
fi

if [[ -d "${APP_PATH}" ]]; then
  log "发现 App：${APP_PATH}"
  if xattr -p com.apple.quarantine "${APP_PATH}" >/dev/null 2>&1; then
    log "提醒：App 带有 macOS quarantine 标记。如无法打开，请按 README 手动处理。"
  fi

  log "正在用 open -n 打开 App，并直接传入项目目录环境变量。"
  if open -n \
    --env "SZU_NETLOGIN_HOME=${SZU_NETLOGIN_HOME}" \
    --stderr "${MENUBAR_ERR_LOG_FILE}" \
    "${APP_PATH}" >> "${LOG_FILE}" 2>&1; then
    log "已请求 macOS 打开 App，请查看屏幕顶部菜单栏的 SZU Dorm。"
    exit 0
  fi

  log "open 打开失败，将回退到 python3 模式。"
else
  log "未找到 App：${APP_PATH}"
  log "将回退到 python3 模式启动状态栏客户端。"
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "启动失败：找不到 python3。"
  exit 1
fi

log "正在用 python3 -m src.szu_netlogin.menubar_app 启动。"
cd "${PROJECT_ROOT}" || exit 1
python3 -m src.szu_netlogin.menubar_app >> "${MENUBAR_LOG_FILE}" 2>&1
status=$?
log "python3 模式已退出，退出码：${status}"
exit "${status}"
