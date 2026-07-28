# Codex Butler Adapter Boundary

The independent SZUNET application remains the sole owner of authentication, Provider state, credentials and release lifecycle. Codex Butler may:

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

The preferred low-coupling boundary is `szu-campus-netctl` with one JSON request on stdin and one JSON response on stdout. A local Swift dependency may reuse public contracts and `SZUNETFeature`, but the standalone App and CLI remain independently buildable.

Schema major-version mismatch is rejected. Unknown response fields may be ignored. Requests include a request ID and bounded timeout; results contain only sanitized status and stable error codes.
