defineProvider({
  id: "clawrouter",
  name: "ClawRouter",
  endpoints: ["https://clawrouter.openclaw.ai"],
  auth: { type: "bearer", secret: "CLAWROUTER_API_KEY" },
  settings: [{
    key: "CLAWROUTER_API_KEY",
    title: "API key",
    subtitle: "ClawRouter policy key used for the usage ledger.",
    type: "secure",
  }],

  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://clawrouter.openclaw.ai/v1/usage");
    if (response.status === 401 || response.status === 403) {
      throw new Error("ClawRouter rejected the API key");
    }
    if (response.status < 200 || response.status >= 300) {
      throw new Error(`ClawRouter API error: HTTP ${response.status}`);
    }
    const payload = response.json;
    if (!payload || typeof payload !== "object" || Array.isArray(payload) ||
        !payload.budget || !payload.usage || !payload.usage.summary || !Array.isArray(payload.usage.providers)) {
      throw new Error("Failed to parse ClawRouter usage response");
    }

    function integer(value, field) {
      if (!Number.isInteger(value)) throw new Error(`ClawRouter ${field} must be an integer`);
      return value;
    }
    function micros(value, field, optional) {
      if (optional && (value === null || value === undefined)) return null;
      return integer(value, field) / 1000000;
    }
    function monthlyReset(windowKey) {
      if (typeof windowKey !== "string") return null;
      const match = windowKey.match(/(\d{4})-(\d{2})$/);
      if (!match) return null;
      let year = Number(match[1]);
      let month = Number(match[2]) + 1;
      if (month === 13) { year += 1; month = 1; }
      return ctx.date.iso(`${year}-${String(month).padStart(2, "0")}-01T00:00:00Z`);
    }

    const budget = payload.budget;
    if (typeof budget.configured !== "boolean" || typeof budget.ledger !== "string") {
      throw new Error("Failed to parse ClawRouter budget");
    }
    const limit = micros(budget.limitMicros, "budget.limitMicros", true);
    const spent = micros(budget.spentMicros, "budget.spentMicros", true);
    const remaining = micros(budget.remainingMicros, "budget.remainingMicros", true);
    const resetsAt = monthlyReset(budget.windowKey);
    const summary = payload.usage.summary;
    const requestCount = integer(summary.requestCount, "summary.requestCount");
    const successCount = integer(summary.successCount, "summary.successCount");
    const errorCount = integer(summary.errorCount, "summary.errorCount");
    const inputTokens = integer(summary.inputTokens, "summary.inputTokens");
    const outputTokens = integer(summary.outputTokens, "summary.outputTokens");
    const totalTokens = integer(summary.totalTokens, "summary.totalTokens");
    const actualCost = micros(summary.actualCostMicros, "summary.actualCostMicros", false);

    const providers = payload.usage.providers.map(item => {
      if (!item || typeof item.provider !== "string") throw new Error("ClawRouter provider name must be a string");
      return {
        provider: item.provider.trim() || "Unknown",
        requests: integer(item.requestCount, "provider.requestCount"),
        success: integer(item.successCount, "provider.successCount"),
        errors: integer(item.errorCount, "provider.errorCount"),
        tokens: integer(item.totalTokens, "provider.totalTokens"),
        cost: micros(item.actualCostMicros, "provider.actualCostMicros", false),
      };
    }).sort((a, b) => b.cost - a.cost || b.requests - a.requests || a.provider.localeCompare(b.provider));

    const result = {
      identity: {
        organization: `${providers.length} routed providers`,
        loginMethod: budget.configured ? "Managed monthly budget" : "Unmetered",
      },
      details: [{
        title: "Usage",
        rows: [
          { label: "Requests", value: String(requestCount), secondaryValue: `${successCount} succeeded · ${errorCount} failed` },
          { label: "Tokens", value: String(totalTokens), secondaryValue: `${inputTokens} input · ${outputTokens} output` },
          { label: "Actual cost", value: `$${actualCost.toFixed(6)}` },
          { label: "Budget ledger", value: budget.ledger },
        ],
      }],
    };

    if (spent !== null && limit !== null) {
      result.primary = { usedPercent: ctx.pct(spent, limit) };
      if (resetsAt) result.primary.resetsAt = resetsAt;
      result.cost = { used: spent, limit, currency: "USD", period: "This month" };
      if (resetsAt) result.cost.resetsAt = resetsAt;
      result.details[0].rows.push({
        label: "Monthly budget",
        value: `$${spent.toFixed(6)} / $${limit.toFixed(2)}`,
        secondaryValue: remaining === null ? undefined : `$${remaining.toFixed(6)} remaining`,
      });
    } else if (actualCost > 0) {
      result.cost = { used: actualCost, currency: "USD", period: "This month" };
      if (resetsAt) result.cost.resetsAt = resetsAt;
    }

    if (providers.length) {
      let visible = providers;
      if (providers.length > 119) {
        const kept = providers.slice(0, 119);
        const other = providers.slice(119).reduce((sum, item) => sum + item.cost, 0);
        visible = kept.concat([{ provider: "Other", cost: other }]);
      }
      result.details.push({
        title: "Routed providers",
        rows: providers.slice(0, 20).map(item => ({
          label: item.provider,
          value: `${item.requests} requests`,
          secondaryValue: `$${item.cost.toFixed(6)} · ${item.tokens} tokens`,
        })),
        chart: {
          kind: "bars",
          title: "Provider cost",
          unit: "USD",
          points: visible.map(item => ({ label: item.provider, value: item.cost })),
        },
      });
    }
    return result;
  },
});
