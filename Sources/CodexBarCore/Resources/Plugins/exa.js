defineProvider({
  id: "exa",
  name: "Exa",
  endpoints: ["https://admin-api.exa.ai"],
  auth: { type: "x-api-key", secret: "EXA_SERVICE_KEY" },
  settings: [
    { key: "EXA_SERVICE_KEY", title: "Exa service key", type: "secure" },
    { key: "EXA_API_KEY_ID", title: "API key ID", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const id = ctx.settings.get("EXA_API_KEY_ID");
    if (!id || id === "." || id === "..") {
      throw ctx.fail.missingCredential(
        "Set the Exa API key ID in Scope or EXA_API_KEY_ID; this is not the service key.",
      );
    }
    const end = new Date(Math.floor(ctx.date.now().getTime() / 1000) * 1000);
    const start = new Date(Date.UTC(end.getUTCFullYear(), end.getUTCMonth(), 1));
    const url =
      `https://admin-api.exa.ai/team-management/api-keys/${encodeURIComponent(id)}/usage` +
      `?start_date=${encodeURIComponent(start.toISOString())}&end_date=${encodeURIComponent(end.toISOString())}`;
    const response = await ctx.http.get(url);
    const message = `Exa returned HTTP ${response.status}.`;
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired("Exa rejected the service key. Ordinary search API keys are not supported.");
    }
    if (response.status === 403) {
      throw ctx.fail.permissionDenied(
        "Exa Team Management must be enabled and both keys must belong to the same team.",
      );
    }
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("Exa returned an unrecognized API key usage response.");
    };
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (
      !data ||
      typeof data.total_cost_usd !== "number" ||
      !Number.isFinite(data.total_cost_usd) ||
      data.total_cost_usd < 0 ||
      !data.period ||
      typeof data.period.start !== "string" ||
      typeof data.period.end !== "string" ||
      Date.parse(data.period.start) !== start.getTime() ||
      Date.parse(data.period.end) !== end.getTime()
    )
      return fail();
    return {
      details: [
        {
          title: "API key this month (UTC)",
          rows: [{ label: "Spend", value: ctx.format.currency(data.total_cost_usd, "USD") }],
        },
      ],
      identity: { loginMethod: "Service key" },
      dataConfidence: "exact",
    };
  },
});
