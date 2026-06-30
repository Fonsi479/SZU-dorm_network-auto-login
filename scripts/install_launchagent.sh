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

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "未找到 python3。请先安装 Python，或用 PYTHON_BIN=/path/to/python3 指定。"
  exit 1
fi

if ! "${PYTHON_BIN}" -c 'import requests' >/dev/null 2>&1; then
  echo "当前 Python 缺少依赖 requests：${PYTHON_BIN}" >&2
  echo "请先运行：${PYTHON_BIN} -m pip install -r requirements.txt" >&2
  exit 1
fi

mkdir -p "${TARGET_DIR}"
mkdir -p "${LOG_DIR}"

export SOURCE_PLIST TARGET_PLIST PROJECT_ROOT LOG_DIR PYTHON_BIN
"${PYTHON_BIN}" -c '
import os
import plistlib
from pathlib import Path

source_plist = Path(os.environ["SOURCE_PLIST"])
target_plist = Path(os.environ["TARGET_PLIST"])
project_root = os.environ["PROJECT_ROOT"]
log_dir = os.environ["LOG_DIR"]
python_bin = os.environ["PYTHON_BIN"]

payload = plistlib.loads(source_plist.read_bytes())
payload["ProgramArguments"] = [
    python_bin,
    "-m",
    "src.szu_netlogin.login",
    "--check-and-login",
]
payload["WorkingDirectory"] = project_root
payload["StandardOutPath"] = f"{log_dir}/launchagent.out.log"
payload["StandardErrorPath"] = f"{log_dir}/launchagent.err.log"
environment = payload.get("EnvironmentVariables")
if not isinstance(environment, dict):
    environment = {}
environment["SZU_NETLOGIN_HOME"] = project_root
payload["EnvironmentVariables"] = environment

target_plist.write_bytes(plistlib.dumps(payload, sort_keys=False))
'
chmod 644 "${TARGET_PLIST}"

if [[ -n "${SZU_NET_PASSWORD:-}" ]]; then
  launchctl setenv SZU_NET_PASSWORD "${SZU_NET_PASSWORD}"
  echo "已把当前终端里的 SZU_NET_PASSWORD 交给本次用户登录会话。"
else
  echo "提醒：当前终端没有 SZU_NET_PASSWORD。"
  echo "只有当 config.yaml 使用 security.password_source: env 且 password_env_name: SZU_NET_PASSWORD 时，才需要设置它。"
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
