# Privacy

SZU Campus Network is a local-only network authentication client.

## Data handled locally

- Provider enablement, non-sensitive account labels and credential references;
- local network classification, masked source address/SSID fingerprints and error/event codes;
- authentication credentials stored by macOS Keychain or Windows Credential Manager;
- rotating local logs and user-requested diagnostic reports.

## Data not collected

The project has no analytics, telemetry, advertising, remote crash upload or account-sync service. It does not automatically upload configuration, logs or diagnostics. There is no localhost HTTP control server.

## Credential access

Status and diagnostic operations do not read credentials. The selected Provider may open its credential only after the Coordinator verifies the environment, source route, portal identity, enablement and explicit offline session state. Codex Butler receives only sanitized status and high-level command results.

The optional Swift adapter does not receive account credentials or complete network identifiers. It launches the independent CLI with a fixed argument array and stdin JSON; it does not read SZUNET configuration, Keychain/Credential Manager data or authentication responses directly.

## Logs and diagnostics

Logs are local, permission-restricted and rotated. Diagnostics are generated only on user request and must be previewed before sharing. They exclude passwords, tokens, cookies, full account values, complete IP/SSID identifiers and derived SRun authentication fields.

Removing the application does not silently delete system credentials. Credential deletion is an explicit user action so rollback remains possible.
