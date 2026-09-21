defineProvider({
  id: "neuralwatt",
  name: "Neuralwatt",
  endpoints: [{ setting: "BASE_URL", policy: "https" }],
  auth: { type: "bearer", secret: "NEURALWATT_API_KEY" },
  settings: [
    { key: "NEURALWATT_API_KEY", title: "API key", type: "secure" },
    { key: "BASE_URL", title: "Base URL", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const configured = ctx.settings.get("BASE_URL") || "";
    const pathEnd = configured.search(/[?#]/u);
    const base = pathEnd < 0 ? configured : configured.slice(0, pathEnd);
    const suffix = pathEnd < 0 ? "" : configured.slice(pathEnd);
    const path = base.replace(/\/+$/u, "");
    const url = `${path}${decodeURIComponent(path).endsWith("/v1") ? "" : "/v1"}/quota${suffix}`;
    let response;
    try {
      response = await ctx.http.get(url, { timeoutSeconds: 15, retryPolicy: "transientIdempotent" });
    } catch (error) {
      if (error.transportClass === "cancelled") throw error;
      throw ctx.fail.networkFailure(`Neuralwatt network error: ${error.message}`);
    }
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.missingCredential(
        "Missing Neuralwatt API key. Set apiKey in the CodexBar config file or NEURALWATT_API_KEY.",
      );
    }
    if (response.status !== 200) throw ctx.fail.apiFailure(`Neuralwatt API error: HTTP ${response.status}`);
    const fail = (message) => {
      throw ctx.fail.parseFailure(`Failed to parse Neuralwatt response: ${message}`);
    };
    const object = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail("invalid object");
      return value;
    };
    const validate = (value, schema) => {
      const record = value == null ? {} : object(value);
      for (const [type, names] of Object.entries(schema))
        for (const name of names.split(" ")) {
          const field = record[name];
          if (field == null) continue;
          const valid =
            type === "date"
              ? typeof field === "string" &&
                /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/u.test(field) &&
                Number.isFinite(Date.parse(field))
              : type === "integer"
                ? Number.isInteger(field) && field >= -9223372036854775808 && field < 9223372036854775808
                : typeof field === type && (type !== "number" || Number.isFinite(field));
          if (!valid) fail(`invalid ${name}`);
        }
      return record;
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch {
      return fail("invalid JSON");
    }
    const root = object(decoded);
    validate(root, { string: "snapshot_at" });
    if (root.balance == null) return fail("Missing Neuralwatt balance object");
    const balance = validate(root.balance, {
      number: "credits_remaining_usd total_credits_usd credits_used_usd",
      string: "accounting_method",
    });
    const subscription = validate(root.subscription, {
      number: "kwh_included kwh_used kwh_remaining",
      string: "plan status billing_interval",
      boolean: "auto_renew in_overage",
      date: "current_period_start current_period_end",
    });
    const key = validate(root.key, { string: "name" });
    const allowance = validate(key.allowance, {
      number: "limit_usd spent_usd remaining_usd",
      string: "period",
      boolean: "blocked",
    });
    validate(root.limits, { number: "overage_limit_usd", string: "rate_limit_tier" });
    const usage = validate(root.usage, {});
    for (const period of [usage.lifetime, usage.current_month])
      validate(period, { number: "cost_usd energy_kwh", integer: "requests tokens" });
    const nonnegative = (value) => (Number.isFinite(value) && value >= 0 ? value : undefined);
    const positive = (value) => (value > 0 ? value : undefined);
    const total =
      positive(balance.total_credits_usd) ??
      positive((nonnegative(balance.credits_used_usd) ?? NaN) + (nonnegative(balance.credits_remaining_usd) ?? NaN));
    const used =
      nonnegative(balance.credits_used_usd) ??
      (positive(balance.total_credits_usd) !== undefined && nonnegative(balance.credits_remaining_usd) !== undefined
        ? Math.max(0, balance.total_credits_usd - balance.credits_remaining_usd)
        : undefined);
    const remaining =
      nonnegative(balance.credits_remaining_usd) ??
      (total !== undefined && used !== undefined ? Math.max(0, total - used) : undefined);
    if (
      nonnegative(balance.credits_remaining_usd) === undefined &&
      nonnegative(balance.credits_used_usd) === undefined &&
      positive(balance.total_credits_usd) === undefined
    )
      return fail("Missing Neuralwatt credit balance fields");
    const included =
      positive(subscription.kwh_included) ??
      positive((nonnegative(subscription.kwh_used) ?? NaN) + (nonnegative(subscription.kwh_remaining) ?? NaN));
    const consumed =
      nonnegative(subscription.kwh_used) ??
      (included !== undefined && nonnegative(subscription.kwh_remaining) !== undefined
        ? Math.max(0, included - subscription.kwh_remaining)
        : undefined);
    const title = (value) => value.toLowerCase().replace(/\b\w/gu, (letter) => letter.toUpperCase());
    const kwh = (value) => {
      if (Object.is(value, -0)) return "-0";
      if (Number.isInteger(value)) return value.toFixed(0);
      // printf uses half-even at exact binary ties; toFixed uses half-up.
      const cents = value * 100;
      if (Number.isInteger(value * 8) && cents % 1 === 0.5 && Math.floor(cents) % 2 === 0)
        return (Math.floor(cents) / 100).toFixed(2);
      return value.toFixed(2);
    };
    const end = subscription.current_period_end;
    const minutes = (Date.parse(end) - Date.parse(subscription.current_period_start)) / 60000;
    const primary =
      included !== undefined && consumed !== undefined
        ? {
            usedPercent: ctx.pct(consumed, included),
            resetsAt: end,
            windowMinutes: minutes > 0 ? Math.max(1, Math.trunc(minutes)) : undefined,
            resetDescription: `${kwh(consumed)} / ${kwh(included)} kWh`,
          }
        : undefined;
    const allowancePercent =
      allowance.blocked === true
        ? 100
        : allowance.spent_usd != null && allowance.limit_usd > 0
          ? ctx.pct(allowance.spent_usd, allowance.limit_usd)
          : undefined;
    const plan = subscription.plan?.trim();
    return {
      empty: true,
      primary,
      dataConfidence: "exact",
      cost:
        remaining === undefined
          ? undefined
          : { used: remaining, limit: 0, currency: "USD", period: "Neuralwatt prepaid balance" },
      identity: {
        loginMethod: plan
          ? `${title(plan.replace(/_/gu, " "))} plan`
          : balance.accounting_method
            ? title(balance.accounting_method)
            : undefined,
      },
      subscriptionRenewsAt: subscription.auto_renew === false ? undefined : primary?.resetsAt,
      extraWindows:
        allowancePercent === undefined
          ? undefined
          : [
              {
                id: "key-allowance",
                title: `Key ${title(allowance.period ?? "allowance")}`,
                usedPercent: allowancePercent,
              },
            ],
    };
  },
});
