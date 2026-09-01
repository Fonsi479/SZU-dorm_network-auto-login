#!/bin/bash

SZUNET_TEAM_ID="89546MG775"

resolve_szunet_codesign_identity() {
    if [[ -n "${SZUNET_CODESIGN_IDENTITY:-}" ]]; then
        printf '%s' "$SZUNET_CODESIGN_IDENTITY"
        return 0
    fi

    local listing found prefix
    listing="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for prefix in "Developer ID Application" "Apple Development"; do
        found="$(awk -v needle="\"${prefix}" 'index($0, needle) { print $2; exit }' \
            <<<"$listing")"
        if [[ -n "$found" ]]; then
            printf '%s' "$found"
            return 0
        fi
    done
    printf '%s' "-"
}

sign_szunet_code() {
    local identity="$1" identifier="$2" target="$3"
    shift 3
    local extra=("$@")

    if [[ "$identity" == "-" ]]; then
        local temporary
        temporary="$(mktemp -d)"
        printf 'designated => identifier "%s"\n' "$identifier" > "$temporary/requirement.txt"
        csreq -r "$temporary/requirement.txt" -b "$temporary/requirement.bin"
        codesign --force --sign - --identifier "$identifier" --timestamp=none \
            --requirements "$temporary/requirement.bin" \
            ${extra[@]+"${extra[@]}"} "$target"
        local result=$?
        rm -rf "$temporary"
        return $result
    fi

    codesign --force --sign "$identity" --identifier "$identifier" --timestamp=none \
        ${extra[@]+"${extra[@]}"} "$target"
}

announce_szunet_codesign_identity() {
    if [[ "$1" == "-" ]]; then
        echo "警告：没有可用的 Apple 签名身份；使用本地 ad-hoc 模式，凭据不会与其他 App 共享。" >&2
    else
        echo "代码签名身份：$1"
    fi
}
