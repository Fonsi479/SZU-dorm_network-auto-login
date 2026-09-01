#!/bin/zsh
set -euo pipefail

APP_NAME="SZU Dorm Login"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
PACKAGE_ROOT="${PROJECT_ROOT}"
APP_BUNDLE="${PROJECT_ROOT}/dist/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
source "${SCRIPT_DIR}/codesign-identity.sh"

if [[ "$(pwd -P)" != "${PROJECT_ROOT}" ]]; then
  echo "请在项目根目录运行：bash scripts/build_app.sh" >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "未找到 Swift 编译器。请先安装 Xcode Command Line Tools。" >&2
  exit 1
fi

echo "正在编译原生 Swift macOS 应用…"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution "${ARCH_FLAGS[@]}" \
  -Xswiftc -warnings-as-errors --product SZUDormLogin
swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution "${ARCH_FLAGS[@]}" \
  -Xswiftc -warnings-as-errors --product szu-campus-netctl
BIN_DIR="$(swift build --package-path "${PACKAGE_ROOT}" --configuration release \
  --disable-automatic-resolution "${ARCH_FLAGS[@]}" --show-bin-path)"
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
lipo "${SOURCE_EXECUTABLE}" -verify_arch arm64 x86_64
lipo "${SOURCE_CLI}" -verify_arch arm64 x86_64

rm -rf "${APP_BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${SOURCE_EXECUTABLE}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "${SOURCE_CLI}" "${CONTENTS}/MacOS/szu-campus-netctl"
cp "${PROJECT_ROOT}/macos/Resources/Info.plist" "${CONTENTS}/Info.plist"
cp "${PROJECT_ROOT}/config.example.json" "${CONTENTS}/Resources/config.example.json"
cp "${PROJECT_ROOT}/campus-providers.example.json" \
  "${CONTENTS}/Resources/campus-providers.example.json"
chmod 755 "${CONTENTS}/MacOS/${APP_NAME}" "${CONTENTS}/MacOS/szu-campus-netctl"

SHARED_ACCESS_GROUP="${SZUNET_SHARED_KEYCHAIN_ACCESS_GROUP:-}"
PROVISIONING_PROFILE="${SZUNET_PROVISIONING_PROFILE:-}"
ENTITLEMENTS="${PROJECT_ROOT}/dist/SZUNET.entitlements"
if [[ -n "${SHARED_ACCESS_GROUP}" || -n "${PROVISIONING_PROFILE}" ]]; then
  if [[ -z "${SHARED_ACCESS_GROUP}" || -z "${PROVISIONING_PROFILE}" ]]; then
    echo "共享钥匙串构建必须同时提供 SZUNET_SHARED_KEYCHAIN_ACCESS_GROUP 与 SZUNET_PROVISIONING_PROFILE。" >&2
    exit 1
  fi
  if [[ ! -f "${PROVISIONING_PROFILE}" ]]; then
    echo "找不到 provisioning profile：${PROVISIONING_PROFILE}" >&2
    exit 1
  fi
  PROFILE_PLIST="$(mktemp)"
  trap 'rm -f "${PROFILE_PLIST:-}" "${ENTITLEMENTS:-}"' EXIT
  security cms -D -i "${PROVISIONING_PROFILE}" > "${PROFILE_PLIST}"
  if ! /usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' \
      "${PROFILE_PLIST}" 2>/dev/null | grep -Fq "${SHARED_ACCESS_GROUP}"; then
    echo "provisioning profile 未授权共享钥匙串组：${SHARED_ACCESS_GROUP}" >&2
    exit 1
  fi
  cp "${PROVISIONING_PROFILE}" "${CONTENTS}/embedded.provisionprofile"
  /usr/libexec/PlistBuddy -c 'Set :SZUNETCredentialMode shared' "${CONTENTS}/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SZUNETKeychainAccessGroup string ${SHARED_ACCESS_GROUP}" \
    "${CONTENTS}/Info.plist"
  cat > "${ENTITLEMENTS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>keychain-access-groups</key>
    <array>
        <string>${SHARED_ACCESS_GROUP}</string>
    </array>
</dict>
</plist>
PLIST
else
  cat > "${ENTITLEMENTS}" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
fi

plutil -lint "${CONTENTS}/Info.plist" >/dev/null
plutil -lint "${ENTITLEMENTS}" >/dev/null
CODESIGN_IDENTITY="$(resolve_szunet_codesign_identity)"
announce_szunet_codesign_identity "${CODESIGN_IDENTITY}"
sign_szunet_code "${CODESIGN_IDENTITY}" \
  "com.szu-netlogin.dorm-login.cli" "${CONTENTS}/MacOS/szu-campus-netctl" \
  --entitlements "${ENTITLEMENTS}" >/dev/null
sign_szunet_code "${CODESIGN_IDENTITY}" \
  "com.szu-netlogin.dorm-login" "${APP_BUNDLE}" \
  --entitlements "${ENTITLEMENTS}" >/dev/null
rm -f "${ENTITLEMENTS}"

echo "打包完成：${APP_BUNDLE}"
echo "实现：纯 Swift / AppKit 状态栏（arm64 + x86_64，不包含 Python 运行时）"
