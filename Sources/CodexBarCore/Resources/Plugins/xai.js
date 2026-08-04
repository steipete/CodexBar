defineProvider({
  id: "xai",
  name: "xAI",
  endpoints: ["https://management-api.x.ai"],
  auth: { type: "bearer", secret: "XAI_MANAGEMENT_API_KEY" },
  settings: [
    { key: "XAI_MANAGEMENT_API_KEY", title: "Management API key", type: "secure" },
    { key: "XAI_TEAM_ID", title: "Team ID", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const team = ctx.settings.get("XAI_TEAM_ID");
    if (!team || team.includes("/") || team === "." || team === "..") throw new Error("Invalid xAI team ID");
    const root = `https://management-api.x.ai/v1/billing/teams/${encodeURIComponent(team)}`;
    const balanceResponse = await ctx.http.getJSON(`${root}/prepaid/balance`);
    if (balanceResponse.status < 200 || balanceResponse.status >= 300) throw new Error(`xAI balance API error: HTTP ${balanceResponse.status}`);
    const raw = balanceResponse.json && balanceResponse.json.total && balanceResponse.json.total.val;
    if (typeof raw !== "string" || !/^-?\d+(\.\d+)?$/.test(raw.trim())) throw new Error("xAI balance is invalid");
    const balance = -Number(raw) / 100;
    const now = new Date();
    const start = new Date(now);
    start.setUTCDate(start.getUTCDate() - 29);
    start.setUTCHours(0, 0, 0, 0);
    const timestamp = date => `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")} ${String(date.getUTCHours()).padStart(2, "0")}:${String(date.getUTCMinutes()).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")}`;
    let daily = [];
    let partial = false;
    try {
      const usage = await ctx.http.postJSON(`${root}/usage`, { body: { analyticsRequest: {
        timeRange: { startTime: timestamp(start), endTime: timestamp(now), timezone: "Etc/GMT" },
        timeUnit: "TIME_UNIT_DAY", values: [{ name: "usd", aggregation: "AGGREGATION_SUM" }],
        groupBy: [], filters: [],
      } } });
      if (usage.status === 401 || usage.status === 403) throw new Error(`xAI usage API error: HTTP ${usage.status}`);
      if (usage.status >= 200 && usage.status < 300) {
        const totals = {};
        for (const series of usage.json.timeSeries || []) for (const point of series.dataPoints || []) {
          const day = String(point.timestamp).slice(0, 10);
          totals[day] = (totals[day] || 0) + Number((point.values || [0])[0] || 0);
        }
        daily = Object.keys(totals).sort().map(day => ({ label: day, value: totals[day] }));
        partial = usage.json.limitReached === true;
      }
    } catch (error) {
      if (/HTTP 401|HTTP 403/.test(error.message)) throw error;
    }
    return {
      cost: { used: balance, currency: "USD", period: "Prepaid credits" },
      identity: { loginMethod: "Management API" },
      details: [{
        title: "Billing summary",
        rows: [
          { label: "Prepaid balance", value: `$${balance.toFixed(2)}` },
          { label: "History", value: partial ? "Last 30 days (partial)" : "Last 30 days" },
        ],
        chart: daily.length ? { kind: "bars", title: "Daily spend", unit: "USD", points: daily } : undefined,
      }],
    };
  },
});
