defineProvider({
  id: "tinyapi",
  name: "TinyApi",
  endpoints: ["https://tinyapi.rest"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["tinyapi.rest"],
  async fetchUsage(ctx) {
    const domain = "tinyapi.rest";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("TinyApi cookies are disabled.");
    let response;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const candidate = await ctx.http.get(`https://${domain}/api/user/credits`, {
        headers: { Cookie: session.header },
        timeoutSeconds: 15,
      });
      if (candidate.status === 401 || candidate.status === 403) {
        rejected = true;
        ctx.browser.rejectCookie(domain, session);
        if (policy === "manual") break;
        continue;
      }
      response = candidate;
      break;
    }
    if (!response) {
      throw rejected
        ? ctx.fail.authenticationExpired("TinyApi session expired. Sign in again or paste a fresh Cookie header.")
        : ctx.fail.missingCredential(
            `Sign in to tinyapi.rest. Supported browsers: ${ctx.browser.supportedBrowsers}. Or set a manual Cookie header.`,
          );
    }
    if (response.status === 429) throw ctx.fail.rateLimited("TinyApi credits requests are rate limited.");
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(`TinyApi credits service returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`TinyApi credits request returned HTTP ${response.status}.`);
    let payload;
    try {
      payload = JSON.parse(response.bodyText);
    } catch {
      throw ctx.fail.parseFailure("TinyApi credits response is not valid JSON.");
    }
    const balance = payload?.data?.totalAvailable;
    if (payload?.success !== true || typeof balance !== "number" || !Number.isFinite(balance) || balance < 0) {
      throw ctx.fail.parseFailure("TinyApi credits response is missing a valid available balance.");
    }
    return {
      details: [
        {
          title: "Credits",
          rows: [
            {
              label: "Available credits",
              value: `${ctx.format.number(balance, { maximumFractionDigits: 2 })} credits`,
              usageValue: balance,
            },
          ],
        },
      ],
      identity: { loginMethod: "Browser session" },
      dataConfidence: "exact",
    };
  },
});
