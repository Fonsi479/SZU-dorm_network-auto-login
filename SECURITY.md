# Security Policy

## Supported release line

Security fixes target the current native macOS and Windows v2 release line. The historical macOS Python client is migration-only and is not restored or bundled.

## Reporting

Do not attach real campus credentials, full authentication URLs, cookies, Challenge/Info/Checksum values, logs, diagnostic archives, Keychain/Credential Manager exports, or private configuration to a public issue. Use a private repository security advisory or contact the maintainer privately, and include only sanitized reproduction steps and event/error codes.

## Security invariants

- Environment, portal identity, source route, provider enablement and explicit offline state are checked before credential access.
- `nonCampus`, `ambiguous`, `unknown`, disabled, already-online and stale-generation paths perform zero credential reads and zero authentication requests.
- macOS credentials remain in Keychain; Windows credentials remain in Credential Manager. CLI and configuration have no password input.
- Authentication operations are globally mutually exclusive and cancellable. Fatal authentication errors are fused; retryable errors use bounded provider-specific backoff.
- SRun uses HTTPS with default certificate validation, a fixed allowed host, no proxy inheritance, no TLS downgrade and no cross-host authentication redirect.
- The application does not require administrator privileges, alter DNS/routes/proxies/VPNs, install a system daemon or expose a local HTTP listener.
- Logs and diagnostics redact account identifiers, IP/SSID values, authentication URLs, request bodies, cookies, Challenge, Info, Password and Checksum fields.
- Optional host integration is process-isolated: `SZUNETFeature` can only call the installed password-free JSON CLI and cannot link Core, create an authentication runtime, access credentials/settings or schedule automatic login.

## Out of scope

This project does not bypass billing, device limits, product suffix rules or account policy. It does not support credential collection, account sharing or batch authentication.

Real campus behavior remains `PENDING_CAMPUS_VALIDATION` until the sanitized acceptance checklist is completed. A synthetic vector or mock-server PASS is not evidence of a successful campus login.
