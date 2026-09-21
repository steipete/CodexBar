defineProvider({
  id: "helmcode",
  name: "Helmcode",
  endpoints: ["https://cloud-api.helmcode.com", "https://cloud-api.nan.builders"],
  settings: [{ key: "TENANT", title: "Manual cookie tenant", type: "plain" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["helmcode.com", "nan.builders"],
  async fetchUsage(ctx) {
    const tenants = [
      { domain: "helmcode.com", name: "Helmcode Cloud" },
      { domain: "nan.builders", name: "NaN Builders" },
    ];
    const policy = ctx.browser.availability(tenants[0].domain);
    if (policy === "off") throw ctx.fail.missingCredential("Helmcode dashboard cookies are disabled.");
    // A pasted header has no origin metadata. Never try it against both tenants.
    const candidates = policy === "manual" ? [tenants[ctx.settings.get("TENANT") === "nanBuilders" ? 1 : 0]] : tenants;
    const fail = (field: string): never => {
      throw ctx.fail.parseFailure(`Helmcode quota response format changed: ${field}`);
    };
    const object = (value: unknown): Record<string, unknown> | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : undefined;
    const parse = (body: string): Record<string, unknown> => {
      try {
        return object(JSON.parse(body)) ?? fail("expected object");
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
    };
    const integer = (value: unknown, field: string): number => {
      if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return fail(field);
      return value;
    };
    const date = (value: unknown): Date | undefined => {
      if (typeof value !== "string") return undefined;
      try {
        return ctx.date.iso(value);
      } catch (error) {
        void error;
        return undefined;
      }
    };
    const validate = (response: CodexBarHTTPTextResponse): void => {
      const seconds = Number(response.headers["retry-after"] ?? 1);
      const retryAfterSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.min(10, seconds) : 1;
      if (response.status === 429) throw ctx.fail.rateLimited("Helmcode rate limit reached.", { retryAfterSeconds });
      if (response.status === 408 || response.status >= 500)
        throw ctx.fail.providerUnavailable("Helmcode dashboard is unavailable.", { retryAfterSeconds });
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`Helmcode dashboard returned HTTP ${response.status}.`);
    };
    let rejected = false;
    for (const tenant of candidates) {
      let cookie: string;
      try {
        cookie = await ctx.browser.cookieHeader(tenant.domain);
      } catch (error) {
        void error;
        continue;
      }
      const headers = {
        Cookie: cookie,
        Origin: `https://cloud.${tenant.domain}`,
        Referer: `https://cloud.${tenant.domain}/dashboard`,
      };
      const get = (path: string, timeoutSeconds = 8) =>
        ctx.http.get(`https://cloud-api.${tenant.domain}${path}`, { headers, timeoutSeconds });
      const response = await get("/api/usage/quota");
      if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403) {
        ctx.browser.rejectCookie(tenant.domain);
        rejected = true;
        continue;
      }
      validate(response);
      const quota = parse(response.bodyText);
      if (typeof quota.periodStart !== "string" || !Array.isArray(quota.models)) return fail("periodStart or models");
      const optional = async (path: string): Promise<Record<string, unknown> | undefined> => {
        try {
          const result = await get(path, 2);
          return result.status === 200 ? parse(result.bodyText) : undefined;
        } catch (error) {
          void error;
          return undefined;
        }
      };
      const billing = await optional("/api/billing");
      const premium = object(billing?.subscription)?.premium === true;
      const start = /^(\d{4})-(\d{2})-(\d{2})(?:T|$)/.exec(quota.periodStart);
      const fallback =
        start && Number(start[2]) >= 1 && Number(start[2]) <= 12 && Number(start[3]) >= 1 && Number(start[3]) <= 31
          ? new Date(Date.UTC(Number(start[1]), Number(start[2]), 1))
          : undefined;
      const models = quota.models
        .map((value: unknown) => {
          const row = object(value) ?? fail("model");
          if (typeof row.model !== "string" || !ctx.isDetailLabel(row.model)) return fail("model name");
          const cap = integer(row.cap, "cap");
          const used = integer(row.tokensUsed, "tokensUsed");
          const credit = row.creditTokens == null ? 0 : integer(row.creditTokens, "creditTokens");
          const hours = row.windowHours == null ? undefined : integer(row.windowHours, "windowHours");
          if (hours !== undefined && (hours < 1 || hours > 525600 / 60)) return fail("windowHours");
          return { name: row.model, cap, used, credit, hours, resetsAt: date(row.periodEnd) ?? fallback };
        })
        .filter((row) => row.cap > 0 && (row.hours === undefined || premium));
      models.sort((a, b) => b.used / b.cap - a.used / a.cap || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      const windows = models.map((row) => ({
        id: `helmcode-${row.name}`,
        title: row.name,
        window: {
          usedPercent: ctx.pct(row.used, row.cap),
          resetsAt: row.resetsAt,
          windowMinutes: row.hours === undefined ? undefined : row.hours * 60,
          resetDescription:
            `${row.name} · ${ctx.format.number(row.used)} / ${ctx.format.number(row.cap)} tokens` +
            (row.credit > 0 ? ` · ${ctx.format.number(row.credit)} credit-funded` : ""),
        },
      }));
      let cost: CodexBarCostSnapshot | undefined;
      if (tenant.domain === "helmcode.com") {
        const credits = await optional("/api/billing/credits");
        const balance = credits?.balanceMicros;
        const currency =
          credits?.currency == null
            ? "EUR"
            : typeof credits.currency === "string"
              ? credits.currency.toUpperCase()
              : "";
        if (typeof balance === "number" && Number.isSafeInteger(balance) && /^[A-Z]{3}$/.test(currency))
          cost = { used: Math.max(0, balance / 1e6), limit: 0, currency, period: "Prepaid balance" };
      }
      return {
        primary: windows[0]?.window,
        extraWindows: windows.slice(1),
        cost,
        identity: { organization: tenant.name, loginMethod: "Dashboard session" },
        dataConfidence: "exact",
      };
    }
    if (rejected) throw ctx.fail.authenticationExpired("Helmcode dashboard session expired. Sign in again.");
    throw ctx.fail.missingCredential(
      "Sign in to cloud.helmcode.com or cloud.nan.builders in Chrome, or paste a Cookie header.",
    );
  },
});
