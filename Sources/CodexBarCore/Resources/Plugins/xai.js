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
    if (!team || team.includes("/") || team === "." || team === "..") {
      throw ctx.fail.missingCredential("Missing or invalid xAI team ID");
    }
    const root = `https://management-api.x.ai/v1/billing/teams/${encodeURIComponent(team)}`;
    const balanceResponse = await ctx.http.getJSON(`${root}/prepaid/balance`);
    if (balanceResponse.status === 401 || balanceResponse.status === 403) {
      throw ctx.fail.authenticationExpired(
        "xAI rejected the Management API key. Create one in the xAI Console under Settings > Management Keys; inference API keys are not accepted.",
      );
    }
    if (balanceResponse.status === 404) {
      throw ctx.fail.apiFailure(
        "xAI returned 404 for this team. Check the team ID, and that the Management key belongs to the same team.",
      );
    }
    if (balanceResponse.status === 429) {
      throw ctx.fail.rateLimited("xAI Management API rate limit exceeded. Usage will refresh on the next cycle.");
    }
    if (balanceResponse.status < 200 || balanceResponse.status >= 300) {
      throw ctx.fail.apiFailure(`xAI Management API returned HTTP ${balanceResponse.status}.`);
    }
    const raw = balanceResponse.json && balanceResponse.json.total && balanceResponse.json.total.val;
    if (typeof raw !== "string" || !/^-?\d+(\.\d+)?$/.test(raw.trim())) {
      throw ctx.fail.parseFailure("Could not parse xAI billing data: balance total.val is not a cent amount");
    }
    const balance = -Number(raw) / 100;
    const now = ctx.date.now();
    const start = new Date(now);
    start.setUTCDate(start.getUTCDate() - 29);
    start.setUTCHours(0, 0, 0, 0);
    const timestamp = (date) =>
      `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")} ${String(date.getUTCHours()).padStart(2, "0")}:${String(date.getUTCMinutes()).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")}`;
    let daily = [];
    let partial = false;
    let historyAvailable = false;
    try {
      const usage = await ctx.http.postJSON(`${root}/usage`, {
        body: {
          analyticsRequest: {
            timeRange: { startTime: timestamp(start), endTime: timestamp(now), timezone: "Etc/GMT" },
            timeUnit: "TIME_UNIT_DAY",
            values: [{ name: "usd", aggregation: "AGGREGATION_SUM" }],
            groupBy: [],
            filters: [],
          },
        },
      });
      if (usage.status === 401 || usage.status === 403) {
        throw ctx.fail.authenticationExpired(
          "xAI rejected the Management API key. Create one in the xAI Console under Settings > Management Keys; inference API keys are not accepted.",
        );
      }
      if (usage.status >= 200 && usage.status < 300) {
        if (!usage.json || !Array.isArray(usage.json.timeSeries)) {
          throw new Error("invalid xAI usage history");
        }
        const totals = {};
        for (const series of usage.json.timeSeries) {
          if (!series || !Array.isArray(series.dataPoints)) {
            throw new Error("invalid xAI usage history");
          }
          for (const point of series.dataPoints) {
            const date = new Date(point.timestamp);
            const value = Array.isArray(point.values) ? point.values[0] : undefined;
            if (!Number.isFinite(date.getTime()) || typeof value !== "number" || !Number.isFinite(value) || value < 0) {
              throw new Error("invalid xAI usage history");
            }
            const day = date.toISOString().slice(0, 10);
            totals[day] = (totals[day] || 0) + value;
          }
        }
        daily = Object.keys(totals)
          .sort()
          .map((day) => ({ label: day, value: totals[day] }));
        partial = usage.json.limitReached === true;
        historyAvailable = true;
      }
    } catch (error) {
      if (/rejected the Management API key/.test(error.message)) throw error;
    }
    return {
      cost: { used: balance, currency: "USD", period: "Prepaid credits" },
      identity: { loginMethod: "Management API" },
      dataConfidence: partial ? "estimated" : "exact",
      details: [
        {
          title: "Billing summary",
          rows: [
            { label: "Prepaid balance", value: `$${balance.toFixed(2)}` },
            {
              label: partial ? "Last 30 days (partial)" : "Last 30 days",
              value: `$${daily.reduce((sum, point) => sum + point.value, 0).toFixed(2)}`,
            },
          ],
          // Emit an empty chart on successful history so spend mapping can tell
          // "zero days" from "analytics unavailable".
          chart: historyAvailable ? { kind: "bars", title: "Daily spend", unit: "USD", points: daily } : undefined,
        },
      ],
    };
  },
});
