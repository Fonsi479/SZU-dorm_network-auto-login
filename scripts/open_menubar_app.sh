#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

if [[ ! -d "${APP_BUNDLE}" ]]; then
  cd "${PROJECT_ROOT}"
  bash scripts/build_app.sh
fi

existing_pids=()
while IFS= read -r pid; do
  [[ -n "${pid}" ]] && existing_pids+=("${pid}")
done < <(pgrep -f -x "${EXECUTABLE}" 2>/dev/null || true)
if (( ${#existing_pids[@]} > 0 )); then
  echo "正在退出旧的 SZU Dorm Login 进程：${existing_pids[*]}"
  kill -TERM "${existing_pids[@]}" 2>/dev/null || true
  for _ in {1..50}; do
    if ! pgrep -f -x "${EXECUTABLE}" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  remaining_pids=()
  while IFS= read -r pid; do
    [[ -n "${pid}" ]] && remaining_pids+=("${pid}")
  done < <(pgrep -f -x "${EXECUTABLE}" 2>/dev/null || true)
  if (( ${#remaining_pids[@]} > 0 )); then
    echo "旧进程未能正常退出，正在强制结束：${remaining_pids[*]}"
    kill -KILL "${remaining_pids[@]}" 2>/dev/null || true
  fi
fi

open -n "${APP_BUNDLE}"
echo "已启动原生 Swift 状态栏 App，请查看屏幕顶部的 SZU Dorm。"
