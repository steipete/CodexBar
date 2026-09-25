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
  id: "litellm",
  name: "LiteLLM",
  endpoints: [{ setting: "LITELLM_BASE_URL", policy: "https-or-private-network-http" }],
  auth: { type: "bearer", secret: "LITELLM_API_KEY" },
  settings: [
    { key: "LITELLM_API_KEY", title: "API key", type: "secure" },
    { key: "LITELLM_BASE_URL", title: "Base URL", type: "plain" },
    { key: "LITELLM_MODEL_USAGE_ENABLED", title: "Show model activity", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const fail = (message) => {
      throw ctx.fail.parseFailure(`LiteLLM parse error: ${message}`);
    };
    const object = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail("expected an object");
      return value;
    };
    const scalar = (value, valid) => {
      if (value == null) return undefined;
      if (!valid) return fail("invalid scalar");
      return value;
    };
    const text = (value) => scalar(value, typeof value === "string");
    const number = (value) => scalar(value, typeof value === "number" && Number.isFinite(value));
    const date = (value) => {
      const string = text(value);
      try {
        return string ? ctx.date.iso(string) : undefined;
      } catch (error) {
        void error;
        return undefined;
      }
    };
    const nonempty = (value) =>
      _optionalChain([text, "call", (_) => _(value), "optionalAccess", (_2) => _2.trim, "call", (_3) => _3()]) ||
      undefined;
    const [basePath, suffix = ""] = (ctx.settings.get("LITELLM_BASE_URL") || "").split(/(?=[?#])/u, 2);
    let base = basePath.replace(/\/+$/u, "");
    if (decodeURIComponent(base).endsWith("/v1")) base = base.slice(0, base.lastIndexOf("/"));
    const request = async (path, query = suffix, allowUnavailable = false) => {
      const response = await ctx.http.get(`${base}/${path}${query}`).catch((error) => {
        throw ctx.fail.networkFailure(`LiteLLM network error: ${String(error)}`);
      });
      if (response.status < 200 || response.status >= 300) {
        if (allowUnavailable && [401, 403, 404].includes(response.status)) return undefined;
        const detail = path.endsWith("/report") ? "" : `: ${response.bodyText.slice(0, 500).trim()}`;
        const message = `LiteLLM API error: HTTP ${response.status}${detail}`;
        if (response.status === 401) throw ctx.fail.authenticationExpired(message);
        if (response.status === 403) throw ctx.fail.permissionDenied(message);
        if (response.status === 429) throw ctx.fail.rateLimited(message);
        if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
        throw ctx.fail.apiFailure(message);
      }
      try {
        return JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
    };
    const keyRoot = await request("key/info", suffix, true);
    if (keyRoot === undefined) {
      const end = ctx.date.now().toISOString().slice(0, 10),
        start = `${end.slice(0, 7)}-01`;
      const query = `?start_date=${start}&end_date=${end}`;
      let scope = "Key",
        rows = await request("key/spend/report", query, true);
      if (rows === undefined) {
        scope = "User";
        rows = await request("user/spend/report", query);
      }
      if (!Array.isArray(rows) || !rows.length) return fail("empty or invalid spend report");
      let used = 0;
      for (const row of rows) {
        const cost = number(object(row).total_cost);
        if (cost === undefined || cost < 0) return fail("invalid total_cost");
        used += cost;
      }
      number(used);
      return { cost: { used, currency: "USD", period: `${scope} spend only (${start}–${end} UTC)` } };
    }
    const key = object(object(keyRoot).info);
    const userID = nonempty(key.user_id),
      teamID = nonempty(key.team_id);
    text(key.key_name);
    number(key.spend);
    const expires = date(key.expires);
    if (!userID && !teamID) return fail("LiteLLM key info did not include a user_id or team_id.");
    const budget = (value, scope, requireID = false) => {
      const info = object(value);
      const id = scope === "Team" ? text(info.team_id) : undefined;
      if (requireID && id === undefined) return fail("missing team_id");
      if (scope === "Team") text(info.budget_duration);
      const alias = scope === "Team" ? text(info.team_alias) : undefined;
      const used = _nullishCoalesce(number(info.spend), () => 0),
        limit = Math.max(
          0,
          _nullishCoalesce(number(info.max_budget), () => 0),
        );
      const resetsAt = date(info.budget_reset_at);
      const label = scope === "Personal" ? "" : `Team${alias === undefined ? "" : ` ${alias}`}: `;
      return {
        id,
        alias,
        window:
          limit > 0
            ? {
                usedPercent: Math.min(100, Math.max(0, (used / limit) * 100)),
                resetsAt,
                resetDescription: `${label}${ctx.format.usd(used)} / ${ctx.format.usd(limit)}`,
              }
            : null,
        cost:
          used > 0 || limit > 0
            ? { used, limit, currency: "USD", period: `${scope} ${limit > 0 ? "budget" : "spend"}`, resetsAt }
            : null,
      };
    };
    let email, personal, team;
    if (userID) {
      const root = object(await request("user/info", `?user_id=${encodeURIComponent(userID)}`));
      const user = object(root.user_info);
      const rootID = text(root.user_id),
        responseID = _nullishCoalesce(text(user.user_id), () => rootID);
      if (responseID !== undefined && responseID !== userID) return fail("user_id did not match /key/info");
      const userEmail = nonempty(user.user_email),
        alias = nonempty(user.user_alias);
      const metadata = user.metadata == null ? {} : object(user.metadata);
      const preferred =
        typeof metadata.preferred_username === "string" ? nonempty(metadata.preferred_username) : undefined;
      email = userEmail || alias || preferred;
      personal = budget(user, "Personal");
      if (root.teams != null && !Array.isArray(root.teams)) return fail("invalid teams");
      const teams = _nullishCoalesce(root.teams, () => []).map((value) => budget(value, "Team", true));
      team = teamID ? teams.find((value) => value.id === teamID) : undefined;
    } else {
      const root = object(await request("team/info", `?team_id=${encodeURIComponent(teamID)}`));
      const rootID = nonempty(root.team_id);
      team = budget(root.team_info, "Team");
      const responseID = nonempty(team.id) || rootID;
      if (responseID !== undefined && responseID !== teamID) return fail("team_id did not match /key/info");
    }
    const modelActivity = async () => {
      const end = ctx.date.now().toISOString().slice(0, 10);
      const start = new Date(ctx.date.now().getTime() - 29 * 86400000).toISOString().slice(0, 10);
      const totals = new Map();
      const fields = ["prompt_tokens", "completion_tokens", "total_tokens", "api_requests"];
      const count = (value) => {
        const parsed = number(value);
        if (parsed === undefined || !Number.isSafeInteger(parsed) || parsed < 0) return fail("invalid activity count");
        return parsed;
      };
      for (let page = 1; page <= 3; page++) {
        const response = await ctx.http.get(
          `${base}/user/daily/activity?user_id=${encodeURIComponent(userID)}&start_date=${start}&end_date=${end}&page=${page}&page_size=1000`,
          { timeoutSeconds: 2 },
        );
        if (response.status !== 200) return fail("model activity unavailable");
        const root = object(JSON.parse(response.bodyText));
        if (!Array.isArray(root.results) || root.results.length > 31) return fail("invalid activity page");
        for (const raw of root.results) {
          const row = object(raw),
            day = text(row.date);
          if (!day || !/^\d{4}-\d{2}-\d{2}$/u.test(day) || day < start || day > end) {
            return fail("invalid activity day");
          }
          const models = object(object(row.breakdown).models);
          for (const [name, value] of Object.entries(models)) {
            if (!ctx.isDetailLabel(name)) return fail("invalid activity model name");
            const entry = object(value),
              metrics = object(_nullishCoalesce(entry.metrics, () => entry));
            const previous = _nullishCoalesce(totals.get(name), () => [0, 0, 0, 0]);
            totals.set(
              name,
              fields.map((field, index) => count(previous[index] + count(metrics[field]))),
            );
            if (totals.size > 1000) return fail("too many activity models");
          }
        }
        const metadata = object(_nullishCoalesce(root.metadata, () => ({})));
        if (metadata.page != null && count(metadata.page) !== page) return fail("repeated activity page");
        const pages = metadata.total_pages == null ? 1 : count(metadata.total_pages);
        if (metadata.has_more != null && typeof metadata.has_more !== "boolean") return fail("invalid pagination");
        if (metadata.has_more !== true && page >= pages) {
          const rows = [...totals]
            .sort((a, b) => b[1][2] - a[1][2] || a[0].localeCompare(b[0]))
            .slice(0, 20)
            .map(([label, [input, output, total, requests]]) => ({
              label,
              value: `${total} tokens · ${requests} requests`,
              secondaryValue: `Input ${input} · Output ${output}`,
            }));
          return rows.length ? [{ title: "Model activity · 30d UTC", rows }] : [];
        }
      }
      return fail("incomplete model activity");
    };
    // Optional history must never discard successfully fetched budgets or expose response bodies.
    const details =
      userID && ctx.settings.get("LITELLM_MODEL_USAGE_ENABLED") === "true" ? await modelActivity().catch(() => []) : [];
    return {
      primary: _optionalChain([personal, "optionalAccess", (_4) => _4.window]),
      secondary: _optionalChain([team, "optionalAccess", (_5) => _5.window]),
      cost: _nullishCoalesce(personal, () => team).cost,
      details,
      subscriptionExpiresAt: expires,
      identity: { email, organization: _optionalChain([team, "optionalAccess", (_6) => _6.alias]), loginMethod: "api" },
    };
  },
});
