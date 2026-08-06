defineProvider({
  id: "sub2api",
  name: "sub2api",
  endpoints: [{ setting: "SUB2API_BASE_URL", policy: "https-or-loopback-http" }],
  auth: { type: "bearer", secret: "SUB2API_API_KEY" },
  settings: [
    { key: "SUB2API_API_KEY", title: "API key", type: "secure" },
    { key: "SUB2API_BASE_URL", title: "Base URL", type: "plain" },
  ],
  async fetchUsage(ctx) {
    let base = ctx.settings.get("SUB2API_BASE_URL").replace(/\/+$/, "");
    if (!/\/v1(?:\/usage)?$/.test(base)) base += "/v1";
    if (!/\/usage$/.test(base)) base += "/usage";
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    let response;
    try {
      response = await ctx.http.get(`${base}?days=30&timezone=${encodeURIComponent(timezone)}`, {
        timeoutSeconds: 15,
      });
    } catch (error) {
      throw ctx.fail.networkFailure(`sub2api network error: ${error && error.message || error}`);
    }
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired(
        "sub2api rejected the API key. Check that the key is active and assigned to a group.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("sub2api API returned HTTP 429.");
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable(`sub2api API returned HTTP ${response.status}.`);
    }
    if (response.status < 200 || response.status >= 300) {
      throw ctx.fail.apiFailure(`sub2api API returned HTTP ${response.status}.`);
    }

    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch (_) {
      throw ctx.fail.parseFailure("Could not parse sub2api usage: response was not valid JSON");
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw ctx.fail.parseFailure("Could not parse sub2api usage: response must be an object");
    }

    function optional(value, field, type) {
      if (value === null || value === undefined) return null;
      if (typeof value !== type || (type === "number" && !Number.isFinite(value))) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} has an invalid type`);
      }
      return value;
    }
    function requiredNumber(value, field) {
      const number = optional(value, field, "number");
      if (number === null) throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} is required`);
      return number;
    }
    function requiredString(value, field) {
      const string = optional(value, field, "string");
      if (string === null || !string) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} is required`);
      }
      return string;
    }
    function parseDate(value, field) {
      const text = optional(value, field, "string");
      if (text === null) return undefined;
      try { return ctx.date.iso(text); } catch (_) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} is not a valid date`);
      }
    }

    const mode = optional(data.mode, "mode", "string") || "unknown";
    const isValid = optional(data.isValid, "isValid", "boolean");
    const status = optional(data.status, "status", "string");
    const planName = optional(data.planName, "planName", "string");
    optional(data.remaining, "remaining", "number");
    const balance = optional(data.balance, "balance", "number");
    const rootUnit = optional(data.unit, "unit", "string");
    if (isValid === false) {
      throw ctx.fail.authenticationExpired(
        "sub2api rejected the API key. Check that the key is active and assigned to a group.");
    }

    let quota = null;
    if (data.quota !== null && data.quota !== undefined) {
      if (!data.quota || typeof data.quota !== "object" || Array.isArray(data.quota)) {
        throw ctx.fail.parseFailure("Could not parse sub2api usage: quota must be an object");
      }
      quota = {
        limit: requiredNumber(data.quota.limit, "quota.limit"),
        used: requiredNumber(data.quota.used, "quota.used"),
        remaining: requiredNumber(data.quota.remaining, "quota.remaining"),
        unit: optional(data.quota.unit, "quota.unit", "string"),
      };
    }
    const unit = rootUnit || quota && quota.unit || "USD";

    let subscription = null;
    if (data.subscription !== null && data.subscription !== undefined) {
      if (!data.subscription || typeof data.subscription !== "object" || Array.isArray(data.subscription)) {
        throw ctx.fail.parseFailure("Could not parse sub2api usage: subscription must be an object");
      }
      subscription = {
        dailyUsage: optional(data.subscription.daily_usage_usd, "subscription.daily_usage_usd", "number") || 0,
        weeklyUsage: optional(data.subscription.weekly_usage_usd, "subscription.weekly_usage_usd", "number") || 0,
        monthlyUsage: optional(data.subscription.monthly_usage_usd, "subscription.monthly_usage_usd", "number") || 0,
        dailyLimit: optional(data.subscription.daily_limit_usd, "subscription.daily_limit_usd", "number"),
        weeklyLimit: optional(data.subscription.weekly_limit_usd, "subscription.weekly_limit_usd", "number"),
        monthlyLimit: optional(data.subscription.monthly_limit_usd, "subscription.monthly_limit_usd", "number"),
        expiresAt: parseDate(data.subscription.expires_at, "subscription.expires_at"),
      };
    }

    const money = (value, valueUnit = "USD") => valueUnit.toUpperCase() === "USD"
      ? `$${new Intl.NumberFormat("en-US", {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      }).format(value)}`
      : `${Number(value).toFixed(2)} ${valueUnit}`;
    const amount = (used, limit, valueUnit = "USD") =>
      `${money(used, valueUnit)} / ${money(limit, valueUnit)}`;
    const window = (used, limit, minutes, valueUnit = "USD") => limit !== null && limit > 0 ? ({
      usedPercent: ctx.pct(used, limit),
      windowMinutes: minutes,
      resetDescription: amount(used, limit, valueUnit),
    }) : null;
    let primary = null;
    let secondary = null;
    let tertiary = null;
    if (subscription) {
      primary = window(subscription.dailyUsage, subscription.dailyLimit, 1440);
      secondary = window(subscription.weeklyUsage, subscription.weeklyLimit, 10080);
      tertiary = window(subscription.monthlyUsage, subscription.monthlyLimit, 43200);
    } else if (quota) {
      primary = window(quota.used, quota.limit, null, quota.unit || unit);
      if (primary) delete primary.windowMinutes;
    }

    let rateLimits = data.rate_limits;
    if (rateLimits === null || rateLimits === undefined) rateLimits = [];
    if (!Array.isArray(rateLimits)) {
      throw ctx.fail.parseFailure("Could not parse sub2api usage: rate_limits must be an array");
    }
    const minuteMap = { "5h": 300, "1d": 1440, "7d": 10080 };
    const titleMap = { "5h": "5 hour limit", "1d": "Daily limit", "7d": "7 day limit" };
    const extraWindows = rateLimits.map((rate, index) => {
      if (!rate || typeof rate !== "object" || Array.isArray(rate)) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: rate_limits[${index}] must be an object`);
      }
      const rateWindow = requiredString(rate.window, `rate_limits[${index}].window`);
      const limit = requiredNumber(rate.limit, `rate_limits[${index}].limit`);
      const used = requiredNumber(rate.used, `rate_limits[${index}].used`);
      requiredNumber(rate.remaining, `rate_limits[${index}].remaining`);
      return {
        id: rateWindow,
        title: titleMap[rateWindow.toLowerCase()] || `${rateWindow} limit`,
        window: {
          usedPercent: ctx.pct(used, limit),
          windowMinutes: minuteMap[rateWindow.toLowerCase()],
          resetsAt: parseDate(rate.reset_at, `rate_limits[${index}].reset_at`),
          resetDescription: amount(used, limit),
        },
      };
    });

    function totals(value, field) {
      if (value === null || value === undefined) return null;
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} must be an object`);
      }
      const requests = optional(value.requests, `${field}.requests`, "number") || 0;
      const tokens = optional(value.total_tokens, `${field}.total_tokens`, "number") || 0;
      if (!Number.isInteger(requests) || !Number.isInteger(tokens)) {
        throw ctx.fail.parseFailure(`Could not parse sub2api usage: ${field} counts must be integers`);
      }
      return {
        requests,
        tokens,
        cost: optional(value.actual_cost, `${field}.actual_cost`, "number") || 0,
      };
    }
    let usage = data.usage;
    if (usage === null || usage === undefined) usage = {};
    if (!usage || typeof usage !== "object" || Array.isArray(usage)) {
      throw ctx.fail.parseFailure("Could not parse sub2api usage: usage must be an object");
    }
    const rows = [];
    if (balance !== null) {
      rows.push({ label: "Balance", value: money(balance, unit) });
    }
    for (const [title, value] of [
      ["Today", totals(usage.today, "usage.today")],
      ["All time", totals(usage.total, "usage.total")],
    ]) {
      if (!value) continue;
      rows.push({ label: `${title} requests`, value: new Intl.NumberFormat("en-US").format(value.requests) });
      rows.push({
        label: `${title} tokens`,
        value: new Intl.NumberFormat("en-US").format(value.tokens),
        secondaryValue: money(value.cost),
      });
    }
    const expiresAt = subscription && subscription.expiresAt || parseDate(data.expires_at, "expires_at");
    return {
      primary,
      secondary,
      tertiary,
      extraWindows,
      subscriptionExpiresAt: expiresAt,
      identity: { organization: planName, loginMethod: planName },
      details: rows.length ? [{ title: "Usage summary", rows }] : undefined,
      dataConfidence: "exact",
    };
  },
});
