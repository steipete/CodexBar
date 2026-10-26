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
  id: "abliteration",
  name: "abliteration.ai",
  endpoints: ["https://api.abliteration.ai"],
  auth: { type: "bearer", secret: "ABLITERATION_API_KEY" },
  settings: [
    { key: "ABLITERATION_API_KEY", title: "API key", type: "secure" },
    { key: "MESSAGES", title: "abliteration.ai", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const response = await ctx.http.get("https://api.abliteration.ai/v1/credits");
    if (response.status === 401 || response.status === 403)
      throw ctx.fail.authenticationExpired(message("Check your API key in Settings."));
    if (response.status === 429)
      throw ctx.fail.rateLimited(message("abliteration.ai is rate limiting requests. Try again later."));
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(message("abliteration.ai request failed. Try refreshing later."));
    if (response.status !== 200)
      throw ctx.fail.apiFailure(message("abliteration.ai request failed. Try refreshing later."));
    const fail = () => {
      throw ctx.fail.parseFailure(
        message("abliteration.ai returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const data = record(_optionalChain([record, "call", (_) => _(decoded), "optionalAccess", (_2) => _2.data]));
    const money = (value) => (typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : fail());
    const total = money(_optionalChain([data, "optionalAccess", (_3) => _3.total_credits]));
    const used = money(_optionalChain([data, "optionalAccess", (_4) => _4.total_usage]));
    return {
      primary:
        total > 0
          ? {
              usedPercent: ctx.pct(used, total),
              resetDescription: `${ctx.format.usd(used)} / ${ctx.format.usd(total)}`,
            }
          : undefined,
      details: [
        {
          title: "Credits",
          rows: [
            { label: "Balance", value: ctx.format.usd(Math.max(0, total - used)) },
            { label: "Credits used", value: ctx.format.usd(used) },
            { label: "Credits", value: ctx.format.usd(total) },
          ],
        },
      ],
      dataConfidence: "exact",
    };
  },
});
