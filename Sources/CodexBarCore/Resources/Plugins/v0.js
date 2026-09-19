defineProvider({
  id: "v0",
  name: "v0",
  endpoints: ["https://api.v0.dev"],
  auth: { type: "bearer", secret: "V0_API_KEY" },
  settings: [
    {
      key: "V0_API_KEY",
      title: "API key",
      subtitle: "A v0 Platform API key.",
      type: "secure",
    },
    {
      key: "V0_SCOPE",
      title: "Scope",
      subtitle: "Optional project or workspace scope.",
      type: "plain",
    },
  ],
  capabilities: ["http-status"],

  async fetchUsage(ctx) {
    const scope = ctx.settings.get("V0_SCOPE");
    const query = scope ? `?scope=${encodeURIComponent(scope)}` : "";

    function apiError(response) {
      if (response.status === 401) throw ctx.fail.authenticationExpired("v0 API key was rejected.");
      if (response.status === 403) throw ctx.fail.permissionDenied("v0 denied access to this scope.");
      if (response.status === 429) throw ctx.fail.rateLimited("v0 API rate limit reached.");
      if (response.status >= 500) throw ctx.fail.providerUnavailable(`v0 API returned HTTP ${response.status}.`);
      throw ctx.fail.apiFailure(`v0 API returned HTTP ${response.status}.`);
    }

    function fail(field) {
      throw ctx.fail.parseFailure(`Could not parse v0 usage: ${field}`);
    }

    function object(value, field) {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    }

    function number(value, field) {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    }

    function text(value, field) {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    }

    function reset(value, field) {
      if (value === undefined || value === null) return undefined;
      const timestamp = number(value, field);
      if (timestamp <= 0) return undefined;
      return timestamp >= 1000000000000 ? ctx.date.unixMillis(timestamp) : ctx.date.unixSeconds(timestamp);
    }

    function quota(value, field) {
      const payload = object(value, field);
      const limit = number(payload.limit, `${field}.limit`);
      const remaining = number(payload.remaining, `${field}.remaining`);
      if (limit < 0) return fail(`${field}.limit must not be negative`);
      const used = Math.max(0, limit - remaining);
      return {
        usedPercent: ctx.pct(used, limit),
        resetsAt: reset(payload.reset, `${field}.reset`),
        remaining,
        limit,
      };
    }

    const billingResponse = await ctx.http.getJSON(`https://api.v0.dev/user/billing${query}`);
    if (billingResponse.status !== 200) apiError(billingResponse);
    const billing = object(billingResponse.json, "billing response");
    const billingData = quota(billing.data, "billing.data");

    const rateLimitResponse = await ctx.http.getJSON(`https://api.v0.dev/rate-limits${query}`);
    if (rateLimitResponse.status !== 200) apiError(rateLimitResponse);
    const rateLimit = quota(rateLimitResponse.json, "rate limit response");

    const billingType = text(billing.billingType, "billingType");
    const billingRemaining = ctx.format.number(billingData.remaining, { maximumFractionDigits: 2 });
    const rateRemaining = ctx.format.number(rateLimit.remaining, { maximumFractionDigits: 2 });
    const rows = [
      {
        label: "Billing remaining",
        value: billingRemaining,
        secondaryValue: `of ${ctx.format.number(billingData.limit, { maximumFractionDigits: 2 })}`,
      },
      {
        label: "Rate-limit remaining",
        value: rateRemaining,
        secondaryValue: `of ${ctx.format.number(rateLimit.limit, { maximumFractionDigits: 2 })}`,
      },
    ];
    if (billingType) rows.push({ label: "Billing type", value: billingType });
    if (scope) rows.push({ label: "Scope", value: scope });

    return {
      primary: { usedPercent: billingData.usedPercent, resetsAt: billingData.resetsAt },
      secondary: { usedPercent: rateLimit.usedPercent, resetsAt: rateLimit.resetsAt },
      details: [{ title: "v0 API", rows }],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
