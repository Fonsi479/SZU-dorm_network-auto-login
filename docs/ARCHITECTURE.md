# Architecture

```text
optional host / SZUNETFeature
             |
     stdin/stdout JSON only
             |
App -------- JSON CLI
             |
   high-level product controller
             |
   CampusNetworkCoordinator
     /                   \
DormDrCOMProvider  TeachingSRunProvider
     \                   /
source-bound transport + system credential broker
```

The Coordinator is the only Provider decision owner and authentication scheduler. Credential-free status/check, provider selection, login and logout all pass through its global mutual exclusion, network generation and cancellation gates; authentication additionally uses the cross-process lease. UI, product services and adapters cannot call a Provider or credential store directly.

Dorm and Teaching have separate enablement, account labels and credential references. Status probes are credential-free. Exactly one Provider must be verified before a credential is opened; two verified Providers are an ambiguous environment and fail closed.

Platform desktop applications own lifecycle, settings, credentials, automation and packaging. The JSON CLI exposes sanitized DTOs and high-level commands only. `SZUNETFeature` is a CLI-only process client with no dependency on `SZUNetCore`; it never creates Provider/Coordinator/runtime state or accepts credentials. Codex Butler is an optional consumer, not an application owner.

The two platform releases share only `protocol-spec/` contracts, fixtures, vectors and error codes. macOS packages Swift code only. Windows packages Python into PE executables and does not include macOS sources.
