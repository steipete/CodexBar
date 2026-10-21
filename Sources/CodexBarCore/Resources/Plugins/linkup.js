defineProvider({
  id: "linkup",
  name: "Linkup",
  endpoints: ["https://api.linkup.so"],
  auth: { type: "bearer", secret: "LINKUP_API_KEY" },
  settings: [{ key: "LINKUP_API_KEY", title: "Linkup API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.linkup.so/v1/credits/balance");
    const message = `Linkup returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("Linkup returned an unrecognized credit balance.");
    }
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (!data || Array.isArray(data) || typeof data.balance !== "number" || !Number.isFinite(data.balance)) {
      return fail();
    }
    return {
      details: [{ title: "Account balance", rows: [{ label: "Credit balance", value: ctx.format.usd(data.balance) }] }],
      identity: { loginMethod: "API" },
      dataConfidence: "exact",
    };
  },
});
