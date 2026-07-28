#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PACKAGE_ROOT="${PROJECT_ROOT}/macos"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"

if [[ "$(pwd -P)" != "${PROJECT_ROOT}" ]]; then
  echo "请在项目根目录运行：bash scripts/build_app.sh" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "未找到 Swift 编译器。请先安装 Xcode Command Line Tools。" >&2
  exit 1
fi

echo "正在编译原生 Swift macOS 应用…"
swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution --product SZUDormLogin
swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution --product szu-campus-netctl
BIN_DIR="$(swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution --show-bin-path)"
SOURCE_EXECUTABLE="${BIN_DIR}/SZUDormLogin"
SOURCE_CLI="${BIN_DIR}/szu-campus-netctl"

if [[ ! -x "${SOURCE_EXECUTABLE}" ]]; then
  echo "Swift 编译完成，但找不到可执行文件：${SOURCE_EXECUTABLE}" >&2
  exit 1
fi
if [[ ! -x "${SOURCE_CLI}" ]]; then
  echo "Swift 编译完成，但找不到 JSON CLI：${SOURCE_CLI}" >&2
  exit 1
fi

rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${SOURCE_EXECUTABLE}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${SOURCE_CLI}" "${CONTENTS}/MacOS/szu-campus-netctl"
cp "${PACKAGE_ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "${PROJECT_ROOT}/config.example.json" "${CONTENTS}/Resources/config.example.json"
cp "${PROJECT_ROOT}/campus-providers.example.json" \
  "${CONTENTS}/Resources/campus-providers.example.json"
chmod 755 "${CONTENTS}/MacOS/${APP_NAME}" "${CONTENTS}/MacOS/szu-campus-netctl"

plutil -lint "${CONTENTS}/Info.plist" >/dev/null
codesign --force --deep --sign - "${APP_BUNDLE}" >/dev/null

echo "打包完成：${APP_BUNDLE}"
echo "实现：纯 Swift / AppKit / SwiftUI（不包含 Python 运行时）"
