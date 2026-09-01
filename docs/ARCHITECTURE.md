# Architecture

```text
MacManager ---- SZUNETEmbedded ----+
                                    |
Standalone App --------------------+---- high-level product controller
                                    |
scripts / legacy host -- JSON CLI -+
             |
   CampusNetworkCoordinator
     /                   \
DormDrCOMProvider  TeachingSRunProvider
     \                   /
source-bound transport + system credential broker
```

The Coordinator is the only Provider decision owner and authentication scheduler. Credential-free status/check, provider selection, login and logout all pass through its global mutual exclusion, network generation and cancellation gates; authentication additionally uses the cross-process lease. UI, product services and adapters cannot call a Provider or credential store directly.

Dorm and Teaching have separate enablement, account labels and credential references. Status probes are credential-free. Exactly one Provider must be verified before a credential is opened; two verified Providers are an ambiguous environment and fail closed.

Dorm automatic recovery runs every 30 seconds and on network-path changes. A Portal-online result is checked through a source-bound session with ambient proxies disabled. Only a failed direct egress probe plus `exactOnlineRecordPresent=false` and a known device count below 3 permits one ordinary login; existing, full, or unknown records remain credential-free.

`SZUNETEmbedded` is the public in-process owner surface for macOS hosts; it composes Core, shared state, ownership, credential mode and management UI without importing private host code. MacManager and the standalone App use different lifecycle shells around that same runtime. `SZUNETFeature` stays transport-neutral and retains the JSON CLI client without depending on `SZUNetCore`.

Shared automation has exactly one persistent owner. Non-owners may issue explicit manual operations, while scheduled authentication must revalidate ownership immediately before Core can open a credential. There is no automatic failover.

The two platform releases share only `protocol-spec/` contracts, fixtures, vectors and error codes. macOS packages one arm64/x86_64 Swift status-bar app. Windows packages Python into separate native x64 and ARM64 PE executables and does not include macOS sources.
