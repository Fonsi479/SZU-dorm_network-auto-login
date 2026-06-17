#!/bin/zsh
set -euo pipefail

DOMAIN="gui/$(id -u)"
TARGET_DIR="${HOME}/Library/LaunchAgents"
PYTHON_BIN="${PYTHON_BIN:-$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null || command -v python3 || true)}"

if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "未找到 LaunchAgents 目录，无需卸载。"
  exit 0
fi

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "未找到 python3，无法扫描 LaunchAgent。"
  exit 1
fi

export TARGET_DIR
MATCHES="$("${PYTHON_BIN}" -c '
import os
import plistlib
from pathlib import Path

target_dir = Path(os.environ["TARGET_DIR"])
known_labels = {
    "com.szu-netlogin.dorm-drcom",
    "com.fonsi.szu-dorm-drcom",
    "com.szu.autologin",
}

for plist_path in sorted(target_dir.glob("*.plist")):
    try:
        payload = plistlib.loads(plist_path.read_bytes())
    except Exception:
        continue

    label = str(payload.get("Label") or plist_path.stem)
    arguments = payload.get("ProgramArguments")
    if not isinstance(arguments, list):
        arguments = []

    haystack = "\n".join([label, *(str(argument) for argument in arguments)]).lower()
    is_this_project = "src.szu_netlogin.login" in haystack and "--check-and-login" in haystack
    is_old_szu_autologin = "szu_auto_login" in haystack or "com.szu.autologin" in haystack

    if label in known_labels or is_this_project or is_old_szu_autologin:
        print(f"{label}\t{plist_path}")
')"

if [[ -z "${MATCHES}" ]]; then
  echo "未找到校园网自动登录 LaunchAgent。"
  echo "项目文件和 config.yaml 都没有删除。"
  exit 0
fi

removed=0
while IFS=$'\t' read -r label plist_path; do
  if [[ -z "${plist_path}" ]]; then
    continue
  fi

  launchctl bootout "${DOMAIN}" "${plist_path}" >/dev/null 2>&1 || true
  rm -f "${plist_path}"
  echo "已卸载：${label} (${plist_path})"
  (( removed += 1 ))
done <<< "${MATCHES}"

echo "共卸载 ${removed} 个校园网自动登录 LaunchAgent。"
echo "项目文件和 config.yaml 都没有删除。"
