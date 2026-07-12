#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"

[[ -d "${APP_BUNDLE}" ]] || { echo "找不到 App：${APP_BUNDLE}" >&2; exit 1; }
[[ -x "${EXECUTABLE}" ]] || { echo "App 可执行文件不存在或不可执行。" >&2; exit 1; }

plutil -lint "${INFO_PLIST}" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")"
UI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${INFO_PLIST}")"

[[ "${VERSION}" == "2.0.0" ]] || { echo "版本错误：${VERSION}" >&2; exit 1; }
[[ "${BUILD}" == "1" ]] || { echo "构建号错误：${BUILD}" >&2; exit 1; }
[[ "${IDENTIFIER}" == "com.szu-netlogin.dorm-login" ]] || { echo "Bundle ID 错误：${IDENTIFIER}" >&2; exit 1; }
[[ "${MIN_SYSTEM}" == "13.0" ]] || { echo "最低系统版本错误：${MIN_SYSTEM}" >&2; exit 1; }
[[ "${UI_ELEMENT}" == "true" ]] || { echo "App 未配置为状态栏应用。" >&2; exit 1; }

VERSION_OUTPUT="$("${EXECUTABLE}" --version)"
[[ "${VERSION_OUTPUT}" == *"native Swift"* ]] || { echo "可执行文件不是预期的 Swift 版本。" >&2; exit 1; }
UI_SMOKE_OUTPUT="$("${EXECUTABLE}" --ui-smoke-test)"
[[ "${UI_SMOKE_OUTPUT}" == *"初始化：正常"* ]] || { echo "状态栏 UI 初始化检查失败。" >&2; exit 1; }

if otool -L "${EXECUTABLE}" | grep -Eiq 'python|libpython'; then
  echo "App 仍链接了 Python 运行时。" >&2
  exit 1
fi
for framework in AppKit Security ServiceManagement SwiftUI; do
  if ! otool -L "${EXECUTABLE}" | grep -q "/${framework}.framework/"; then
    echo "原生可执行文件未链接必要框架：${framework}" >&2
    exit 1
  fi
done
if find "${APP_BUNDLE}/Contents" -iname '*python*' -print -quit | grep -q .; then
  echo "App 包中仍包含 Python 文件。" >&2
  exit 1
fi

codesign --verify --deep --strict "${APP_BUNDLE}"
bash "${PROJECT_ROOT}/scripts/run_swift_checks.sh"

SIZE="$(du -sh "${APP_BUNDLE}" | awk '{print $1}')"
echo "App 验证通过：${APP_BUNDLE}"
echo "版本：${VERSION}（${BUILD}）"
echo "架构：$(lipo -archs "${EXECUTABLE}")"
echo "大小：${SIZE}"
echo "Python 运行时：未包含"
