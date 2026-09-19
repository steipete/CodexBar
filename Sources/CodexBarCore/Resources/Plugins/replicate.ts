defineProvider({
  id: "replicate",
  name: "Replicate",
  endpoints: ["https://replicate.com"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["replicate.com"],
  async fetchUsage(ctx) {
    const fail = (field: string): never => {
      throw ctx.fail.parseFailure(`Replicate billing response format changed: ${field}`);
    };
    const record = (value: unknown): Record<string, unknown> | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : undefined;
    const parse = (body: string): unknown => {
      try {
        return JSON.parse(body);
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
    };
    const money = (value: unknown): number | undefined => {
      if (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value.trim())) return undefined;
      const number = Number(value.trim());
      return Number.isFinite(number) && number >= 0 ? number : undefined;
    };
    const expired = (): never => {
      throw ctx.fail.authenticationExpired("Replicate session expired. Sign in again or paste a fresh Cookie header.");
    };
    const validate = (response: CodexBarHTTPTextResponse): void => {
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
    let account: { kind: string; username: string } | undefined;
    const scripts = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
    let match: RegExpExecArray | null;
    let visited = 0;
    while ((match = scripts.exec(response.bodyText)) && !account && visited < 4000) {
      if (
        !/\bid\s*=\s*(["'])react-component-props[^"']*\1/i.test(match[1]) ||
        !/\btype\s*=\s*(["'])application\/json\1/i.test(match[1])
      )
        continue;
      let payload: unknown;
      try {
        payload = JSON.parse(match[2]);
      } catch (error) {
        void error;
        continue;
      }
      const queue: unknown[] = [payload];
      for (let index = 0; index < queue.length && visited < 4000; index++, visited++) {
        const item = queue[index];
        const object = record(item);
        const candidate = record(object?.account);
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
    const invoices = record(parse(invoicesResponse.bodyText))?.invoices;
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
    let balance: number | undefined;
    try {
      const credit = await ctx.http.get(`${base}/unused-credit`, { headers: { Cookie: cookie }, timeoutSeconds: 2 });
      if (credit.status >= 200 && credit.status < 300) balance = money(record(parse(credit.bodyText))?.unused_credit);
    } catch (error) {
      void error;
    }
    const rows: CodexBarDetailRow[] = [{ label: "Spent this month", value: ctx.format.usd(used) }];
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
