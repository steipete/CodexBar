function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
defineProvider({
  id: "parallel",
  name: "Parallel",
  endpoints: ["https://platform.parallel.ai"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["platform.parallel.ai"],
  async fetchUsage(ctx) {
    const domain = "platform.parallel.ai";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("Parallel cookies are disabled.");
    // Internal dashboard RPC with no public contract; every shape check below fails closed.
    const request = (cookie) =>
      ctx.http.post(`https://${domain}/api/rpc/billing/payments/refresh-balance`, {
        body: {},
        headers: { Cookie: cookie, Origin: `https://${domain}` },
      });
    const signedOut = (response) =>
      response.status === 401 ||
      response.status === 403 ||
      (response.status >= 300 && response.status < 400) ||
      (response.status === 200 &&
        _nullishCoalesce(response.headers["content-type"], () => "")
          .toLowerCase()
          .includes("text/html"));

    let response;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const candidate = await request(_nullishCoalesce(session.header, () => ""));
      if (signedOut(candidate)) {
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
        ? ctx.fail.authenticationExpired(
            "Parallel session expired. Sign in to platform.parallel.ai again or paste a fresh Cookie header.",
          )
        : ctx.fail.missingCredential(
            `No Parallel session found. Sign in to platform.parallel.ai. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste a Cookie header.`,
          );
    }

    const message = `Parallel returned HTTP ${response.status}.`;
    if (response.status === 429) {
      const delay = Number(_nullishCoalesce(response.headers["retry-after"], () => 1));
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status === 408 || response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);

    const formatChanged = () => {
      throw ctx.fail.parseFailure("Parallel billing response format changed.");
    };
    const finite = (value) => typeof value === "number" && Number.isFinite(value);
    let payload;
    try {
      payload = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return formatChanged();
    }
    const data = payload && typeof payload === "object" && payload.kind === "ok" ? payload.data : undefined;
    if (!data || typeof data !== "object" || !finite(data.balance)) return formatChanged();
    const rows = [{ label: "Balance", value: ctx.format.currency(data.balance / 100, "USD") }];
    if (finite(data.pendingDebitBalanceCents) && data.pendingDebitBalanceCents !== 0) {
      rows.push({ label: "Pending debit", value: ctx.format.currency(data.pendingDebitBalanceCents / 100, "USD") });
    }
    return {
      details: [{ title: "Account balance", rows }],
      identity: { loginMethod: "Browser session" },
      dataConfidence: "exact",
    };
  },
});
