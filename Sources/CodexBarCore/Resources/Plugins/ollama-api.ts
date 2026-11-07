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
    function fail(): never {
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
    function amount(value: unknown): number {
      if (typeof value === "string" && /^-?\d+(?:\.\d+)?$/.test(value.trim())) value = Number(value);
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      return value;
    }
    function resetDate(value: unknown): string | undefined {
      if (value == null) return;
      if (
        typeof value !== "string" ||
        !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
      )
        return fail();
      const date = new Date(value);
      const [year, month, day] = value.slice(0, 10).split("-").map(Number);
      if (!Number.isFinite(date.getTime()) || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return fail();
      return date.toISOString();
    }
    function legacyWindow(value: unknown, windowMinutes: number): CodexBarRateWindow | undefined {
      if (value == null) return;
      if (typeof value !== "object" || Array.isArray(value)) return fail();
      const entry = value as Record<string, unknown>;
      const remaining = amount(entry.remaining_percent);
      if (remaining < 0 || remaining > 100) return fail();
      return { usedPercent: 100 - remaining, windowMinutes, resetsAt: resetDate(entry.resets_at) };
    }
    const rows: CodexBarDetailRow[] = [];
    if (data.purchased != null) {
      rows.push({ label: "Credit balance", value: ctx.format.usd(amount(data.purchased.balance_usd)) });
    }
    const included = data.included;
    let primary: CodexBarRateWindow | undefined;
    let secondary: CodexBarRateWindow | undefined;
    if (included?.session != null || included?.weekly != null) {
      primary = legacyWindow(included.session, 300);
      secondary = legacyWindow(included.weekly, 10080);
    } else if (included != null) {
      const allowance = amount(included.allowance_usd);
      const balance = amount(included.balance_usd);
      if (allowance < 0) return fail();
      const used = Math.max(0, allowance - balance);
      if (!Number.isFinite(used)) return fail();
      rows.push({ label: "Monthly credits used", value: ctx.format.usd(used) });
      const period = included.period;
      if (period != null && (typeof period !== "object" || Array.isArray(period))) return fail();
      const resetsAt = resetDate(period?.until);
      // Match the cookie path's monthly classification and calendar-based pace.
      if (allowance > 0)
        primary = { usedPercent: Math.min(100, (used / allowance) * 100), windowMinutes: 43200, resetsAt };
    }
    if (!rows.length && !primary && !secondary) return fail();
    return {
      primary,
      secondary,
      details: rows.length ? [{ title: "Credits", rows }] : undefined,
      identity: { loginMethod: "API key" },
    };
  },
});
