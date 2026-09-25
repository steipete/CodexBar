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
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = (): never => {
      throw ctx.fail.parseFailure("xKiro returned an unrecognized free-token usage response.");
    };
    const record = (value: unknown): Record<string, unknown> | undefined =>
      value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
    let decoded: unknown;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const root = record(decoded);
    const free = record(root?.free_tokens);
    if (root?.object !== "usage" || !free) return fail();
    const counter = (value: unknown): number | undefined => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const used = counter(free.used_today);
    const limit = counter(free.limit_per_day);
    const remaining = counter(free.remaining);
    if (used === undefined && limit === undefined && remaining === undefined && free.limit_per_day !== null) {
      return fail();
    }
    const rows: CodexBarDetailRow[] = [];
    if (used !== undefined) rows.push({ label: "Tokens used today", value: ctx.format.number(used) });
    if (limit !== undefined) rows.push({ label: "Daily allowance", value: ctx.format.number(limit) });
    else if (free.limit_per_day === null) rows.push({ label: "Daily allowance", value: "No cap reported" });
    if (remaining !== undefined) rows.push({ label: "Tokens remaining", value: ctx.format.number(remaining) });
    rows.push({ label: "Daily reset", value: "00:00 UTC" });
    const text = (value: unknown): string | undefined =>
      typeof value === "string" ? value.trim() || undefined : undefined;
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
        email: text(record(root.user)?.email),
        loginMethod: root.plan === null ? "Pay as you go" : text(root.plan),
      },
      dataConfidence: "exact",
    };
  },
});
