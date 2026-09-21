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
      subtitle: "Optional project ID or slug.",
      type: "plain",
    },
  ],
  capabilities: ["http-status"],

  async fetchUsage(ctx) {
    const scope = ctx.settings.get("V0_SCOPE")?.trim();
    const query = scope ? `?scope=${encodeURIComponent(scope)}` : "";

    function apiError(response: { status: number; headers: Record<string, string> }): never {
      if (response.status === 401) throw ctx.fail.authenticationExpired("v0 API key was rejected.");
      if (response.status === 403) throw ctx.fail.permissionDenied("v0 denied access to this scope.");
      if (response.status === 429) {
        const delay = Number(response.headers["retry-after"] ?? 1);
        throw ctx.fail.rateLimited("v0 API rate limit reached.", {
          retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
        });
      }
      if (response.status >= 500) throw ctx.fail.providerUnavailable(`v0 API returned HTTP ${response.status}.`);
      throw ctx.fail.apiFailure(`v0 API returned HTTP ${response.status}.`);
    }

    function fail(field: string): never {
      throw ctx.fail.parseFailure(`Could not parse v0 usage: ${field}`);
    }

    async function getJSON(path: string): Promise<unknown> {
      const response = await ctx.http.get(`${V0_API_BASE}${path}${query}`);
      if (response.status !== 200) apiError(response);
      try {
        return JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return fail(`${path} returned invalid JSON`);
      }
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

    function tokenBilling(value: unknown, field: string) {
      const payload = object(value, field);
      const balance = object(payload.balance, `${field}.balance`);
      const total = number(balance.total, `${field}.balance.total`);
      const remaining = number(balance.remaining, `${field}.balance.remaining`);
      const billingCycle = object(payload.billingCycle, `${field}.billingCycle`);
      const onDemand =
        payload.onDemand === undefined || payload.onDemand === null
          ? undefined
          : object(payload.onDemand, `${field}.onDemand`);
      if (total < 0) return fail(`${field}.balance.total must not be negative`);
      return {
        usedPercent: ctx.pct(Math.max(0, total - remaining), total),
        resetsAt: reset(billingCycle.end, `${field}.billingCycle.end`),
        remaining,
        limit: total,
        onDemandBalance: onDemand === undefined ? undefined : number(onDemand.balance, `${field}.onDemand.balance`),
      };
    }

    const billing = object(await getJSON("/user/billing"), "billing response");
    const billingType = text(billing.billingType, "billingType");
    if (billingType !== "token" && billingType !== "legacy") return fail("billingType");
    const tokenBillingData = billingType === "token" ? tokenBilling(billing.data, "billing.data") : undefined;
    const billingData = tokenBillingData ?? quota(billing.data, "billing.data");

    const rateLimit = quota(await getJSON("/rate-limits"), "rate limit response");
    const rateRemaining = rateLimit.remaining;

    const billingRemaining = billingData.remaining;
    const rows: CodexBarDetailRow[] = [
      {
        label: "Billing remaining",
        value:
          billingRemaining === undefined
            ? "Unavailable"
            : ctx.format.number(billingRemaining, { maximumFractionDigits: 2 }),
        secondaryValue: `${billingRemaining === undefined ? "limit" : "of"} ${ctx.format.number(billingData.limit, { maximumFractionDigits: 2 })}`,
      },
    ];
    if (tokenBillingData?.onDemandBalance !== undefined) {
      rows.push({
        label: "On-demand balance",
        value: ctx.format.number(tokenBillingData.onDemandBalance, { maximumFractionDigits: 2 }),
      });
    }
    rows.push({
      label: "Rate-limit remaining",
      value:
        rateRemaining === undefined ? "Unavailable" : ctx.format.number(rateRemaining, { maximumFractionDigits: 2 }),
      secondaryValue:
        rateRemaining === undefined
          ? `limit ${ctx.format.number(rateLimit.limit, { maximumFractionDigits: 2 })}`
          : `of ${ctx.format.number(rateLimit.limit, { maximumFractionDigits: 2 })}`,
    });
    if (billingType) rows.push({ label: "Billing type", value: billingType });
    if (scope) rows.push({ label: "Scope", value: scope.slice(0, 120) });

    return {
      primary:
        billingData.usedPercent === undefined
          ? null
          : { usedPercent: billingData.usedPercent, resetsAt: billingData.resetsAt },
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
