# Flow

Before this PR, CodexBar had no `jev` provider, so Jev usage was absent from the provider manifest and refresh pipeline.

After this PR:

`ProviderManifest.allDescriptors` → `JevProviderDescriptor` → `JevWebFetchStrategy` → cached/manual/browser-imported `console.typesafe.ai` cookies → `JevUsageFetcher.fetchUsage` → `GET /api/usage?granularity=day` → `JevUsageFetcher.summarize` → `JevUsageSummary.toUsageSnapshot` → Jev detail rows for requests and tokens.

On macOS, browser cookies are imported through `JevCookieImporter` using the shared browser detection and cookie client. A successful session is stored in `CookieHeaderCache`; a 401/403 clears the cached session and retries browser discovery.
