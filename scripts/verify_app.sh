#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
CLI_EXECUTABLE="${APP_BUNDLE}/Contents/MacOS/szu-campus-netctl"
INFO_PLIST="${APP_BUNDLE}/Contents/Info.plist"

[[ -d "${APP_BUNDLE}" ]] || { echo "找不到 App：${APP_BUNDLE}" >&2; exit 1; }
[[ -x "${EXECUTABLE}" ]] || { echo "App 可执行文件不存在或不可执行。" >&2; exit 1; }
[[ -x "${CLI_EXECUTABLE}" ]] || { echo "App 内 JSON CLI 不存在或不可执行。" >&2; exit 1; }
[[ -f "${APP_BUNDLE}/Contents/Resources/campus-providers.example.json" ]] \
  || { echo "App 缺少双 Provider 配置示例。" >&2; exit 1; }

plutil -lint "${INFO_PLIST}" >/dev/null
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")"
UI_ELEMENT="$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "${INFO_PLIST}")"

[[ "${VERSION}" == "2.0.0" ]] || { echo "版本错误：${VERSION}" >&2; exit 1; }
[[ "${BUILD}" == "2" ]] || { echo "构建号错误：${BUILD}" >&2; exit 1; }
[[ "${IDENTIFIER}" == "com.szu-netlogin.dorm-login" ]] || { echo "Bundle ID 错误：${IDENTIFIER}" >&2; exit 1; }
[[ "${MIN_SYSTEM}" == "13.0" ]] || { echo "最低系统版本错误：${MIN_SYSTEM}" >&2; exit 1; }
[[ "${UI_ELEMENT}" == "true" ]] || { echo "App 未配置为状态栏应用。" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SZUNETAutomationOwnershipSchema' "${INFO_PLIST}")" == "1" ]] \
  || { echo "App 缺少自动化所有权能力标记。" >&2; exit 1; }

CREDENTIAL_MODE="$(/usr/libexec/PlistBuddy -c 'Print :SZUNETCredentialMode' "${INFO_PLIST}")"
if [[ "${CREDENTIAL_MODE}" == "shared" ]]; then
  ACCESS_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :SZUNETKeychainAccessGroup' "${INFO_PLIST}")"
  [[ -n "${ACCESS_GROUP}" ]] || { echo "共享钥匙串模式缺少 access group。" >&2; exit 1; }
  codesign -d --entitlements :- "${APP_BUNDLE}" 2>&1 | grep -Fq "${ACCESS_GROUP}" \
    || { echo "App 签名未包含共享钥匙串 entitlement。" >&2; exit 1; }
  [[ -f "${APP_BUNDLE}/Contents/embedded.provisionprofile" ]] \
    || { echo "共享钥匙串模式缺少 provisioning profile。" >&2; exit 1; }
elif [[ "${CREDENTIAL_MODE}" != "local" ]]; then
  echo "未知凭据模式：${CREDENTIAL_MODE}" >&2
  exit 1
fi

VERSION_OUTPUT="$("${EXECUTABLE}" --version)"
[[ "${VERSION_OUTPUT}" == *"native Swift"* ]] || { echo "可执行文件不是预期的 Swift 版本。" >&2; exit 1; }
UI_SMOKE_OUTPUT="$("${EXECUTABLE}" --ui-smoke-test)"
[[ "${UI_SMOKE_OUTPUT}" == *"初始化：正常"* ]] || { echo "状态栏 UI 初始化检查失败。" >&2; exit 1; }
CLI_SELF_TEST_OUTPUT="$("${CLI_EXECUTABLE}" --self-test)"
[[ "${CLI_SELF_TEST_OUTPUT}" == *'"schemaVersion":1'* ]] \
  || { echo "JSON CLI 离线自检缺少 schemaVersion。" >&2; exit 1; }
[[ "${CLI_SELF_TEST_OUTPUT}" == *'"outcome":"unchanged"'* ]] \
  || { echo "JSON CLI 离线自检失败。" >&2; exit 1; }
CLI_LINE_COUNT="$(printf '%s\n' "${CLI_SELF_TEST_OUTPUT}" | wc -l | tr -d ' ')"
[[ "${CLI_LINE_COUNT}" == "1" ]] || { echo "JSON CLI stdout 不是单对象单行。" >&2; exit 1; }

if otool -L "${EXECUTABLE}" | grep -Eiq 'python|libpython'; then
  echo "App 仍链接了 Python 运行时。" >&2
  exit 1
fi
if otool -L "${CLI_EXECUTABLE}" | grep -Eiq 'python|libpython'; then
  echo "JSON CLI 仍链接了 Python 运行时。" >&2
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
lipo "${EXECUTABLE}" -verify_arch arm64 x86_64
lipo "${CLI_EXECUTABLE}" -verify_arch arm64 x86_64
[[ "$(lipo -archs "${EXECUTABLE}")" == "$(lipo -archs "${CLI_EXECUTABLE}")" ]] \
  || { echo "App 与 JSON CLI 架构不一致。" >&2; exit 1; }
bash "${PROJECT_ROOT}/scripts/run_swift_checks.sh"

SIZE="$(du -sh "${APP_BUNDLE}" | awk '{print $1}')"
echo "App 验证通过：${APP_BUNDLE}"
echo "版本：${VERSION}（${BUILD}）"
echo "架构：$(lipo -archs "${EXECUTABLE}")"
echo "大小：${SIZE}"
echo "Python 运行时：未包含"
echo "JSON CLI：已内置并通过离线自检"
