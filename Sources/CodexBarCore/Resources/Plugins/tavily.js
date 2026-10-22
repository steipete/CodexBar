defineProvider({
  id: "tavily",
  name: "Tavily",
  endpoints: ["https://api.tavily.com"],
  auth: { type: "bearer", secret: "TAVILY_API_KEY" },
  settings: [{ key: "TAVILY_API_KEY", title: "Tavily API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.tavily.com/usage");
    const message = `Tavily returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    // The usage endpoint allows only ten requests per ten minutes; do not replay a throttled request.
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("Tavily returned an unrecognized credit usage response.");
    };
    const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
    const count = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : fail());
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (!record(data) || !record(data.account) || !record(data.key)) return fail();
    const { account, key } = data;
    const format = (value) => `${ctx.format.number(count(value))} credits`;
    const rows = (usage, cap, unlimited = false) =>
      [
        { label: "Used", value: format(usage) },
        { label: "Limit", value: cap === null ? (unlimited ? "Unlimited" : null) : format(cap) },
        { label: "Remaining", value: cap === null ? null : format(Math.max(0, cap - usage)) },
      ].filter((row) => row.value !== null);
    const details = [
      { title: "Account plan", rows: rows(account.plan_usage, count(account.plan_limit)) },
      { title: "API key", rows: rows(key.usage, key.limit, true) },
    ];
    if (account.paygo_usage !== undefined || account.paygo_limit !== undefined) {
      details.push({ title: "Pay as you go", rows: rows(account.paygo_usage, account.paygo_limit) });
    }
    const plan = account.current_plan;
    if (plan !== undefined && (typeof plan !== "string" || !plan.trim() || plan.length > 120)) return fail();
    return {
      primary: account.plan_limit > 0 ? { usedPercent: ctx.pct(account.plan_usage, account.plan_limit) } : undefined,
      secondary: key.limit > 0 ? { usedPercent: ctx.pct(key.usage, key.limit) } : undefined,
      details,
      identity: { loginMethod: plan === undefined ? "API key" : plan.trim() },
      dataConfidence: "exact",
    };
  },
});
