type V0BillingResponse = {
  billingType?: unknown;
  data?: unknown;
};

const V0_API_BASE = "https://api.v0.dev/v1";

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

    function apiError(response: { status: number }): never {
      if (response.status === 401) throw ctx.fail.authenticationExpired("v0 API key was rejected.");
      if (response.status === 403) throw ctx.fail.permissionDenied("v0 denied access to this scope.");
      if (response.status === 429) throw ctx.fail.rateLimited("v0 API rate limit reached.");
      if (response.status >= 500) throw ctx.fail.providerUnavailable(`v0 API returned HTTP ${response.status}.`);
      throw ctx.fail.apiFailure(`v0 API returned HTTP ${response.status}.`);
    }

    function fail(field: string): never {
      throw ctx.fail.parseFailure(`Could not parse v0 usage: ${field}`);
    }

    function object(value: unknown, field: string): Record<string, unknown> {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value as Record<string, unknown>;
    }

    function number(value: unknown, field: string): number {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    }

    function text(value: unknown, field: string): string | undefined {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    }

    function reset(value: unknown, field: string): Date | undefined {
      if (value === undefined || value === null) return undefined;
      const timestamp = number(value, field);
      if (timestamp <= 0) return undefined;
      return timestamp >= 1_000_000_000_000 ? ctx.date.unixMillis(timestamp) : ctx.date.unixSeconds(timestamp);
    }

    function optionalNumber(value: unknown, field: string): number | undefined {
      if (value === undefined || value === null) return undefined;
      return number(value, field);
    }

    function quota(value: unknown, field: string) {
      const payload = object(value, field);
      const limit = number(payload.limit, `${field}.limit`);
      const remaining = optionalNumber(payload.remaining, `${field}.remaining`);
      if (limit < 0) return fail(`${field}.limit must not be negative`);
      return {
        usedPercent: remaining === undefined ? undefined : ctx.pct(Math.max(0, limit - remaining), limit),
        resetsAt: reset(payload.reset, `${field}.reset`),
        remaining,
        limit,
      };
    }

    function legacyBilling(value: unknown, field: string) {
      const parsed = quota(value, field);
      if (parsed.remaining === undefined) return fail(`${field}.remaining`);
      return {
        usedPercent: ctx.pct(Math.max(0, parsed.limit - parsed.remaining), parsed.limit),
        resetsAt: parsed.resetsAt,
        remaining: parsed.remaining,
        limit: parsed.limit,
      };
    }

    function tokenBilling(value: unknown, field: string) {
      const payload = object(value, field);
      const balance = object(payload.balance, `${field}.balance`);
      const total = number(balance.total, `${field}.balance.total`);
      const remaining = number(balance.remaining, `${field}.balance.remaining`);
      const billingCycle = object(payload.billingCycle, `${field}.billingCycle`);
      if (total < 0) return fail(`${field}.balance.total must not be negative`);
      return {
        usedPercent: ctx.pct(Math.max(0, total - remaining), total),
        resetsAt: reset(billingCycle.end, `${field}.billingCycle.end`),
        remaining,
        limit: total,
      };
    }

    const billingResponse = await ctx.http.getJSON(`${V0_API_BASE}/user/billing${query}`);
    if (billingResponse.status !== 200) apiError(billingResponse);
    const billing = object(billingResponse.json as V0BillingResponse, "billing response");
    const billingType = text(billing.billingType, "billingType");
    const billingData =
      billingType === "token"
        ? tokenBilling(billing.data, "billing.data")
        : legacyBilling(billing.data, "billing.data");

    const rateLimitResponse = await ctx.http.getJSON(`${V0_API_BASE}/rate-limits${query}`);
    if (rateLimitResponse.status !== 200) apiError(rateLimitResponse);
    const rateLimit = quota(rateLimitResponse.json, "rate limit response");
    const rateRemaining = rateLimit.remaining;

    const billingRemaining = ctx.format.number(billingData.remaining, { maximumFractionDigits: 2 });
    const rows: CodexBarDetailRow[] = [
      {
        label: "Billing remaining",
        value: billingRemaining,
        secondaryValue: `of ${ctx.format.number(billingData.limit, { maximumFractionDigits: 2 })}`,
      },
      {
        label: "Rate-limit remaining",
        value:
          rateRemaining === undefined ? "Unavailable" : ctx.format.number(rateRemaining, { maximumFractionDigits: 2 }),
        secondaryValue:
          rateRemaining === undefined
            ? `limit ${ctx.format.number(rateLimit.limit, { maximumFractionDigits: 2 })}`
            : `of ${ctx.format.number(rateLimit.limit, { maximumFractionDigits: 2 })}`,
      },
    ];
    if (billingType) rows.push({ label: "Billing type", value: billingType });
    if (scope) rows.push({ label: "Scope", value: scope });

    return {
      primary: { usedPercent: billingData.usedPercent, resetsAt: billingData.resetsAt },
      secondary:
        rateRemaining === undefined
          ? null
          : {
              usedPercent: ctx.pct(Math.max(0, rateLimit.limit - rateRemaining), rateLimit.limit),
              resetsAt: rateLimit.resetsAt,
            },
      details: [{ title: "v0 API", rows }],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
