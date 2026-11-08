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
  id: "siliconflow",
  name: "SiliconFlow",
  endpoints: ["https://cloud.siliconflow.cn"],
  settings: [{ key: "MESSAGES", title: "SiliconFlow", type: "plain" }],
  capabilities: ["browser-cookies", "http-status"],
  // The session cookie is scoped to the parent domain.
  cookieDomains: ["cloud.siliconflow.cn", "siliconflow.cn"],
  // The host's optional name filter excludes dots; validate the opaque session at the wallet endpoint.
  cookiePolicy: { selection: "request-url", cache: "validated-single-entry", imports: "access-gated" },
  async fetchUsage(ctx) {
    const domain = "cloud.siliconflow.cn";
    const origin = `https://${domain}`;
    const billingPage = `${origin}/me/expensebill`;
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const signIn = message("Sign in to cloud.siliconflow.cn in your browser, then refresh CodexBar.");
    const expired = ctx.fail.authenticationExpired(signIn);
    const fail = () => {
      throw ctx.fail.parseFailure(
        message("SiliconFlow returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential(signIn);

    const isLoginRedirect = (location) => {
      if (!location) return false;
      const match = /^https:\/\/([^/?#]+)(\/[^?#]*)?/i.exec(location);
      return Boolean(match && match[1].toLowerCase() === "account.siliconflow.cn" && /^\/login\b/.test(match[2] || ""));
    };
    const classify = (response) => {
      if (response.status === 200) return;
      if (response.status === 401) throw expired;
      if (response.status >= 300 && response.status < 400 && isLoginRedirect(response.headers.location)) throw expired;
      const tryLater = message("SiliconFlow request failed. Try refreshing later.");
      if (response.status === 403) {
        throw ctx.fail.permissionDenied(message("SiliconFlow denied access to the console balance (HTTP 403)."));
      }
      if (response.status === 429)
        throw ctx.fail.rateLimited(message("SiliconFlow is rate limiting requests. Try again later."));
      if (response.status === 408 || response.status >= 500) throw ctx.fail.providerUnavailable(tryLater);
      throw ctx.fail.apiFailure(tryLater);
    };
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    // Wallet amounts are integer strings in 10^-12 CNY; split the digits instead of dividing a lossy number.
    const yuan = (value) => {
      if (typeof value !== "string") return fail();
      const match = /^(-?)(\d{1,30})$/.exec(value);
      if (!match) return fail();
      const digits = match[2].padStart(13, "0");
      const amount = Number(`${match[1]}${digits.slice(0, -12)}.${digits.slice(-12)}`);
      return Number.isFinite(amount) ? amount : fail();
    };

    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      try {
        // The billing page reports the active subject in a response header; no ID is sent here.
        const page = await ctx.http.get(billingPage, {
          cookieSession: session.id,
          headers: { Accept: "text/html" },
        });
        classify(page);
        const subject = page.headers["x-subject-id"];
        if (typeof subject !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(subject)) return fail();
        const wallet = await ctx.http.get(`${origin}/walletd-server/api/v1/subject/profile/peek`, {
          cookieSession: session.id,
          headers: { Accept: "application/json", Referer: billingPage, "x-subject-id": subject },
        });
        classify(wallet);
        let decoded;
        try {
          decoded = JSON.parse(wallet.bodyText);
        } catch (error) {
          void error;
          return fail();
        }
        const root = record(decoded);
        if (!root || root.code !== 20000) return fail();
        const financial = record(
          _optionalChain([record, "call", (_) => _(root.data), "optionalAccess", (_2) => _2.financialInfo]),
        );
        if (!financial) return fail();
        const balance = ctx.format.currency(yuan(financial.balance), "CNY");
        if (policy !== "manual") ctx.browser.acceptCookie(domain, session);
        return {
          details: [{ title: "Balance", rows: [{ label: "Balance", value: balance }] }],
          dataConfidence: "exact",
        };
      } catch (error) {
        if (error !== expired) throw error;
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
      }
    }
    throw rejected ? expired : ctx.fail.missingCredential(signIn);
  },
});
