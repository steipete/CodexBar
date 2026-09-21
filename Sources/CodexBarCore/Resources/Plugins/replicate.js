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
  id: "replicate",
  name: "Replicate",
  endpoints: ["https://replicate.com"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["replicate.com"],
  async fetchUsage(ctx) {
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Replicate billing response format changed: ${field}`);
    };
    const record = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    const parse = (body) => {
      try {
        return JSON.parse(body);
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
    };
    const money = (value) => {
      if (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value.trim())) return undefined;
      const number = Number(value.trim());
      return Number.isFinite(number) && number >= 0 ? number : undefined;
    };
    const expired = () => {
      throw ctx.fail.authenticationExpired("Replicate session expired. Sign in again or paste a fresh Cookie header.");
    };
    const validate = (response) => {
      if (response.status === 401 || response.status === 403) expired();
      const rawRetry = response.headers["retry-after"];
      const retry = rawRetry && /^\d+(?:\.\d+)?$/.test(rawRetry.trim()) ? Number(rawRetry) : 1;
      const retryAfterSeconds = Number.isFinite(retry) ? Math.min(10, retry) : 1;
      if (response.status === 429) throw ctx.fail.rateLimited("Replicate rate limit reached.", { retryAfterSeconds });
      if (response.status === 408 || response.status >= 500)
        throw ctx.fail.providerUnavailable("Replicate billing is unavailable.", { retryAfterSeconds });
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`Replicate returned HTTP ${response.status}.`);
    };
    const cookie = await ctx.browser.cookieHeader("replicate.com");
    const response = await ctx.http.get("https://replicate.com/account/billing", {
      headers: { Cookie: cookie, Accept: "text/html" },
      timeoutSeconds: 8,
    });
    validate(response);
    let account;
    const scripts = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
    let match;
    let visited = 0;
    while ((match = scripts.exec(response.bodyText)) && !account && visited < 4000) {
      if (
        !/\bid\s*=\s*(["'])react-component-props[^"']*\1/i.test(match[1]) ||
        !/\btype\s*=\s*(["'])application\/json\1/i.test(match[1])
      )
        continue;
      let payload;
      try {
        payload = JSON.parse(match[2]);
      } catch (error) {
        void error;
        continue;
      }
      const queue = [payload];
      for (let index = 0; index < queue.length && visited < 4000; index++, visited++) {
        const item = queue[index];
        const object = record(item);
        const candidate = record(_optionalChain([object, "optionalAccess", (_) => _.account]));
        if (
          candidate &&
          (candidate.kind === "user" || candidate.kind === "organization") &&
          typeof candidate.username === "string" &&
          candidate.username.trim()
        ) {
          account = { kind: candidate.kind, username: candidate.username.trim() };
          break;
        }
        const children = Array.isArray(item) ? item : object ? Object.values(object) : [];
        for (const child of children) {
          if (queue.length >= 4000) break;
          if (child !== null && typeof child === "object") queue.push(child);
        }
      }
    }
    if (!account) {
      // These two markers identify Replicate's public signed-out billing redirect.
      const signInTitle = /<title>\s*Sign in\s*\|\s*Replicate\s*<\/title>/i.test(response.bodyText);
      const githubLogin = /<a\b[^>]*\bhref=["']\/login\/github\/(?:\?[^"']*)?["']/i.test(response.bodyText);
      if (signInTitle && githubLogin) return expired();
      return fail("unrecognized billing account props");
    }
    const base = `https://replicate.com/api/${account.kind === "organization" ? "organizations" : "users"}/${encodeURIComponent(account.username)}`;
    const invoicesResponse = await ctx.http.get(`${base}/invoices`, { headers: { Cookie: cookie }, timeoutSeconds: 8 });
    validate(invoicesResponse);
    const invoices = _optionalChain([
      record,
      "call",
      (_2) => _2(parse(invoicesResponse.bodyText)),
      "optionalAccess",
      (_3) => _3.invoices,
    ]);
    if (!Array.isArray(invoices)) return fail("missing invoices");
    const now = ctx.date.now().getTime();
    const current = invoices.map(record).find((invoice) => {
      if (!invoice || invoice.type !== "monthly-usage") return false;
      if (invoice.ended_before === null || invoice.ended_before === undefined) return true;
      if (typeof invoice.ended_before !== "string" || !invoice.ended_before.trim()) return false;
      const end = Date.parse(invoice.ended_before);
      return Number.isFinite(end) && end > now;
    });
    if (!current) return fail("no current monthly-usage invoice");
    const used = money(current.total_cost_before_adjustments);
    if (used === undefined) return fail("missing or invalid total_cost_before_adjustments");
    let balance;
    try {
      const credit = await ctx.http.get(`${base}/unused-credit`, { headers: { Cookie: cookie }, timeoutSeconds: 2 });
      if (credit.status >= 200 && credit.status < 300)
        balance = money(
          _optionalChain([
            record,
            "call",
            (_4) => _4(parse(credit.bodyText)),
            "optionalAccess",
            (_5) => _5.unused_credit,
          ]),
        );
    } catch (error) {
      void error;
    }
    const rows = [{ label: "Spent this month", value: ctx.format.usd(used) }];
    if (balance !== undefined) rows.push({ label: "Credit balance", value: ctx.format.usd(balance) });
    return {
      cost: { used, balance, currency: "USD", period: "This month" },
      details: [{ title: "Billing", rows }],
      identity: {
        accountID: account.username,
        organization: account.kind === "organization" ? account.username : undefined,
      },
      dataConfidence: "exact",
    };
  },
});
