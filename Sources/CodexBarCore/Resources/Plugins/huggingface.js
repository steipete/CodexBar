defineProvider({
  id: "huggingface",
  name: "Hugging Face",
  endpoints: ["https://huggingface.co"],
  auth: { type: "bearer", secret: "HF_TOKEN" },
  settings: [{ key: "HF_TOKEN", title: "API token", type: "secure" }],
  capabilities: ["http-status"],

  async fetchUsage(ctx) {
    const root = "https://huggingface.co";
    const identityCacheTTLSeconds = 12 * 60 * 60;

    function parseFailure(message) {
      throw ctx.fail.parseFailure(`Could not parse Hugging Face billing data: ${message}`);
    }

    function object(value, field) {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        parseFailure(`${field} must be an object`);
      }
      return value;
    }

    function requiredString(value, field) {
      if (typeof value !== "string" || !value.trim()) {
        parseFailure(`${field} must be a non-empty string`);
      }
      return value.trim();
    }

    function optionalString(value, field) {
      if (value === null || value === undefined) return null;
      if (typeof value !== "string") parseFailure(`${field} must be a string`);
      const trimmed = value.trim();
      return trimmed || null;
    }

    function nonnegativeFiniteNumber(value) {
      if (value === null || value === undefined || String(value).trim() === "") return null;
      const parsed = Number(String(value).trim());
      return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
    }

    function retryAfterSeconds(response) {
      const headers = response.headers || {};
      const rateLimit = headers.ratelimit;
      if (typeof rateLimit === "string") {
        for (const part of rateLimit.split(";")) {
          const match = /^\s*t\s*=\s*(.*?)\s*$/.exec(part);
          if (!match) continue;
          const seconds = nonnegativeFiniteNumber(match[1]);
          if (seconds !== null) return seconds;
        }
      }
      return nonnegativeFiniteNumber(headers["retry-after"]);
    }

    function classifyStatus(status, resource, response) {
      if (status === 401) {
        if (resource === "billing") {
          throw ctx.fail.authenticationExpired(
            "Hugging Face rejected access to personal billing usage. The token may be invalid or expired.",
          );
        }
        throw ctx.fail.authenticationExpired(
          "Hugging Face rejected the user access token. It may be invalid or expired.",
        );
      }
      if (resource === "billing" && status === 403) {
        throw ctx.fail.permissionDenied(
          "Hugging Face denied access to personal billing usage. A fine-grained token may require the Billing read permission.",
        );
      }
      if (resource === "billing" && status === 404) {
        throw ctx.fail.apiFailure("Hugging Face personal billing usage was not found.");
      }
      if (status === 429) {
        const retryAfter = retryAfterSeconds(response);
        if (retryAfter === null) {
          throw ctx.fail.rateLimited("Hugging Face rate limit exceeded. Usage will refresh on the next cycle.");
        }
        throw ctx.fail.rateLimited(
          "Hugging Face rate limit exceeded. Retry in " +
            ctx.format.number(retryAfter) +
            " seconds. Usage will refresh on the next cycle.",
          { retryAfterSeconds: retryAfter },
        );
      }
      if (status >= 500 && status <= 599) {
        throw ctx.fail.providerUnavailable(`Hugging Face ${resource} API returned HTTP ${status}.`);
      }
      if (status < 200 || status >= 300) {
        throw ctx.fail.apiFailure(`Hugging Face ${resource} API returned HTTP ${status}.`);
      }
    }

    async function getJSON(url, resource) {
      const response = await ctx.http.get(url);
      classifyStatus(response.status, resource, response);
      try {
        return JSON.parse(response.bodyText);
      } catch {
        parseFailure(`${resource} response was not valid JSON`);
      }
    }

    function parseIdentity(profile) {
      const value = object(profile, "identity response");
      const username = requiredString(value.name, "identity.name");
      const email = optionalString(value.email, "identity.email");
      if (value.isPro !== undefined && value.isPro !== null && typeof value.isPro !== "boolean") {
        parseFailure("identity.isPro must be a boolean");
      }
      return {
        email: email || undefined,
        accountID: username,
        ...(value.isPro === true ? { loginMethod: "PRO" } : {}),
      };
    }

    async function fetchIdentity(ctx) {
      const token = ctx.settings.getSecret("HF_TOKEN");
      if (typeof token !== "string" || !token.trim()) return null;

      const cacheKey = "huggingface.identity:" + token;
      const cached = ctx.cache.get(cacheKey);
      if (cached !== undefined) return cached;

      const profile = await getJSON(root + "/api/whoami-v2", "identity");
      const identity = parseIdentity(profile);
      ctx.cache.set(cacheKey, identity, identityCacheTTLSeconds);
      return identity;
    }

    function parsePeriod(period) {
      const value = object(period, "billing.period");
      const periodStartText = requiredString(value.periodStart, "billing.period.periodStart");
      const periodEndText = requiredString(value.periodEnd, "billing.period.periodEnd");
      let periodStart;
      let periodEnd;
      try {
        periodStart = ctx.date.iso(periodStartText);
        periodEnd = ctx.date.iso(periodEndText);
      } catch {
        parseFailure("billing.period.periodStart and billing.period.periodEnd must be valid ISO-8601 dates");
      }
      if (periodEnd.getTime() < periodStart.getTime()) {
        parseFailure("billing.period.periodEnd must not precede billing.period.periodStart");
      }
      return { periodStart, periodEnd };
    }

    function finiteNonnegativeCost(value, field) {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        parseFailure(`${field} must be a finite nonnegative number`);
      }
      if (value > Number.MAX_SAFE_INTEGER) {
        parseFailure(`${field} exceeds the safe numeric range`);
      }
      return value;
    }

    function addCosts(total, cost, field) {
      const next = total + cost;
      if (!Number.isFinite(next) || next > Number.MAX_SAFE_INTEGER) {
        parseFailure(`${field} total exceeds the safe numeric range`);
      }
      return next;
    }

    function categoryLabel(value) {
      const normalized = value
        .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
        .replace(/[_-]+/g, " ")
        .trim();
      if (!normalized) return "Unknown";
      return normalized.replace(/\b\w/g, (character) => character.toUpperCase());
    }

    function compareRows(a, b) {
      if (a.costMicroUSD !== b.costMicroUSD) return b.costMicroUSD - a.costMicroUSD;
      if (a.label < b.label) return -1;
      if (a.label > b.label) return 1;
      return 0;
    }

    // This settings response is the selected finite billing source. Sum only the categories it returns;
    // do not infer whole-account coverage or credits from other Hugging Face billing routes.
    const billing = object(await getJSON(`${root}/api/settings/billing/usage`, "billing"), "billing response");
    // Billing is authoritative and is intentionally fetched before optional identity enrichment.
    const period = parsePeriod(billing.period);
    const usage = object(billing.usage, "billing.usage");
    const categoryRows = [];
    let totalMicroUSD = 0;
    for (const category of Object.keys(usage)) {
      const items = usage[category];
      if (!Array.isArray(items)) {
        parseFailure(`billing.usage.${category} must be an array`);
      }
      let categoryTotalMicroUSD = 0;
      for (let index = 0; index < items.length; index += 1) {
        const item = items[index];
        object(item, `billing.usage.${category}[${index}]`);
        const cost = finiteNonnegativeCost(
          item.totalCostMicroUSD,
          `billing.usage.${category}[${index}].totalCostMicroUSD`,
        );
        categoryTotalMicroUSD = addCosts(categoryTotalMicroUSD, cost, `billing.usage.${category}`);
      }
      totalMicroUSD = addCosts(totalMicroUSD, categoryTotalMicroUSD, "billing.usage");
      categoryRows.push({
        label: categoryLabel(category),
        costMicroUSD: categoryTotalMicroUSD,
      });
    }

    const totalUSD = totalMicroUSD / 1_000_000;
    if (!Number.isFinite(totalUSD)) parseFailure("billing cost total overflowed");
    categoryRows.sort(compareRows);

    let identity = null;
    try {
      identity = await fetchIdentity(ctx);
    } catch {
      // Billing remains useful when identity is unavailable or malformed.
    }

    const periodStartLabel = period.periodStart.toISOString().slice(0, 10);
    const periodEndLabel = period.periodEnd.toISOString().slice(0, 10);

    return {
      cost: {
        used: totalUSD,
        currency: "USD",
        period: "Reported billing period",
        resetsAt: period.periodEnd,
      },
      identity,
      dataConfidence: "exact",
      details: [
        {
          title: "Billing summary",
          rows: [
            { label: "Billing period", value: `${periodStartLabel} – ${periodEndLabel}` },
            { label: "Reported spend", value: ctx.format.usd(totalUSD) },
            ...(identity && identity.loginMethod === "PRO" ? [{ label: "Plan", value: "PRO" }] : []),
          ],
        },
        {
          title: "Usage breakdown",
          rows: categoryRows.map((row) => ({
            label: row.label,
            value: ctx.format.usd(row.costMicroUSD / 1_000_000),
          })),
        },
      ],
    };
  },
});
