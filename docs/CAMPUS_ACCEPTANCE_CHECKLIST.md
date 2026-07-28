# Campus Acceptance Checklist

All unchecked items are `PENDING_CAMPUS_VALIDATION`. Use a dedicated test window, manual trigger and minimal request count. Do not run a login/logout loop.

## Preparation

- [ ] Verify the release SHA-256 and keep the previous rollback archive.
- [ ] Confirm Teaching is disabled and automatic login is paused.
- [ ] Confirm no real credentials appear in configuration, logs or process arguments.
- [ ] Record only sanitized campus/area/access-type metadata.
- [ ] Preserve the active Shadowrocket/VPN state; do not disconnect or reconfigure it for this test.

## Teaching area

- [ ] With Teaching disabled, status may probe but credential reads/authentication requests remain zero.
- [ ] Portal host/certificate, route-selected source IP and dynamic ACID/client IP agree.
- [ ] An unknown/conflicting Portal result returns a stable error and sends no login.
- [ ] After explicit enablement and credential save, one manual login performs one Challenge and one login request.
- [ ] Login ACK is accepted only after matching online status confirmation.
- [ ] Already-online status performs no credential read and no repeat login.
- [ ] Bad-password/device-limit/product-suffix errors enter fatal fuse without looping.
- [ ] Teaching logout remains disabled and sends no request.

## Dorm area

- [ ] Existing gateway/source-IP gate still selects Dorm only.
- [ ] Existing offline login, online no-op and verified logout behavior match the baseline.
- [ ] Teaching sends no request when Dorm is the unique verified Provider.

## Network changes and ambiguity

- [ ] Switching Wi-Fi/network increments generation and cancels the old request path.
- [ ] Old generation produces no stale UI result and no follow-up authentication.
- [ ] Two verified Providers return `ENV_AMBIGUOUS` with zero credential reads.
- [ ] Non-campus, VPN-only and unknown routes perform zero credential reads/authentication.

## Platform lifecycle

- [ ] macOS pause/resume, wake, login item, status bar and quit work; process exits.
- [ ] Windows tray, keyboard navigation, startup link removal and quit work; process exits.
- [ ] Windows Credential Manager and configuration/diagnostic ACLs are correct in a clean VM.
- [ ] VoiceOver/Narrator status is understandable without relying only on color.

## Evidence record

Record app version, artifact hash, platform version, sanitized Provider/category, event/error codes, request counts and outcome. Never record raw account, password, full IP/SSID, cookies or SRun derived fields.
