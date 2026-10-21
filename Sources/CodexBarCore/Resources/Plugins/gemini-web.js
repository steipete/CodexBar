function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "gemini",
  name: "Gemini app",
  endpoints: ["https://gemini.google.com"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["gemini.google.com", "google.com"],
  cookiePolicy: { selection: "request-url", cache: "nonpersistent", imports: "access-gated" },
  async fetchUsage(ctx) {
    const domain = "gemini.google.com";
    if (ctx.browser.availability(domain) === "off")
      throw ctx.fail.missingCredential("Gemini app cookies are disabled.");
    // UsagePageQuery from the public UsagePageSurface bundle; this is separate from Gemini CLI quotas.
    const signature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g=";
    const variables = JSON.stringify({
      g1Request: { entrypoints: ["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"] },
      workspaceRequest: { recommendationsForSurfaceRequests: [] },
    });
    const url =
      `https://${domain}/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery` +
      `?query_signature=${encodeURIComponent(signature)}&variables=${encodeURIComponent(variables)}`;
    const invalid = () => {
      throw ctx.fail.parseFailure("Gemini app usage response changed. Update CodexBar or report this.");
    };
    const object = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const response = await ctx.http.get(url, {
        cookieSession: session.id,
        headers: { Accept: "application/json", Referer: `https://${domain}/usage` },
        retryPolicy: "transientIdempotent",
      });
      if (
        response.status === 401 ||
        response.status === 403 ||
        (response.status === 200 && response.bodyText.trimStart().startsWith("<"))
      ) {
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      if (response.status === 429) throw ctx.fail.rateLimited("Gemini app usage is rate limited.");
      if (response.status >= 500) throw ctx.fail.providerUnavailable("Gemini app usage is temporarily unavailable.");
      if (response.status !== 200) throw ctx.fail.apiFailure(`Gemini app returned HTTP ${response.status}.`);
      let results;
      try {
        results = JSON.parse(response.bodyText.trim().replace(/^\)\]\}'\s*/, ""));
      } catch (error) {
        void error;
        return invalid();
      }
      if (!Array.isArray(results)) return invalid();
      const data = results
        .map((result) => object(_optionalChain([object, "call", (_) => _(result), "optionalAccess", (_2) => _2.data])))
        .filter((value) => value !== undefined);
      if (data.length === 0) return invalid();
      const result = data.find((value) => Object.prototype.hasOwnProperty.call(value, "viewer"));
      if (!result) return invalid();
      if (result.viewer === null) {
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      const viewer = object(result.viewer);
      if (!viewer) return invalid();
      const usage = object(
        _optionalChain([object, "call", (_3) => _3(viewer.rpcs), "optionalAccess", (_4) => _4.getUsageInfo]),
      );
      if (!usage || !Array.isArray(usage.pools)) return invalid();
      const pools = usage.pools;
      const window = (type, minutes) => {
        const pool = pools
          .map(object)
          .find((pool) => _optionalChain([pool, "optionalAccess", (_5) => _5.poolType]) === type);
        const percent = _optionalChain([pool, "optionalAccess", (_6) => _6.percentageUsed]);
        if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0) return undefined;
        const rawReset = _optionalChain([
          object,
          "call",
          (_7) => _7(_optionalChain([pool, "optionalAccess", (_8) => _8.gxu])),
          "optionalAccess",
          (_9) => _9.windowRefreshesAt,
        ]);
        let resetsAt;
        if (typeof rawReset === "string" && /^\d{4}-\d{2}-\d{2}T/.test(rawReset)) {
          try {
            const date = ctx.date.iso(rawReset);
            if (Number.isFinite(date.getTime())) resetsAt = date;
          } catch (error) {
            void error;
          }
        }
        return { usedPercent: Math.min(100, percent * 100), windowMinutes: minutes, resetsAt };
      };
      const primary = window("GXU_FIVE_HOURLY", 300);
      const secondary = window("GXU_WEEKLY", 10080);
      if (!primary && !secondary) {
        throw ctx.fail.providerUnavailable("This Google account reports no Gemini app usage windows.");
      }
      return {
        primary,
        secondary,
        identity: { loginMethod: usage.subscriptionTier === "TIER1" ? "Pro" : undefined },
        dataConfidence: "exact",
      };
    }
    if (rejected) throw ctx.fail.authenticationExpired("Sign in again at gemini.google.com/usage.");
    throw ctx.fail.missingCredential(
      `Sign in at gemini.google.com/usage. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste its Cookie header.`,
    );
  },
});
