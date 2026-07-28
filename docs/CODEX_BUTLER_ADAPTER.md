# Codex Butler Adapter Boundary

The independent SZUNET application remains the sole owner of authentication, Provider state, credentials, settings, automation and release lifecycle. Codex Butler may:

- request sanitized `status` or `check` results;
- request `login` for `auto`, `dorm` or `teaching`;
- request Dorm logout or receive `SRUN_LOGOUT_DISABLED` for Teaching;
- pause/resume automation;
- open settings or request a sanitized diagnostic summary.

Codex Butler must not:

- receive or store passwords, cookies, Challenge/Info/Checksum values or complete network identifiers;
- instantiate a second authentication implementation;
- bypass Coordinator gates or select a Provider from UI assumptions;
- own the SZUNET menu bar, settings, login item or final application bundle;
- use a default localhost HTTP control port.

The enforced boundary is `szu-campus-netctl --json` with one JSON request on stdin and one JSON response on stdout. The optional `SZUNETFeature` Swift library is only a typed process client for that executable. It must not link or import `SZUNetCore`, instantiate a Provider/Coordinator/runtime, access a configuration or credential path, accept credentials, or schedule automatic login. Its UI may show sanitized state and forward explicit high-level commands, but account and Provider settings stay in the independent App.

The live adapter resolves only an explicitly supplied CLI URL or the fixed CLI inside an installed `SZU Dorm Login.app`. It uses a process argument array plus stdin JSON, bounded output and timeout, and terminates the child on cancellation. Missing CLI, schema mismatch, request-ID mismatch, oversized output and timeout all fail closed without falling back to an in-process authentication implementation.

The standalone App and CLI remain independently buildable and distributable. Installing Codex Butler is never required for SZUNET, and importing `SZUNETFeature` never transfers authentication ownership to the host.

Schema major-version mismatch is rejected. Unknown response fields may be ignored. Requests include a request ID and bounded timeout; results contain only sanitized status and stable error codes.

Repository tests use an injected fake executor and never launch the real campus CLI. A real Codex Butler host build/runtime integration remains a separate optional consumer acceptance step; it is not evidence for campus-network protocol acceptance.
