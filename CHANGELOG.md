# Changelog

## Unreleased

## 2.0.0-beta.1 - 2026-07-28

### Added

- Teaching-area SRun Provider with dynamic ACID/client-IP discovery, strict JSONP, BX1 crypto vectors and post-login confirmation.
- Single Dorm/Teaching Coordinator with independent switches, mutual exclusion, generation cancellation, bounded backoff and fatal-error fuse.
- Independent macOS and Windows JSON CLI surfaces for optional Codex Butler integration.
- Per-Provider credential references and sanitized dual-Provider status in native desktop clients.
- Shared schemas, fixtures, error codes, offline acceptance evidence and release safety documentation.

### Security

- Credential reads moved behind environment, source-route, portal-identity and explicit-offline gates.
- Authentication transports require the verified local source address; SRun retains default TLS validation and bypasses system proxy settings.
- Extended log/diagnostic redaction and permission checks for SRun-derived fields and authentication URLs.
- Teaching logout remains disabled until a campus-safe contract is verified.
- Optional `SZUNETFeature` integration is a password-free CLI consumer only; it cannot instantiate Core, Provider, Coordinator, Keychain/configuration ownership or its own automatic-login scheduler.

### Compatibility

- Dorm Dr.COM/ePortal remains enabled by default and preserves its existing behavior/tests.
- Teaching is disabled by default after migration.
- Existing credentials are referenced in place; no password is copied to configuration.

### Validation boundary

All Teaching results in this prerelease are offline/synthetic. Real campus login, Apple notarization, Windows Authenticode and Defender/SmartScreen results must be recorded separately before promotion to RC or a public stable release.
