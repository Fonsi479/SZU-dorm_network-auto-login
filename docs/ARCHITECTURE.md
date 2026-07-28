# Architecture

```text
App / JSON CLI / optional SZUNETFeature
                  |
        high-level product controller
                  |
        CampusNetworkCoordinator
          /                   \
DormDrCOMProvider      TeachingSRunProvider
          \                   /
 source-bound transport + system credential broker
```

The Coordinator is the only authentication scheduler. It owns provider selection, global mutual exclusion, network generation, cancellation, provider-specific backoff and fatal-error fuses. UI and adapters cannot call a Provider or credential store directly.

Dorm and Teaching have separate enablement, account labels and credential references. Status probes are credential-free. Exactly one Provider must be verified before a credential is opened; two verified Providers are an ambiguous environment and fail closed.

Platform desktop applications own lifecycle, settings and packaging. `SZUNETFeature` and the JSON CLI expose sanitized DTOs and high-level commands only; they do not duplicate Provider code. Codex Butler is an optional consumer, not an application owner.

The two platform releases share only `protocol-spec/` contracts, fixtures, vectors and error codes. macOS packages Swift code only. Windows packages Python into PE executables and does not include macOS sources.
