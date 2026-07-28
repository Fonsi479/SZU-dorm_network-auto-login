# Migration and Rollback

## Before migration

1. Record the installed application version and keep the previous release archive/hash.
2. Back up configuration files without exporting passwords or system credential databases.
3. Record whether Dorm/Teaching and automatic login are enabled.
4. Do not remove the historical client or login item until the new build has completed offline checks.

## v2 migration

- A schema-v1 configuration is converted to schema v2 with Dorm enabled and Teaching disabled.
- Existing Dorm account and Keychain/Credential Manager reference are retained in place.
- Teaching receives its own disabled Provider entry and credential reference; no password is copied.
- Old macOS Python configuration and LaunchAgent are discovered only for explicit import/cleanup. The old client is never silently restarted.

## Rollback triggers

Rollback immediately if any of the following occurs:

- a non-campus, unknown or ambiguous network reads a credential or sends authentication;
- Dorm regression tests fail or Dorm behavior changes unexpectedly;
- both Providers send authentication concurrently;
- a cancelled/stale generation sends a follow-up request;
- source binding cannot be proven;
- logs or diagnostics contain sensitive fields;
- the App/tray cannot exit, or retries risk an account lock, device limit or unexpected charge.

## Rollback procedure

1. Disable Teaching and automatic login.
2. Quit the current App/tray and confirm the process exits.
3. Restore the previous platform-specific binary and configuration backup.
4. Keep system credentials unless the user explicitly chooses to delete them.
5. Remove only the new startup/login item if it was created; do not change VPN, DNS, proxy or route settings.
6. Preserve sanitized event codes and add the failure as a deterministic fixture/test before retrying.

Windows and macOS artifacts are rolled back independently. Never replace one platform with an archive built for the other.
