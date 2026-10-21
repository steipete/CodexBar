function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
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
  id: "sailresearch",
  name: "Sail Research",
  endpoints: ["https://api.sailresearch.com"],
  auth: { type: "bearer", secret: "SAIL_API_KEY" },
  settings: [{ key: "SAIL_API_KEY", title: "Sail Research API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.sailresearch.com/v2/usage/summary?range=30d");
    const message = `Sail Research returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 402)
      throw ctx.fail.apiFailure("Sail Research disabled this API key because credits are exhausted.");
    if (response.status === 403) throw ctx.fail.permissionDenied("Sail Research API key has no organization access.");
    if (response.status === 429) {
      const delay = Number(_nullishCoalesce(response.headers["retry-after"], () => 1));
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("Sail Research returned an unrecognized billing summary.");
    }
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (
      _optionalChain([data, "optionalAccess", (_) => _.object]) !== "usage.summary" ||
      typeof data.available !== "boolean"
    )
      return fail();
    if (!data.available) throw ctx.fail.providerUnavailable("Sail Research billing data is unavailable.");
    if (typeof data.has_metronome_customer !== "boolean") return fail();
    if (!data.has_metronome_customer) throw ctx.fail.apiFailure("Sail Research organization has no billing account.");
    if (typeof data.balance_unavailable !== "boolean") return fail();
    function dollars(key) {
      const value = data[key];
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      return value / 100;
    }
    const spend = dollars("period_spend");
    if (spend < 0) return fail();
    const rangeLabels = {
      "1h": "Last hour spend",
      "6h": "Last 6 hours spend",
      "24h": "Last 24 hours spend",
      "7d": "Last 7 days spend",
      "30d": "Last 30 days spend",
      period: "Billing-period spend",
    };
    const rangeLabel = typeof data.effective_range === "string" ? rangeLabels[data.effective_range] : null;
    if (typeof rangeLabel !== "string") return fail();
    const rows = [
      { label: "Credit balance", value: data.balance_unavailable ? "Unavailable" : ctx.format.usd(dollars("balance")) },
      { label: rangeLabel, value: ctx.format.usd(spend) },
    ];
    return {
      details: [{ title: "Organization billing", rows }],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
