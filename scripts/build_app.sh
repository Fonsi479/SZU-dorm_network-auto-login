#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
ENTRY="src/szu_netlogin/menubar_app.py"
SPEC="packaging/SZUDormLogin.spec"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
CURRENT_DIR="$(pwd -P)"

if [[ "${CURRENT_DIR}" != "${PROJECT_ROOT}" ]]; then
  echo "请在项目根目录运行：bash scripts/build_app.sh" >&2
  echo "当前目录：${CURRENT_DIR}" >&2
  echo "项目根目录：${PROJECT_ROOT}" >&2
  exit 1
fi

if [[ ! -f "${ENTRY}" ]]; then
  echo "找不到入口文件：${ENTRY}" >&2
  exit 1
fi

if ! command -v pyinstaller >/dev/null 2>&1; then
  echo "未安装 PyInstaller。请先运行：python3 -m pip install pyinstaller" >&2
  exit 1
fi

if [[ ! -f "${SPEC}" ]]; then
  echo "找不到 PyInstaller spec：${SPEC}" >&2
  exit 1
fi

# SZUDormLogin.spec uses console=False, the spec-file equivalent of --windowed.
export SZU_NETLOGIN_HOME="${PROJECT_ROOT}"
pyinstaller --noconfirm --clean "${SPEC}"

if [[ ! -d "dist/${APP_NAME}.app" ]]; then
  echo "打包失败：未生成 dist/${APP_NAME}.app" >&2
  exit 1
fi

if [[ -d "dist/${APP_NAME}" ]]; then
  rm -rf "dist/${APP_NAME}"
fi

echo "打包完成：dist/${APP_NAME}.app"
