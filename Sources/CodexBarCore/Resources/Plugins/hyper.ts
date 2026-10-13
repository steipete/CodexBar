defineProvider({
  id: "hyper",
  name: "Charm Hyper",
  endpoints: ["https://hyper.charm.land"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["hyper.charm.land"],
  settings: [
    { key: "HYPER_API_KEY", title: "API key", type: "secure" },
    { key: "SOURCE_MODE", title: "Source", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const domain = "hyper.charm.land";
    const key = ctx.settings.getSecret("HYPER_API_KEY");
    const canUseKey = Boolean(key) && ctx.settings.get("SOURCE_MODE") !== "web";
    const cookiePolicy = ctx.browser.availability(domain);
    const missing = (): never => {
      throw ctx.fail.missingCredential("Sign in to hyper.charm.land or configure a Charm Hyper API key.");
    };
    // Browser sessions use the dashboard; /v1/credits accepts bearer keys only.
    const request = (headers: Record<string, string>, session = false) =>
      ctx.http.get(`https://${domain}/${session ? "" : "v1/credits"}`, {
        headers,
        timeoutSeconds: session ? 8 : 10,
      });
    let response: CodexBarHTTPTextResponse | undefined;
    let session = false;
    if (cookiePolicy !== "off") {
      try {
        const cookie = await ctx.browser.cookieHeader(domain);
        session = true;
        response = await request({ Cookie: cookie, Accept: "text/html" }, true);
      } catch (error) {
        if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
        if (!canUseKey) {
          if (session) throw ctx.fail.networkFailure("Charm Hyper session request failed.");
          return missing();
        }
      }
      const team = /\/teams\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;
      if (
        response &&
        (response.status === 401 ||
          response.status === 403 ||
          (response.status >= 300 && response.status < 400) ||
          (response.status === 200 && !team.test(response.url) && !team.test(response.bodyText)))
      ) {
        ctx.browser.rejectCookie(domain);
        if (!canUseKey) {
          throw ctx.fail.authenticationExpired(
            cookiePolicy === "manual"
              ? "Charm Hyper session expired. Paste a fresh Cookie header in Settings."
              : "Charm Hyper session expired. Sign in again at hyper.charm.land.",
          );
        }
        response = undefined;
      }
    }
    if (!response) {
      if (!canUseKey) return missing();
      response = await request({ Authorization: `Bearer ${key}` });
      session = false;
    }
    if (response.status === 401) throw ctx.fail.authenticationExpired("Charm Hyper API key rejected (HTTP 401).");
    if (response.status === 403)
      throw ctx.fail.permissionDenied("Charm Hyper API key cannot access credits (HTTP 403).");
    if (response.status === 429) throw ctx.fail.rateLimited("Charm Hyper credits requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Charm Hyper API error: HTTP ${response.status}`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Charm Hyper API error: HTTP ${response.status}`);

    let balance: unknown;
    if (session) {
      const match = /Hypercredits Available[\s\S]{0,400}?text-5xl font-bold">\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s*</.exec(
        response.bodyText,
      );
      balance = match ? Number(match[1].replace(/,/g, "")) : NaN;
    } else {
      try {
        balance = JSON.parse(response.bodyText)?.balance;
      } catch (error) {
        void error;
        throw ctx.fail.parseFailure("Charm Hyper credits response is not valid JSON.");
      }
    }
    if (typeof balance !== "number" || !Number.isFinite(balance) || balance < 0) {
      throw ctx.fail.parseFailure("Charm Hyper balance must be a non-negative number.");
    }
    const row = {
      label: "Balance",
      value: `${ctx.format.number(balance, { maximumFractionDigits: 2 })} HC`,
      usageValue: balance,
    };
    return {
      usage: {
        details: [{ title: "Hypercredits", rows: [row] }],
        identity: { loginMethod: session ? "Browser session" : "API key" },
        dataConfidence: "exact",
      },
      sourceLabel: session ? "web" : "api",
    };
  },
});
