function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
defineProvider({
  id: "sofya",
  name: "Sofya",
  endpoints: ["https://sofya.co"],
  auth: { type: "bearer", secret: "SOFYA_API_KEY" },
  settings: [{ key: "SOFYA_API_KEY", title: "Sofya API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://sofya.co/v1/auth/me");
    const message = `Sofya returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    if (response.status === 429) {
      const delay = Number(_nullishCoalesce(response.headers["retry-after"], () => 1));
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("Sofya returned an unrecognized account credit response.");
    }
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) return fail();
    const rows = [];
    for (const [key, label] of [
      ["credits", "Available credits"],
      ["plan_credits", "Plan credits"],
      ["purchased_credits", "Purchased credits"],
    ]) {
      const value = data[key];
      if (value === null || value === undefined) continue;
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return fail();
      rows.push({ label, value: ctx.format.number(value, { maximumFractionDigits: 6 }) });
    }
    if (!rows.length) return fail();
    const eligible = data.is_free_tier;
    if (eligible !== undefined && eligible !== null && typeof eligible !== "boolean") return fail();
    const reset = data.credits_reset_at;
    if (reset !== undefined && reset !== null) {
      if (
        typeof reset !== "string" ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(reset)
      )
        return fail();
      const date = new Date(reset);
      const [year, month, day] = reset.slice(0, 10).split("-").map(Number);
      if (!Number.isFinite(date.getTime()) || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return fail();
      if (eligible === true) {
        rows.push({
          label: "Monthly reset",
          value: date
            .toISOString()
            .replace("T", " ")
            .replace(/(?:\.000)?Z$/, " UTC"),
        });
      }
    }
    return {
      details: [{ title: "Account credits", rows }],
      identity: { loginMethod: eligible === true ? "Free tier" : eligible === false ? "Pay as you go" : "API" },
      dataConfidence: "exact",
    };
  },
});
