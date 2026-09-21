defineProvider({
  id: "litellm",
  name: "LiteLLM",
  endpoints: [{ setting: "LITELLM_BASE_URL", policy: "https-or-private-network-http" }],
  auth: { type: "bearer", secret: "LITELLM_API_KEY" },
  settings: [
    { key: "LITELLM_API_KEY", title: "API key", type: "secure" },
    { key: "LITELLM_BASE_URL", title: "Base URL", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const fail = (message: string): never => {
      throw ctx.fail.parseFailure(`LiteLLM parse error: ${message}`);
    };
    const object = (value: unknown): Record<string, unknown> => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail("expected an object");
      return value as Record<string, unknown>;
    };
    const text = (value: unknown): string | undefined => {
      if (value == null) return undefined;
      if (typeof value !== "string") return fail("invalid string");
      return value;
    };
    const number = (value: unknown): number | undefined => {
      if (value == null) return undefined;
      if (typeof value !== "number" || !Number.isFinite(value)) return fail("invalid number");
      return value;
    };
    const date = (value: unknown): Date | undefined => {
      const string = text(value);
      if (!string) return undefined;
      try {
        return ctx.date.iso(string);
      } catch (error) {
        void error;
        return undefined;
      }
    };
    const nonempty = (value: unknown) => text(value)?.trim() || undefined;
    const rawBase = ctx.settings.get("LITELLM_BASE_URL") || "";
    const [basePath, suffix = ""] = rawBase.split(/(?=[?#])/u, 2);
    let base = basePath.replace(/\/+$/u, "");
    if (decodeURIComponent(base).endsWith("/v1")) base = base.slice(0, base.lastIndexOf("/"));
    const request = async (path: string, query?: string) => {
      let response;
      try {
        response = await ctx.http.get(`${base}/${path}${query ?? suffix}`);
      } catch (error) {
        throw ctx.fail.networkFailure(`LiteLLM network error: ${String(error)}`);
      }
      if (response.status < 200 || response.status >= 300) {
        const message = `LiteLLM API error: HTTP ${response.status}: ${response.bodyText.slice(0, 500).trim()}`;
        if (response.status === 401) throw ctx.fail.authenticationExpired(message);
        if (response.status === 403) throw ctx.fail.permissionDenied(message);
        if (response.status === 429) throw ctx.fail.rateLimited(message);
        if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
        throw ctx.fail.apiFailure(message);
      }
      let decoded;
      try {
        decoded = JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
      return object(decoded);
    };
    const key = object((await request("key/info")).info);
    const userID = nonempty(key.user_id),
      teamID = nonempty(key.team_id);
    text(key.key_name);
    number(key.spend);
    const expires = date(key.expires);
    if (!userID && !teamID) return fail("LiteLLM key info did not include a user_id or team_id.");
    const budget = (value: unknown, requireID = false) => {
      const info = object(value);
      const id = text(info.team_id);
      if (requireID && id === undefined) return fail("missing team_id");
      text(info.budget_duration);
      return {
        id,
        alias: text(info.team_alias),
        spend: number(info.spend) ?? 0,
        limit: number(info.max_budget),
        reset: date(info.budget_reset_at),
      };
    };
    let personalSpend = 0,
      personalBudget: number | undefined,
      personalReset: Date | undefined;
    let email: string | undefined, team: ReturnType<typeof budget> | undefined;
    if (userID) {
      const root = await request("user/info", `?user_id=${encodeURIComponent(userID)}`);
      const user = object(root.user_info);
      const rootID = text(root.user_id),
        responseID = text(user.user_id) ?? rootID;
      if (responseID !== undefined && responseID !== userID) return fail("user_id did not match /key/info");
      const userEmail = nonempty(user.user_email),
        alias = nonempty(user.user_alias);
      const metadata = user.metadata == null ? {} : object(user.metadata);
      const preferred =
        typeof metadata.preferred_username === "string" ? nonempty(metadata.preferred_username) : undefined;
      email = userEmail ?? alias ?? preferred;
      personalSpend = number(user.spend) ?? 0;
      personalBudget = number(user.max_budget);
      personalReset = date(user.budget_reset_at);
      if (root.teams != null && !Array.isArray(root.teams)) return fail("invalid teams");
      const teams = ((root.teams ?? []) as unknown[]).map((value) => budget(value, true));
      team = teamID ? teams.find((value) => value.id === teamID) : undefined;
    } else {
      const root = await request("team/info", `?team_id=${encodeURIComponent(teamID!)}`);
      const rootID = nonempty(root.team_id);
      team = budget(root.team_info);
      const responseID = team.id?.trim() || rootID;
      if (responseID !== undefined && responseID !== teamID) return fail("team_id did not match /key/info");
    }
    const window = (spend: number, limit: number | undefined, reset: Date | undefined, label?: string) =>
      limit !== undefined && limit > 0
        ? {
            usedPercent: Math.min(100, Math.max(0, (spend / limit) * 100)),
            resetsAt: reset,
            resetDescription: `${label === undefined ? "" : `${label}: `}${ctx.format.usd(spend)} / ${ctx.format.usd(limit)}`,
          }
        : null;
    const spend = userID ? personalSpend : team!.spend;
    const limit = userID ? personalBudget : team!.limit;
    const reset = userID ? personalReset : team!.reset;
    return {
      primary: window(personalSpend, personalBudget, personalReset),
      secondary: team
        ? window(team.spend, team.limit, team.reset, team.alias === undefined ? "Team" : `Team ${team.alias}`)
        : null,
      cost:
        spend > 0 || (limit ?? 0) > 0
          ? {
              used: spend,
              limit: Math.max(0, limit ?? 0),
              currency: "USD",
              period: `${userID ? "Personal" : "Team"} ${(limit ?? 0) > 0 ? "budget" : "spend"}`,
              resetsAt: reset,
            }
          : null,
      subscriptionExpiresAt: expires,
      identity: { email, organization: team?.alias, loginMethod: "api" },
    };
  },
});
