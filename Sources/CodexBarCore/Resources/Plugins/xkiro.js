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
  id: "xkiro",
  name: "xKiro",
  endpoints: ["https://api.xkiro.com"],
  auth: { type: "bearer", secret: "XKIRO_API_KEY" },
  settings: [{ key: "XKIRO_API_KEY", title: "xKiro API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.xkiro.com/v1/usage");
    const message = `xKiro returned HTTP ${response.status}.`;
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
      throw ctx.fail.parseFailure("xKiro returned an unrecognized free-token usage response.");
    };
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const root = record(decoded);
    const free = record(_optionalChain([root, "optionalAccess", (_) => _.free_tokens]));
    if (_optionalChain([root, "optionalAccess", (_2) => _2.object]) !== "usage" || !free) return fail();
    const counter = (value) => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const used = counter(free.used_today);
    const limit = counter(free.limit_per_day);
    const remaining = counter(free.remaining);
    if (used === undefined && limit === undefined && remaining === undefined && free.limit_per_day !== null) {
      return fail();
    }
    const rows = [];
    if (used !== undefined) rows.push({ label: "Tokens used today", value: ctx.format.number(used) });
    if (limit !== undefined) rows.push({ label: "Daily allowance", value: ctx.format.number(limit) });
    else if (free.limit_per_day === null) rows.push({ label: "Daily allowance", value: "No cap reported" });
    if (remaining !== undefined) rows.push({ label: "Tokens remaining", value: ctx.format.number(remaining) });
    rows.push({ label: "Daily reset", value: "00:00 UTC" });
    const text = (value) => (typeof value === "string" ? value.trim() || undefined : undefined);
    return {
      primary:
        used !== undefined && limit !== undefined
          ? {
              usedPercent: limit === 0 ? 100 : ctx.pct(used, limit),
              windowMinutes: 1440,
              resetsAt: ctx.date.nextDailyReset("UTC", 0),
            }
          : undefined,
      details: [{ title: "Free tokens", rows }],
      identity: {
        email: text(_optionalChain([record, "call", (_3) => _3(root.user), "optionalAccess", (_4) => _4.email])),
        loginMethod: root.plan === null ? "Pay as you go" : text(root.plan),
      },
      dataConfidence: "exact",
    };
  },
});
