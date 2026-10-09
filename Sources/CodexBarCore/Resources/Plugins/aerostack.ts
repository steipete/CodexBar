defineProvider({
  id: "aerostack",
  name: "Aerostack",
  endpoints: ["https://api.aerostack.dev"],
  auth: { type: "bearer", secret: "AEROSTACK_TOKEN" },
  settings: [{ key: "AEROSTACK_TOKEN", title: "Account JWT", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.aerostack.dev/api/billing/usage");
    const message = `Aerostack returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired("Aerostack account JWT expired or was rejected.");
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = (): never => {
      throw ctx.fail.parseFailure("Aerostack returned an unrecognized account AI-token usage response.");
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
    const tokens = record(record(root?.usage)?.ai_tokens);
    if (!tokens) return fail();
    const counter = (value: unknown): number | undefined => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const used = counter(tokens.used);
    const limit = counter(tokens.limit);
    if (used === undefined && limit === undefined) return fail();
    const rows: CodexBarDetailRow[] = [];
    if (used !== undefined) rows.push({ label: "Tokens used", value: ctx.format.number(used) });
    if (limit !== undefined) rows.push({ label: "Allowance", value: ctx.format.number(limit) });
    if (used !== undefined && limit !== undefined) {
      rows.push({ label: "Remaining", value: ctx.format.number(Math.max(0, limit - used)) });
      if (used > limit) rows.push({ label: "Above allowance", value: ctx.format.number(used - limit) });
    }
    if (root?.period !== undefined && root.period !== null) {
      if (typeof root.period !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(root.period)) return fail();
      rows.push({ label: "Period", value: root.period });
    }
    const tier = root?.tier;
    if (tier !== undefined && tier !== null && (typeof tier !== "string" || tier.length > 120)) return fail();
    return {
      primary:
        used !== undefined && limit !== undefined && limit > 0 ? { usedPercent: ctx.pct(used, limit) } : undefined,
      details: [{ title: "Monthly AI tokens", rows }],
      identity: { loginMethod: typeof tier === "string" ? tier.trim() || undefined : undefined },
      dataConfidence: "exact",
    };
  },
});
