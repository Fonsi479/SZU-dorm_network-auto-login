# Executable provider behavior

This file fixes the cross-platform behavior that tests must implement. It does
not describe a live-campus acceptance result.

## Credential authorization

1. Probe every Provider without opening the credential store.
2. Require exactly one verified Provider, an unchanged network generation, a
   verified portal identity, and a bound source route.
3. Require the selected Provider to be enabled. Teaching is disabled by default.
4. Require an explicit offline session result. Unknown, conflicting, probable,
   disabled, already-online, and fatal states perform zero credential reads and
   zero authentication requests.
5. Open a short-lived credential handle only after all preceding checks pass.

## Teaching SRun

- Discover ACID and client IP from the entry URL and structured page fields.
  Missing, invalid, or conflicting values fail closed; no global ACID exists.
- Strictly verify the requested JSONP callback, one JSON object, response size,
  optional final semicolon, and absence of trailing content.
- Build BX1 fields using `vectors/srun-bx1.json` and stable JSON key order.
- Bind every request to the verified source IP, bypass environment proxies,
  preserve normal TLS/SNI verification, and block authentication redirects.
- Treat login ACK as provisional. A matching online status is required for
  success. Already-online queries status; unknown status never starts login.
- Teaching logout is disabled until a sanitized campus capture establishes its
  endpoint and semantics.

## Scheduling

- One coordinator serializes both Providers and cancels the old generation.
- Retryable failures use independent 2/5/10/15 minute Provider backoff with at
  most 15 percent jitter. Credential, account, product, device, and TLS failures
  enter a Provider-specific fatal state.
- Providers return retryability and never create recursive retry loops.
