# MacManager / Codex Butler Integration Boundary

The public repository supports two explicit integration modes:

- `SZUNETFeature` remains transport-neutral and keeps the bounded JSON CLI client for scripts and legacy consumers. It does not depend on `SZUNetCore`.
- `SZUNETEmbedded` is the full in-process product for trusted macOS hosts. It owns the same Core, Provider selection, settings, credential broker, automation gate and reusable SwiftUI management page used by the standalone product.

MacManager imports `SZUNETEmbedded`; it does not copy Provider or authentication code and does not require `SZU Dorm Login.app` or `szu-campus-netctl` at runtime. The standalone App and CLI remain independently buildable and distributable, and neither requires MacManager.

Both official macOS hosts share non-secret state under `~/Library/Application Support/szu-netlogin`. `automation.json` records one explicit automation owner. Manual status/login/logout remains available from either host, but only the current owner may schedule automatic login. Ownership is rechecked immediately before automatic credential access; quitting an owner does not transfer it, while explicitly disabling a module releases it.

Official same-team builds may use a provisioning-profile-authorized Keychain access group. Shared credentials are read first; readable legacy items are copied without deleting the originals. Ad-hoc or self-built clients use local Keychain mode and clearly disclose that credentials are not shared.

Neither integration mode may bypass Coordinator environment/session/source-route gates, expose passwords or protocol secrets, enable Teaching logout, create a localhost control service, or treat offline fixtures as real campus acceptance. All repository tests use fake executors/transports and synthetic credentials.
