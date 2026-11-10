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
    const integer = (value: unknown, field: string): number => {
      if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) return fail(field);
      return value;
    };
    /** Credits are fractional (10.6 of 7,000), so they cannot use `integer`. */
    const decimal = (value: unknown, field: string): number => {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return fail(field);
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
      const response = await get("/api/usage/quota");
      if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403) {
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
        continue;
      }
      const seconds = Number(response.headers["retry-after"] ?? 1);
      const retryAfterSeconds = Number.isFinite(seconds) && seconds >= 0 ? Math.min(10, seconds) : 1;
      if (response.status === 429) throw ctx.fail.rateLimited("Helmcode rate limit reached.", { retryAfterSeconds });
      if (response.status === 408 || response.status >= 500)
        throw ctx.fail.providerUnavailable("Helmcode dashboard is unavailable.", { retryAfterSeconds });
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`Helmcode dashboard returned HTTP ${response.status}.`);
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
      // NaN metered inference in credits from 10 Nov 2026. `/api/usage/quota`
      // keeps answering with the per-model token caps it had before the switch,
      // frozen at the last legacy request, so those windows are history for any
      // tenant that reports a credit plan. The plan is credited per billing
      // period, not per calendar month, and each model spends at its own weight.
      const creditUsage = await optional("/api/usage/credits");
      if (creditUsage?.enabled === true) {
        const allowance = decimal(creditUsage.allowanceCredits, "allowanceCredits");
        const spent = decimal(creditUsage.usedCredits, "usedCredits");
        if (allowance <= 0) return fail("allowanceCredits");
        const periodStart =
          typeof creditUsage.periodStart === "string" ? ctx.date.iso(creditUsage.periodStart) : undefined;
        const periodEnd = typeof creditUsage.periodEnd === "string" ? ctx.date.iso(creditUsage.periodEnd) : undefined;
        const minutes =
          periodStart && periodEnd && periodEnd.getTime() > periodStart.getTime()
            ? Math.round((periodEnd.getTime() - periodStart.getTime()) / 60000)
            : undefined;
        const weights = (Array.isArray(creditUsage.models) ? creditUsage.models : [])
          .map((value: unknown) => {
            const row = object(value) ?? fail("credit model");
            if (typeof row.model !== "string" || !ctx.isDetailLabel(row.model)) return fail("credit model name");
            return {
              name: row.model,
              spent: row.creditsThisMonth == null ? 0 : decimal(row.creditsThisMonth, "creditsThisMonth"),
              weight:
                row.approxCreditsPerMTokens == null
                  ? undefined
                  : decimal(row.approxCreditsPerMTokens, "approxCreditsPerMTokens"),
            };
          })
          .sort((a, b) => b.spent - a.spent || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
        const rows: Array<{ label: string; value: string; secondaryValue?: string }> = weights
          .slice(0, 20)
          .map((row) => ({
            label: row.name,
            value: `${ctx.format.number(row.spent, { maximumFractionDigits: 2 })} credits`,
            secondaryValue:
              row.weight === undefined
                ? undefined
                : `${ctx.format.number(row.weight, { maximumFractionDigits: 3 })} per million tokens`,
          }));

        if (weights.length > rows.length) rows.push({
          label: "Other models",
          value: `${weights.length - rows.length} more`,
        });
        if (creditUsage.packCredits != null) {
          const pack = decimal(creditUsage.packCredits, "packCredits");
          if (pack > 0) rows.push({
            label: "Credit pack",
            value: `${ctx.format.number(pack, { maximumFractionDigits: 2 })} credits`,
          });
        }
        if (creditUsage.frozen === true) rows.push({ label: "Credits", value: "Paused during grace period" });
        return {
          primary: {
            title: "Credits",
            usedPercent: ctx.pct(spent, allowance),
            resetsAt: periodEnd,
            windowMinutes: minutes,
            quotaLimit: allowance,
            quotaUnit: "credits",
            resetDescription: `${ctx.format.number(spent, { maximumFractionDigits: 2 })} / ${ctx.format.number(allowance)} credits`,
          },
          details: [{ title: "Credits by model", rows }],
          identity: { organization: tenant.name, loginMethod: "Dashboard session" },
          dataConfidence: "exact",
        };
      }
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
