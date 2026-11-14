# Command Code cancellation through the production HTTP client

This supplements the standalone runner proof with the provider/transport path requested in PR #5085.

## Executed surface

```text
CommandCodeWebFetchStrategy.fetch
  ProviderCandidateRetryRunner.run
    CommandCodeUsageFetcher.fetchUsage(cookieHeader:session:)
      CommandCodeUsageFetcher.send
        loopback/cancellation adapter
          ProviderHTTPClient.data
            URLSession.data
              real TCP HTTP server -> HTTP 401
      CommandCodeUsageError.invalidCredentials
    cancellation check before another candidate read
```

The adapter only redirects the production destination to the owned loopback server and cancels the current Swift
refresh task after the required credits response has arrived. It returns the actual response unchanged. The real
Command Code fetcher classifies HTTP 401; the strategy's usage loader logs and rethrows the original error.
No URLProtocol stub, fabricated HTTPURLResponse or synthetic authentication exception is used.

The server returns the optional subscription response before the required credits response. This keeps unrelated
subscription cancellation from racing FoundationNetworking while the proof tests the candidate traversal boundary.
The temporary profile files contain synthetic cookies; the lazy session sequence reads them only when advanced.
Cache access uses the existing in-memory test store and an owned temporary legacy-cache directory.

## Reproduce

Environment: Linux x86_64, Swift 6.3.3. From the repository root:

```bash
CODEXBAR_SUPPRESS_TEST_KEYCHAIN_ACCESS=1 swift test --filter CommandCodeCancellationTransportProofTests
```

The suite executes two real HTTP scenarios: normal authentication fallback and cancellation after HTTP 401.
Every `wire` entry is emitted by the receiving server; `transport` entries indicate calls into the real client,
which may reject an already-cancelled request before it reaches the server.

For the before/after comparison, the exact same suite was built with the pristine production runner from
`22f731375854ae739bec1395ff5b3f1d5116a243`, then rebuilt with the fixed runner. Only that source file was swapped;
the test, provider strategy, fetcher, HTTP client and server were unchanged. The baseline runner's SHA256 was
`a42b4b28e948a50ec39da594ae821eff2d1aa25c385a6b7523b7d81c90b75203`.

## Observations

Baseline cancellation trace, after the actual credits HTTP 401:

```text
cancel after on-wire HTTP 401
provider classified invalidCredentials
read profile-2
transport candidate-2 /internal/billing/credits
transport candidate-2 /internal/billing/subscriptions
```

The baseline exits 1 with the exact assertion failure: `reads == ["read profile-1"]` observes
`["read profile-1", "read profile-2"]`. There are also unexpected candidate-2 transport calls.
URLSession rejects those already-cancelled calls before they reach the server in this run; the proof does not
claim a second on-wire request on the baseline.

Fixed cancellation trace ends at:

```text
cancel after on-wire HTTP 401
provider classified invalidCredentials
COMMANDCODE_TRANSPORT_PROOF cancelOn401=true outcome=cancelled
```

No profile-2 read, candidate-2 client call or candidate-2 server request occurs. The uncancelled control reads both
profiles and sends both candidates' requests through the real client/server, ending with `invalidCredentials`.

[Full captured runtime output](provider-candidate-transport.log).
[Executable scenario](../../TestsLinux/CommandCodeCancellationTransportProofTests.swift).

## Limits

This is an executed provider-path integration with the production HTTP client and real loopback HTTP, not a live
Command Code account probe. Routing and cancellation timing are controlled by the fixture. Browser databases,
macOS UI/Keychain, TLS to the public provider and real account compatibility are not exercised. No actual cookies,
credentials or provider data are used. Cancellation is cooperative; in-progress reads are not forcibly interrupted.
