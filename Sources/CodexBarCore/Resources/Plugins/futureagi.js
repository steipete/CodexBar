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
  id: "futureagi",
  name: "Future AGI",
  endpoints: ["https://api.futureagi.com"],
  auth: { type: "x-api-key", secret: "FI_API_KEY" },
  settings: [
    { key: "FI_API_KEY", title: "API key", type: "secure" },
    { key: "FI_SECRET_KEY", title: "Secret key", type: "secure" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const secret = ctx.settings.getSecret("FI_SECRET_KEY");
    if (!secret) throw ctx.fail.missingCredential("Future AGI requires both an API key and a secret key.");
    const response = await ctx.http.get("https://api.futureagi.com/usage/v2/usage-overview/", {
      headers: { "X-Secret-Key": secret },
    });
    const message = `Future AGI returned HTTP ${response.status}.`;
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
    const fail = () => {
      throw ctx.fail.parseFailure("Future AGI returned an unrecognized usage overview.");
    };
    let body;
    try {
      body = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const data = _optionalChain([body, "optionalAccess", (_) => _.result]);
    if (
      _optionalChain([body, "optionalAccess", (_2) => _2.status]) !== true ||
      !data ||
      !Array.isArray(data.dimensions)
    )
      return fail();
    const amount = (value) =>
      typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER
        ? value
        : fail();
    const date = (value) => {
      if (
        typeof value !== "string" ||
        !/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?$/.test(value)
      )
        return fail();
      const parsed = new Date(value);
      return Number.isFinite(parsed.getTime()) ? parsed : fail();
    };
    const start = date(data.billing_period_start);
    const end = date(data.billing_period_end);
    if (end <= start || data.dimensions.length === 0 || data.dimensions.length > 16) return fail();
    const windows = {};
    const rows = [];
    const keys = new Set();
    for (const meter of data.dimensions) {
      if (
        !meter ||
        typeof meter.key !== "string" ||
        keys.has(meter.key) ||
        !ctx.isDetailLabel(meter.display_name) ||
        !ctx.isDetailLabel(meter.display_unit)
      )
        return fail();
      keys.add(meter.key);
      const used = amount(meter.current_usage);
      const allowance = amount(meter.free_allowance);
      if (allowance > 0) {
        windows[meter.key] = {
          usedPercent: ctx.pct(used, allowance),
          windowMinutes: Math.round((end.getTime() - start.getTime()) / 60000),
          resetsAt: end,
          quotaLimit: allowance,
          quotaUnit: meter.display_unit,
        };
      }
      rows.push({
        label: meter.display_name,
        value: `${ctx.format.number(used)} / ${ctx.format.number(allowance)} ${meter.display_unit}`,
      });
    }
    return {
      primary: windows.ai_credits,
      secondary: windows.gateway_requests,
      details: [
        { title: "Used / free allowance", rows },
        {
          title: "Billing period",
          rows: [{ label: "Estimated usage cost", value: ctx.format.usd(amount(data.total_estimated_cost)) }],
        },
      ],
      identity: { loginMethod: typeof data.plan_display_name === "string" ? data.plan_display_name : undefined },
      dataConfidence: "exact",
    };
  },
});
