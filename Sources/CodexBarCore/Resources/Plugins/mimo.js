defineProvider({
  id: "mimo",
  name: "Xiaomi MiMo",
  endpoints: ["https://token-plan-cn.xiaomimimo.com", "https://token-plan-sgp.xiaomimimo.com"],
  auth: { type: "bearer", secret: "MIMO_API_KEY" },
  settings: [
    { key: "MIMO_API_KEY", title: "API key", type: "secure" },
    { key: "REGION", title: "API region", type: "plain" },
    { key: "MESSAGES", title: "Xiaomi MiMo", type: "plain" },
  ],
  capabilities: ["http-status"],
  snapshotPolicy: { percent: "preserve-overage" },
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const invalid = () => {
      throw ctx.fail.parseFailure(message("MiMo returned an unrecognized response. Update CodexBar and try again."));
    };
    const region = ctx.settings.get("REGION") || "cn";
    if (region !== "cn" && region !== "sgp") return invalid();
    const response = await ctx.http.get(`https://token-plan-${region}.xiaomimimo.com/v1/platform/token_plan`);
    if (response.status === 401) throw ctx.fail.authenticationExpired(message("Check your API key in Settings."));
    if (response.status === 403) throw ctx.fail.permissionDenied(message("Check your API key in Settings."));
    if (response.status === 429)
      throw ctx.fail.rateLimited(message("MiMo is rate limiting requests. Try again later."));
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(message("MiMo request failed. Try refreshing later."));
    if (response.status !== 200) throw ctx.fail.apiFailure(message("MiMo request failed. Try refreshing later."));
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return invalid();
    }
    const object = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : invalid();
    const root = object(decoded);
    if (root.object !== "token_plan") return invalid();
    const quota = object(root.quota);
    const count = (value) =>
      typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : invalid();
    const total = count(quota.total_credits);
    const used = count(quota.used_credits);
    const remaining = count(quota.remaining_credits);
    if (remaining !== Math.max(0, total - used)) return invalid();
    const period = object(root.period);
    // Xiaomi documents these timezone-less timestamps as UTC, including regional endpoints.
    const date = (value) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value)) return invalid();
      const iso = value.replace(" ", "T") + "Z";
      const parsed = new Date(iso);
      if (!Number.isFinite(parsed.getTime()) || parsed.toISOString().replace(".000", "") !== iso) return invalid();
      return parsed;
    };
    const start = date(period.start_at),
      end = date(period.end_at);
    if (start && end && end <= start) return invalid();
    const minutes = start && end ? (end.getTime() - start.getTime()) / 60000 : undefined;
    return {
      empty: total === 0,
      primary:
        total > 0
          ? {
              usedPercent: (used / total) * 100,
              quotaLimit: total,
              quotaUnit: "credits",
              resetsAt: end,
              windowMinutes: minutes !== undefined && Number.isSafeInteger(minutes) ? minutes : undefined,
              resetDescription: `${ctx.format.number(used)} / ${ctx.format.number(total)} Credits`,
            }
          : undefined,
      identity: { loginMethod: typeof root.plan_code === "string" ? root.plan_code : undefined },
      dataConfidence: "exact",
    };
  },
});
