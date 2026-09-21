defineProvider({
  id: "llmproxy",
  name: "LLM Proxy",
  endpoints: [{ setting: "LLM_PROXY_BASE_URL", policy: "https-or-private-network-http" }],
  auth: { type: "bearer", secret: "LLM_PROXY_API_KEY" },
  settings: [
    { key: "LLM_PROXY_API_KEY", title: "API key", type: "secure" },
    { key: "LLM_PROXY_BASE_URL", title: "Base URL", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const [base, suffix = ""] = (ctx.settings.get("LLM_PROXY_BASE_URL") || "").split(/(?=[?#])/u, 2);
    const path = base.replace(/\/+$/u, "");
    const endpoint = `${path}${decodeURIComponent(path).endsWith("/v1") ? "" : "/v1"}/quota-stats${suffix}`;
    let response;
    try {
      response = await ctx.http.get(endpoint);
    } catch (error) {
      throw ctx.fail.networkFailure(`LLM Proxy network error: ${String(error)}`);
    }
    if (response.status < 200 || response.status >= 300) {
      const message = `LLM Proxy API error: HTTP ${response.status}: ${response.bodyText.slice(0, 500).trim()}`;
      if (response.status === 401) throw ctx.fail.authenticationExpired(message);
      if (response.status === 403) throw ctx.fail.permissionDenied(message);
      if (response.status === 429) throw ctx.fail.rateLimited(message);
      if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
      throw ctx.fail.apiFailure(message);
    }
    const fail = (field: string): never => {
      throw ctx.fail.parseFailure(`LLM Proxy parse error: ${field}`);
    };
    const object = (value: unknown): Record<string, unknown> => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail("expected an object");
      return value as Record<string, unknown>;
    };
    const number = (value: unknown, integer = false): number | undefined => {
      if (value == null) return undefined;
      if (typeof value !== "number" || !Number.isFinite(value) || (integer && !Number.isInteger(value))) {
        return fail("invalid number");
      }
      return value;
    };
    const text = (value: unknown): string | undefined => {
      if (value == null) return undefined;
      if (typeof value !== "string") return fail("invalid string");
      return value;
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("invalid JSON");
    }
    const root = object(decoded);
    const summary = root.summary == null ? {} : object(root.summary);
    const groups: Array<{ remaining?: number; reset?: string }> = [];
    let credentials = 0,
      active = 0;
    const providers = Object.entries(object(root.providers))
      .map(([name, value]) => {
        const stats = object(value);
        credentials += number(stats.credential_count, true) ?? 0;
        active += number(stats.active_count, true) ?? 0;
        number(stats.exhausted_count, true);
        const tokens = stats.tokens == null ? {} : object(stats.tokens);
        // Native decoding treats malformed quota_groups as absent, without discarding other usage.
        try {
          const values =
            stats.quota_groups == null
              ? []
              : Array.isArray(stats.quota_groups)
                ? stats.quota_groups
                : Object.values(object(stats.quota_groups));
          const parsed = values.map((value) => {
            const group = object(value);
            return { remaining: number(group.remaining_percent), reset: text(group.reset_time) };
          });
          for (const group of parsed) groups.push(group);
        } catch (error) {
          void error;
          /* Optional quota groups are best effort. */
        }
        return {
          name,
          requests: number(stats.total_requests, true) ?? 0,
          tokens:
            (number(tokens.input_cached, true) ?? 0) +
            (number(tokens.input_uncached, true) ?? 0) +
            (number(tokens.output, true) ?? 0),
          cost: number(stats.approx_cost),
        };
      })
      .sort((a, b) => b.requests - a.requests || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    const requests = number(summary.total_requests, true) ?? providers.reduce((sum, p) => sum + p.requests, 0);
    const tokens = number(summary.total_tokens, true) ?? providers.reduce((sum, p) => sum + p.tokens, 0);
    const sum = providers.reduce((sum, p) => sum + (p.cost ?? 0), 0);
    const cost = number(summary.approx_cost) ?? (sum > 0 ? sum : undefined);
    const remaining = groups.flatMap((g) => (g.remaining === undefined ? [] : [g.remaining]));
    const resets = groups
      .flatMap((g) => {
        if (!g.reset) return [];
        try {
          const date = ctx.date.iso(g.reset);
          return date > ctx.date.now() ? [date] : [];
        } catch (error) {
          void error;
          return [];
        }
      })
      .sort((a, b) => a.getTime() - b.getTime());
    const integer = (value: number) => ctx.format.number(value, { maximumFractionDigits: 0 });
    return {
      primary: remaining.length
        ? {
            usedPercent: Math.max(
              0,
              Math.min(100, 100 - remaining.reduce((minimum, value) => Math.min(minimum, value), Infinity)),
            ),
            resetsAt: resets[0],
          }
        : null,
      secondary: { usedPercent: 0, resetDescription: `${integer(requests)} requests` },
      tertiary: { usedPercent: 0, resetDescription: `${integer(tokens)} tokens` },
      extraWindows: providers.slice(0, 3).map((p) => ({
        id: p.name,
        title: p.name,
        usedPercent: 0,
        resetDescription: [
          `${integer(p.requests)} req`,
          `${integer(p.tokens)} tok`,
          ...(p.cost === undefined ? [] : [ctx.format.usd(p.cost)]),
        ].join(" · "),
      })),
      cost:
        cost === undefined
          ? null
          : { used: cost, limit: 0, currency: "USD", period: "Approx. spend", resetsAt: resets[0] },
      identity: { organization: `${active}/${credentials} active keys`, loginMethod: "quota-stats" },
    };
  },
});
