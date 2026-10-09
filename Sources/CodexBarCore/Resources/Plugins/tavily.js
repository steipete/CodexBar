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
    const account = data.account;
    const used = count(account.plan_usage);
    const limit = count(account.plan_limit);
    const keyUsed = count(data.key.usage);
    const keyLimit = data.key.limit === null ? null : count(data.key.limit);
    const format = (value) => `${ctx.format.number(value)} credits`;
    const rows = (usage, cap) => [
      { label: "Used", value: format(usage) },
      { label: "Limit", value: cap === null ? "Unlimited" : format(cap) },
      ...(cap === null ? [] : [{ label: "Remaining", value: format(Math.max(0, cap - usage)) }]),
    ];
    const details = [
      { title: "Account plan", rows: rows(used, limit) },
      { title: "API key", rows: rows(keyUsed, keyLimit) },
    ];
    if (account.paygo_usage !== undefined || account.paygo_limit !== undefined) {
      details.push({ title: "Pay as you go", rows: rows(count(account.paygo_usage), count(account.paygo_limit)) });
    }
    const plan = account.current_plan;
    if (plan !== undefined && (typeof plan !== "string" || !plan.trim() || plan.length > 120)) return fail();
    return {
      primary: limit > 0 ? { usedPercent: ctx.pct(used, limit) } : undefined,
      secondary: keyLimit > 0 ? { usedPercent: ctx.pct(keyUsed, keyLimit) } : undefined,
      details,
      identity: { loginMethod: plan === undefined ? "API key" : plan.trim() },
      dataConfidence: "exact",
    };
  },
});
