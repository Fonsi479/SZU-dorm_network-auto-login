#!/bin/zsh
set -euo pipefail

LABEL="com.szu-netlogin.dorm-drcom"
DOMAIN="gui/$(id -u)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_PLIST="${PROJECT_ROOT}/launchd/${LABEL}.plist"
TARGET_DIR="${HOME}/Library/LaunchAgents"
TARGET_PLIST="${TARGET_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/szu-netlogin"
PYTHON_BIN="${PYTHON_BIN:-$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || command -v python3 || true)}"
APP_EXECUTABLE="${SZU_NETLOGIN_APP_EXECUTABLE:-}"
CONFIG_HOME="${SZU_NETLOGIN_HOME:-${PROJECT_ROOT}}"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "未找到 python3。请先安装 Python，或用 PYTHON_BIN=/path/to/python3 指定。"
  exit 1
fi

if [[ -z "${APP_EXECUTABLE}" ]] && ! "${PYTHON_BIN}" -c 'import requests' >/dev/null 2>&1; then
  echo "当前 Python 缺少依赖 requests：${PYTHON_BIN}" >&2
  echo "请先运行：${PYTHON_BIN} -m pip install -r requirements.txt" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}"
mkdir -p "${LOG_DIR}"

export SOURCE_PLIST TARGET_PLIST PROJECT_ROOT LOG_DIR PYTHON_BIN APP_EXECUTABLE CONFIG_HOME
"${PYTHON_BIN}" -c '
import os
import plistlib
from pathlib import Path

source_plist = Path(os.environ["SOURCE_PLIST"])
target_plist = Path(os.environ["TARGET_PLIST"])
project_root = os.environ["PROJECT_ROOT"]
log_dir = os.environ["LOG_DIR"]
python_bin = os.environ["PYTHON_BIN"]
app_executable = os.environ["APP_EXECUTABLE"]
config_home = os.environ["CONFIG_HOME"]

payload = plistlib.loads(source_plist.read_bytes())
payload["ProgramArguments"] = (
    [app_executable, "--szu-netlogin-control", "check-and-login"]
    if app_executable
    else [python_bin, "-m", "src.szu_netlogin.login", "--check-and-login"]
)
payload["WorkingDirectory"] = config_home
payload["StandardOutPath"] = f"{log_dir}/launchagent.out.log"
payload["StandardErrorPath"] = f"{log_dir}/launchagent.err.log"
environment = payload.get("EnvironmentVariables")
if not isinstance(environment, dict):
    environment = {}
environment["SZU_NETLOGIN_HOME"] = config_home
payload["EnvironmentVariables"] = environment

target_plist.write_bytes(plistlib.dumps(payload, sort_keys=False))
'
chmod 644 "${TARGET_PLIST}"

PASSWORD_ENV_NAME="${SZU_NETLOGIN_PASSWORD_ENV_NAME:-$(cd "${CONFIG_HOME}" 2>/dev/null && "${PYTHON_BIN}" -c 'from src.szu_netlogin.config import get_password_env_name, load_config; print(get_password_env_name(load_config()))' 2>/dev/null || true)}"
PASSWORD_VALUE=""
if [[ -n "${PASSWORD_ENV_NAME}" ]]; then
  # printenv returns a non-zero status for an unset variable.  Reading it this
  # way keeps `set -u` from turning an optional password into a script crash.
  PASSWORD_VALUE="$(printenv "${PASSWORD_ENV_NAME}" 2>/dev/null || true)"
fi
if [[ -n "${PASSWORD_ENV_NAME}" && -n "${PASSWORD_VALUE}" ]]; then
  launchctl setenv "${PASSWORD_ENV_NAME}" "${PASSWORD_VALUE}"
  echo "已把当前终端里的 ${PASSWORD_ENV_NAME} 交给本次用户登录会话。"
else
  echo "提醒：当前终端没有配置的密码环境变量 ${PASSWORD_ENV_NAME:-SZU_NET_PASSWORD}。"
  echo "只有当 config.yaml 使用 security.password_source: env 时，才需要设置它。"
fi

launchctl bootout "${DOMAIN}" "${TARGET_PLIST}" >/dev/null 2>&1 || true
launchctl bootstrap "${DOMAIN}" "${TARGET_PLIST}"
launchctl kickstart -k "${DOMAIN}/${LABEL}"

echo "已安装并加载：${LABEL}"
echo "Python：${PYTHON_BIN}"
echo "项目目录：${PROJECT_ROOT}"
echo
echo "查看状态："
echo "launchctl print ${DOMAIN}/${LABEL}"
echo
echo "查看登录日志："
echo "tail -n 80 '${LOG_DIR}/netlogin.log'"
echo "如果感觉安装后没反应，优先看这个文件：${LOG_DIR}/netlogin.log"
echo
echo "查看 launchd 输出："
echo "tail -n 80 '${LOG_DIR}/launchagent.out.log'"
echo "tail -n 80 '${LOG_DIR}/launchagent.err.log'"
