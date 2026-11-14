defineProvider({
  id: "helmcode",
  name: "Helmcode",
  endpoints: ["https://cloud-api.helmcode.com", "https://cloud-api.nan.builders"],
  settings: [{ key: "TENANT", title: "Manual cookie tenant", type: "plain" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["helmcode.com", "cloud-api.helmcode.com", "nan.builders"],
  async fetchUsage(ctx) {
    const tenants = [
      { domain: "helmcode.com", cookieDomain: "cloud-api.helmcode.com", name: "Helmcode Cloud" },
      { domain: "nan.builders", cookieDomain: "nan.builders", name: "NaN Builders" },
    ];
    const policy = ctx.browser.availability(tenants[0].cookieDomain);
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
    const amount = (value: unknown, field: string, fractional = false): number => {
      const valid = fractional ? Number.isFinite(value) : Number.isSafeInteger(value);
      if (typeof value !== "number" || !valid || value < 0) return fail(field);
      return value;
    };
    async function* sessions() {
      for (const tenant of candidates) {
        const domains =
          policy !== "manual" && tenant.domain !== tenant.cookieDomain
            ? [tenant.domain, tenant.cookieDomain, tenant.domain]
            : [tenant.cookieDomain];
        // Try the old cache first, then API-host and parent-domain browser sessions.
        for (const [index, domain] of domains.entries()) {
          try {
            for await (const session of ctx.browser.sessions(domain, {
              cachedOnly: domains.length > 1 && index === 0,
            })) {
              yield { tenant, domain, session };
            }
          } catch (error) {
            void error;
          }
        }
      }
    }
    let rejected = false;
    for await (const { tenant, domain, session } of sessions()) {
      if (!session.header) continue;
      const headers = {
        Cookie: session.header,
        Origin: `https://cloud.${tenant.domain}`,
        Referer: `https://cloud.${tenant.domain}/dashboard`,
      };
      const get = (path: string, timeoutSeconds = 8) =>
        ctx.http.get(`https://cloud-api.${tenant.domain}${path}`, { headers, timeoutSeconds });
      const required = async (path: string, allowMissing = false) => {
        const response = await get(path);
        if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403) {
          ctx.browser.rejectCookie(domain, session);
          rejected = true;
          return undefined;
        }
        const seconds = Number(response.headers["retry-after"] ?? 1);
        const retryAfterSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.min(10, seconds) : 1;
        if (response.status === 429) throw ctx.fail.rateLimited("Helmcode rate limit reached.", { retryAfterSeconds });
        if (response.status === 408 || response.status >= 500)
          throw ctx.fail.providerUnavailable("Helmcode dashboard is unavailable.", { retryAfterSeconds });
        if ((response.status < 200 || response.status >= 300) && !(allowMissing && response.status === 404))
          throw ctx.fail.apiFailure(`Helmcode dashboard returned HTTP ${response.status}.`);
        return response;
      };
      const creditResponse = await required("/api/usage/credits", true);
      if (!creditResponse) continue;
      const credits = creditResponse.status === 404 ? undefined : parse(creditResponse.bodyText);
      if (credits && typeof credits.enabled !== "boolean") return fail("enabled");
      // Only an absent or explicitly disabled credit plan permits legacy token quotas.
      if (credits?.enabled) {
        const allowance = amount(credits.allowanceCredits, "allowanceCredits", true);
        const spent = amount(credits.usedCredits, "usedCredits", true);
        if (allowance <= 0) return fail("allowanceCredits");
        const start = typeof credits.periodStart === "string" ? ctx.date.iso(credits.periodStart) : undefined;
        const end = typeof credits.periodEnd === "string" ? ctx.date.iso(credits.periodEnd) : undefined;
        const format = (value: unknown, field: string) =>
          value == null ? "—" : ctx.format.number(amount(value, field, true), { maximumFractionDigits: 3 });
        const models = (Array.isArray(credits.models) ? credits.models : []).map((value: unknown) => {
          const row = object(value) ?? fail("credit model");
          if (typeof row.model !== "string" || !ctx.isDetailLabel(row.model)) return fail("credit model name");
          return {
            label: row.model,
            value: format(row.creditsThisMonth, "creditsThisMonth"),
            weight: format(row.approxCreditsPerMTokens, "approxCreditsPerMTokens"),
          };
        });
        const rows: CodexBarDetailRow[] = models.slice(0, 20).map(({ label, value }) => ({ label, value }));
        if (models.length > 20) rows.push({ label: "Other models", value: "—" });
        const planRows: CodexBarDetailRow[] = [];
        if (credits.packCredits != null)
          planRows.push({ label: "Top-up credits", value: format(credits.packCredits, "packCredits") });
        if (credits.frozen === true) planRows.push({ label: "Paused during grace period", value: "—" });
        return {
          primary: {
            title: "Credits",
            usedPercent: ctx.pct(spent, allowance),
            resetsAt: end,
            windowMinutes:
              start && end && end > start ? Math.round((end.getTime() - start.getTime()) / 60000) : undefined,
            quotaLimit: allowance,
            quotaUnit: "credits",
            resetDescription: `${format(spent, "usedCredits")} / ${format(allowance, "allowanceCredits")}`,
          },
          details: [
            { title: "Credits used", rows },
            {
              title: "Credits per million tokens",
              rows: models.slice(0, 20).map(({ label, weight }) => ({ label, value: weight })),
            },
            ...(planRows.length ? [{ title: "Credits", rows: planRows }] : []),
          ],
          identity: { organization: tenant.name, loginMethod: "Dashboard session" },
          dataConfidence: "exact",
        };
      }
      const response = await required("/api/usage/quota");
      if (!response) continue;
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
          const cap = amount(row.cap, "cap");
          const used = amount(row.tokensUsed, "tokensUsed");
          const credit = row.creditTokens == null ? 0 : amount(row.creditTokens, "creditTokens");
          const hours = row.windowHours == null ? undefined : amount(row.windowHours, "windowHours");
          if (hours !== undefined && (hours < 1 || hours > 525600 / 60)) return fail("windowHours");
          let resetsAt = fallback;
          if (typeof row.periodEnd === "string") {
            try {
              resetsAt = ctx.date.iso(row.periodEnd) ?? fallback;
            } catch (error) {
              void error;
            }
          }
          return { name: row.model, cap, used, credit, hours, resetsAt };
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
      `Sign in to cloud.helmcode.com or cloud.nan.builders. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste a Cookie header.`,
    );
  },
});
