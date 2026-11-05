defineProvider({
  id: "tripo",
  name: "Tripo",
  endpoints: ["https://openapi.tripo3d.ai"],
  auth: { type: "bearer", secret: "TRIPO_API_KEY" },
  settings: [
    { key: "TRIPO_API_KEY", title: "API key", type: "secure" },
    { key: "MESSAGES", title: "Tripo", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const response = await ctx.http.get("https://openapi.tripo3d.ai/v3/account/balance");
    if (response.status === 401) throw ctx.fail.authenticationExpired(message("Check your API key in Settings."));
    if (response.status === 403) throw ctx.fail.permissionDenied(message("Check your API key in Settings."));
    if (response.status === 429)
      throw ctx.fail.rateLimited(message("Tripo is rate limiting requests. Try again later."));
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(message("Tripo request failed. Try refreshing later."));
    if (response.status !== 200) throw ctx.fail.apiFailure(message("Tripo request failed. Try refreshing later."));
    const fail = () => {
      throw ctx.fail.parseFailure(message("Tripo returned an unrecognized response. Update CodexBar and try again."));
    };
    let body;
    try {
      body = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (!body || typeof body !== "object" || Array.isArray(body) || !Number.isInteger(body.code)) return fail();
    if (body.code !== 0) throw ctx.fail.apiFailure(message("Tripo request failed. Try refreshing later."));
    if (!body.data || typeof body.data !== "object" || Array.isArray(body.data)) return fail();
    const credits = (value) =>
      typeof value === "number" && Number.isFinite(value) && value >= 0
        ? ctx.format.number(value, { maximumFractionDigits: 2 })
        : fail();
    return {
      details: [
        {
          title: "Credits",
          rows: [
            // The API balance is already available credits; frozen credits are a separate reservation.
            { label: "Balance", value: credits(body.data.balance) },
            { label: "Reserved", value: credits(body.data.frozen) },
          ],
        },
      ],
      dataConfidence: "exact",
    };
  },
});
