# Versioning and Releases

This document defines the public source, branch, tag and artifact structure for SZU Campus Network.

## Source branches

| Branch | Purpose | Lifecycle |
|---|---|---|
| `main` | The only v2 source of truth: shared protocol, macOS, Windows and adapter contracts | Active |
| `codex/*` | Short-lived review branches targeting `main` | Delete after merge |
| `macswift` | Dorm-only macOS Swift 1.x history | Legacy; do not cut v2 releases |
| `winpython` | Dorm-only Windows Python 1.x history | Legacy; do not merge wholesale into v2 |
| `macpython` | Dorm-only macOS Python 1.x history | End of life |

Historical branches and tags are retained for migration and provenance. They must not be force-rewritten or reused for v2.

## Product versions and channels

The product follows Semantic Versioning. A channel suffix describes validation maturity without changing the numeric macOS bundle or Windows file version.

| Channel | Example | Required evidence |
|---|---|---|
| Beta | `2.0.0-beta.2` (macOS) / `2.0.0-beta.1` (Windows) | Offline fixtures, unit tests, frozen self-tests, package integrity and privacy gates |
| Release candidate | `2.0.0-rc.1` | Beta gates plus controlled Dorm and Teaching campus acceptance |
| Stable | `2.0.0` | RC gates plus target-platform signing, notarization/SmartScreen and maintainer approval |

The current source channels are macOS `2.0.0-beta.2` and Windows `2.0.0-beta.1`. Teaching remains default-off and `PENDING_CAMPUS_VALIDATION`.

## Platform tags and assets

macOS and Windows releases are separate entries built from the same reviewed source commit.

| Platform | Tag | Assets |
|---|---|---|
| macOS | `macos-v2.0.0-beta.2` | `SZU-Campus-Network-macOS-v2.0.0-beta.2.zip` and `.zip.sha256` |
| Windows | `windows-v2.0.0-beta.1` | Separate `SZU-Campus-Network-Windows-x64-v2.0.0-beta.1.zip` and `SZU-Campus-Network-Windows-arm64-v2.0.0-beta.1.zip` assets with `.zip.sha256` files |

Each Beta or RC GitHub Release must set `prerelease=true`. Do not upload raw executables, local reports, wheelhouses, installers, VM transfer files or any `*-local.zip`.

GitHub automatically publishes repository-wide source archives for every tag. Platform-specific Release assets contain only the corresponding runtime, documentation, SBOM, provenance and checksums.

## Release notes contract

Every platform Release must state, near the top:

1. channel and production-readiness status;
2. supported platform and architecture;
3. Dorm and Teaching validation status, including that Teaching defaults off;
4. signing, notarization, Authenticode and SmartScreen status;
5. immutable source commit and paired platform Release;
6. SHA-256 verification instructions;
7. migration, rollback, security and privacy links.

Tags must be annotated and must point to one reviewed immutable commit. Push only the intended branch and explicit tags; never use `git push --all` or `git push --tags` in this repository.

## Legacy releases

- `1` / `SZU_autologin_1.0`: historical macOS Python source archive with a non-semantic tag.
- `macos-v1.1.0`: historical Dorm-only macOS Python release.
- `windows-v1.0.0`: historical Dorm-only Windows transfer package.

These entries remain available as immutable history. They are not current downloads and do not contain v2 security or Teaching Provider work.
