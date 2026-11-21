function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "trustedrouter",
  name: "TrustedRouter",
  endpoints: ["https://api.trustedrouter.com"],
  auth: { type: "bearer", secret: "TRUSTEDROUTER_API_KEY" },
  settings: [
    { key: "TRUSTEDROUTER_API_KEY", title: "API key", type: "secure" },
    { key: "MESSAGES", title: "TrustedRouter", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const response = await ctx.http.get("https://api.trustedrouter.com/v1/key");
    if (response.status === 401) throw ctx.fail.authenticationExpired(message("Check your API key in Settings."));
    if (response.status === 403) throw ctx.fail.permissionDenied(message("Check your API key in Settings."));
    if (response.status === 429)
      throw ctx.fail.rateLimited(message("TrustedRouter is rate limiting requests. Try again later."));
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(message("TrustedRouter request failed. Try refreshing later."));
    if (response.status !== 200)
      throw ctx.fail.apiFailure(message("TrustedRouter request failed. Try refreshing later."));
    const fail = () => {
      throw ctx.fail.parseFailure(
        message("TrustedRouter returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const data = record(_optionalChain([record, "call", (_) => _(decoded), "optionalAccess", (_2) => _2.data]));
    if (!data) return fail();
    // Money fields are integer microdollars (1 USD = 1,000,000); the float dollar fields are display copies.
    const dollars = (value) =>
      typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value / 1000000 : fail();
    const optionalDollars = (value) => (value === null ? undefined : dollars(value));
    const usage = dollars(data.usage_microdollars);
    const daily = dollars(data.usage_daily_microdollars);
    const weekly = dollars(data.usage_weekly_microdollars);
    const monthly = dollars(data.usage_monthly_microdollars);
    const limit = optionalDollars(data.limit_microdollars);
    const remaining = optionalDollars(data.limit_remaining_microdollars);
    if ((limit === undefined) !== (remaining === undefined)) return fail();
    const keyLimit = limit !== undefined && remaining !== undefined ? { limit, remaining } : undefined;
    // The remaining amount already excludes in-flight reservations, so it is not recomputed from usage.
    const spent = keyLimit ? Math.max(0, keyLimit.limit - keyLimit.remaining) : 0;
    return {
      primary:
        keyLimit && keyLimit.limit > 0
          ? {
              usedPercent: ctx.pct(spent, keyLimit.limit),
              resetDescription: `${ctx.format.usd(spent)} / ${ctx.format.usd(keyLimit.limit)}`,
            }
          : undefined,
      details: [
        {
          title: "Usage",
          rows: [
            ...(keyLimit
              ? [
                  { label: "Remaining", value: ctx.format.usd(keyLimit.remaining) },
                  { label: "Limit", value: ctx.format.usd(keyLimit.limit) },
                ]
              : []),
            { label: "Today", value: ctx.format.usd(daily) },
            { label: "This week", value: ctx.format.usd(weekly) },
            { label: "This month", value: ctx.format.usd(monthly) },
            { label: "Total usage", value: ctx.format.usd(usage) },
          ],
        },
      ],
      dataConfidence: "exact",
    };
  },
});
