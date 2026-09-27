defineProvider({
  id: "anyrouter",
  name: "AnyRouter",
  endpoints: ["https://anyrouter.dev"],
  auth: { type: "bearer", secret: "ANYROUTER_API_KEY" },
  settings: [{ key: "ANYROUTER_API_KEY", title: "AnyRouter API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://anyrouter.dev/api/v1/credits");
    const message = `AnyRouter returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(`AnyRouter API key was rejected (HTTP 401).`);
    if (response.status === 403) {
      // A key created in the dashboard ships with an endpoint allow-list that omits
      // /api/v1/credits, so this is a scope problem rather than a rejected credential.
      throw ctx.fail.permissionDenied(
        `AnyRouter key cannot read credits (HTTP 403). Enable Management permissions for this key in the AnyRouter dashboard.`,
      );
    }
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail(): never {
      throw ctx.fail.parseFailure("AnyRouter returned an unrecognized credit payload.");
    }
    let data: unknown;
    try {
      data = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return fail();
    const payload = data as Record<string, unknown>;
    // Every documented amount is a USD credit, and one credit is one US dollar, so a
    // different currency means the payload is not what this provider understands.
    if (payload.currency !== "usd") return fail();
    function amount(value: unknown, allowNegative = false): number {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      if (!allowNegative && value < 0) return fail();
      return value;
    }
    // `balance` is the remaining total and can dip fractionally below zero when a request
    // settles between the balance and spend reads; the accumulations below never can.
    const balance = amount(payload.balance, true),
      monthlyBalance = amount(payload.monthly_balance),
      topupBalance = amount(payload.topup_balance),
      used = amount(payload.used),
      todayCost = amount(payload.today_cost);
    return {
      details: [
        {
          title: "Credits",
          rows: [
            { label: "Available balance", value: ctx.format.usd(balance), usageValue: balance },
            { label: "Plan credits", value: ctx.format.usd(monthlyBalance), usageValue: monthlyBalance },
            { label: "Top-up credits", value: ctx.format.usd(topupBalance), usageValue: topupBalance },
            { label: "Lifetime spend", value: ctx.format.usd(used), usageValue: used },
            { label: "Spent today (UTC)", value: ctx.format.usd(todayCost), usageValue: todayCost },
          ],
        },
      ],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
