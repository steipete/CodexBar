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
  id: "ollama",
  name: "Ollama",
  endpoints: ["https://ollama.com"],
  auth: { type: "bearer", secret: "OLLAMA_API_KEY" },
  settings: [{ key: "OLLAMA_API_KEY", title: "Ollama API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://ollama.com/api/balance");
    const message = `Ollama returned HTTP ${response.status}.`;
    if (response.status === 401 || response.status === 403)
      throw ctx.fail.authenticationExpired("Ollama API key is invalid or expired.");
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("Ollama returned an unrecognized credit balance response.");
    }
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return fail();
    function amount(value) {
      if (typeof value === "string" && /^-?\d+(?:\.\d+)?$/.test(value.trim())) value = Number(value);
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      return value;
    }
    const rows = [];
    if (data.purchased != null) {
      rows.push({ label: "Credit balance", value: ctx.format.usd(amount(data.purchased.balance_usd)) });
    }
    let primary;
    if (data.included != null) {
      const allowance = amount(data.included.allowance_usd);
      const balance = amount(data.included.balance_usd);
      if (allowance < 0) return fail();
      const used = Math.max(0, allowance - balance);
      if (!Number.isFinite(used)) return fail();
      rows.push({ label: "Monthly credits used", value: ctx.format.usd(used) });
      let resetsAt;
      const period = data.included.period;
      if (period != null && (typeof period !== "object" || Array.isArray(period))) return fail();
      const until = _optionalChain([period, "optionalAccess", (_) => _.until]);
      if (until != null) {
        if (
          typeof until !== "string" ||
          !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(until)
        )
          return fail();
        const date = new Date(until);
        const [year, month, day] = until.slice(0, 10).split("-").map(Number);
        if (!Number.isFinite(date.getTime()) || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return fail();
        resetsAt = date.toISOString();
      }
      // Match the cookie path's monthly classification and calendar-based pace.
      if (allowance > 0)
        primary = { usedPercent: Math.min(100, (used / allowance) * 100), windowMinutes: 43200, resetsAt };
    }
    if (!rows.length) return fail();
    return {
      primary,
      details: [{ title: "Credits", rows }],
      identity: { loginMethod: "API key" },
    };
  },
});
