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
  id: "aixy",
  name: "Aixy",
  endpoints: [{ setting: "AIXY_BASE_URL", policy: "https-or-private-network-http" }],
  auth: { type: "bearer", secret: "AIXY_API_KEY" },
  settings: [
    { key: "AIXY_API_KEY", title: "API key", type: "secure" },
    { key: "AIXY_BASE_URL", title: "Base URL", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const fail = (message) => {
      throw ctx.fail.parseFailure(`Aixy: ${message}`);
    };
    const object = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail("expected an object");
      return value;
    };
    const text = (value) => {
      if (typeof value !== "string" || !value.trim()) return fail("invalid text");
      return value.trim();
    };
    const bounded = (value) => Array.from(value).slice(0, 120).join("");
    const number = (value) => {
      if (value == null) return undefined;
      if (typeof value === "string" && /^\d+(?:\.\d+)?$/u.test(value)) value = Number(value);
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return fail("invalid amount");
      return value;
    };
    const count = (value) => {
      const parsed = number(value);
      if (parsed === undefined || !Number.isSafeInteger(parsed)) return fail("invalid count");
      return parsed;
    };
    const date = (value) => {
      if (value == null) return undefined;
      let parsed;
      try {
        parsed = ctx.date.iso(text(value));
      } catch (error) {
        void error;
        return fail("invalid date");
      }
      if (!Number.isFinite(parsed.getTime())) return fail("invalid date");
      return parsed;
    };
    const base = (ctx.settings.get("AIXY_BASE_URL") || "https://api.aixy-gateway.com").replace(/\/+$/u, "");
    if (/[?#]/u.test(base)) throw ctx.fail.apiFailure("Aixy Base URL must not contain a query or fragment.");
    const endpoint = `${base.replace(/\/v1$/u, "")}/v1/usage`;
    const response = await ctx.http.get(endpoint);
    const message = `Aixy usage request failed (HTTP ${response.status}).`;
    if (response.status === 401)
      throw ctx.fail.authenticationExpired("Aixy rejected the API key. Check its expiry or revocation.");
    if (response.status === 403) throw ctx.fail.permissionDenied("Aixy denied access to this key's usage.");
    if (response.status === 404)
      throw ctx.fail.apiFailure(
        "This Aixy installation does not provide the usage endpoint. Update the gateway or check its Base URL.",
      );
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status < 200 || response.status >= 300) throw ctx.fail.apiFailure(message);
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("invalid usage JSON");
    }
    const root = object(decoded);
    if (root.object !== "key.usage" || root.currency !== "USD") return fail("unsupported usage contract");
    const asOf = date(root.as_of);
    if (!asOf) return fail("missing observation time");
    const key = object(root.key);
    const keyID = text(key.id);
    if (!Array.isArray(root.budgets)) return fail("invalid budgets");
    const labels = {
      organization: "Organization",
      project: "Project",
      team: "Team",
      user: "User",
      api_key: "Key",
      daily: "Daily",
      weekly: "Weekly",
      monthly: "Monthly",
      lifetime: "Lifetime",
    };
    if (root.budgets.length > 64) return fail("too many budgets");
    const ids = new Set();
    const budgets = root.budgets
      .map((raw) => {
        const budget = object(raw),
          id = text(budget.id);
        if (ids.has(id)) return fail("duplicate budget");
        ids.add(id);
        const scope = text(budget.scope),
          interval = text(budget.interval);
        if (
          !["organization", "project", "team", "user", "api_key"].includes(scope) ||
          !["daily", "weekly", "monthly", "lifetime"].includes(interval)
        )
          return fail("invalid budget scope or interval");
        if (budget.enforcement !== "hard" && budget.enforcement !== "monitor") return fail("invalid enforcement");
        if (typeof budget.shared !== "boolean") return fail("invalid shared scope");
        const limit = number(budget.limit_usd);
        if (limit === undefined || limit <= 0) return fail("invalid budget limit");
        if (
          !Array.isArray(budget.applies_to) ||
          !budget.applies_to.length ||
          budget.applies_to.some(
            (item) => object(item).api_key_id !== keyID || object(item).project_id !== key.project_id,
          )
        )
          return fail("budget belongs to another key");
        const availability = object(budget.availability);
        const hard = budget.enforcement === "hard";
        if (!["available", "unavailable", "not_enforced"].includes(text(availability.status)))
          return fail("invalid availability");
        if (!["available", "unavailable"].includes(text(budget.spend_status))) return fail("invalid spend status");
        const known = hard ? availability.status === "available" : budget.spend_status === "available";
        const spent = number(hard ? availability.spent_usd : budget.spend_usd);
        const reserved = hard ? number(availability.reserved_usd) : 0;
        const remaining = number(hard ? availability.remaining_usd : budget.remaining_usd);
        if (known && (spent === undefined || reserved === undefined || remaining === undefined))
          return fail("incomplete budget balance");
        const used = known ? spent + reserved : undefined;
        if (used !== undefined && !Number.isFinite(used)) return fail("budget amount overflow");
        const startsAt = date(budget.starts_at),
          resetsAt = date(budget.resets_at);
        if (startsAt && resetsAt && resetsAt <= startsAt) return fail("invalid budget period");
        const minutes = startsAt && resetsAt ? (resetsAt.getTime() - startsAt.getTime()) / 60000 : undefined;
        const title = bounded(
          `${labels[scope]} · ${labels[interval]} · ${budget.shared ? "Shared" : "Personal"} · ${hard ? "Hard" : "Monitor"}`,
        );
        return {
          id: `aixy-${id}`,
          title,
          known,
          hard,
          spent,
          reserved,
          remaining,
          limit,
          used,
          window: {
            usedPercent: known ? ctx.pct(used, limit) : 0,
            windowMinutes: minutes !== undefined && Number.isSafeInteger(minutes) && minutes > 0 ? minutes : undefined,
            resetsAt,
            resetDescription: `${title} · ${known ? `${ctx.format.usd(remaining)} remaining` : "Unavailable"}`,
          },
        };
      })
      .sort(
        (a, b) =>
          Number(b.hard) - Number(a.hard) ||
          Number(b.known) - Number(a.known) ||
          b.window.usedPercent - a.window.usedPercent ||
          (a.id < b.id ? -1 : a.id > b.id ? 1 : 0),
      );
    const known = budgets.filter((budget) => budget.known);
    const selected = known.slice(0, 2);
    const details = [
      {
        title: "Aixy key",
        rows: [
          { label: "Key", value: bounded(key.name == null ? keyID : text(key.name)) },
          {
            label: "Project",
            value: bounded(key.project_name == null ? text(key.project_id) : text(key.project_name)),
          },
          { label: "Observed", value: asOf.toISOString() },
        ],
      },
    ];
    for (let offset = 0; offset < budgets.length; offset += 24)
      details.push({
        title: "Applicable budgets",
        rows: budgets.slice(offset, offset + 24).map((budget) => ({
          label: budget.title,
          value: budget.known
            ? `${ctx.format.usd(budget.remaining)} / ${ctx.format.usd(budget.limit)} remaining`
            : "Unavailable",
          secondaryValue: budget.known
            ? `${ctx.format.usd(budget.spent)} spent${budget.hard ? ` · ${ctx.format.usd(budget.reserved)} reserved` : ""}`
            : undefined,
          progress: budget.known ? budget.window.usedPercent / 100 : undefined,
          usageValue: budget.used,
        })),
      });
    let cost;
    let confidence = "unknown";
    if (root.usage != null) {
      const usage = object(root.usage);
      if (usage.window !== "7d") return fail("unsupported reporting period");
      const requests = count(usage.requests),
        tokens = count(usage.total_tokens);
      const attributed = count(usage.attributed_requests),
        partial = count(usage.partial_requests);
      const spend = number(usage.spend_usd);
      if (attributed > requests || partial > attributed || (spend !== undefined && spend > 0 && attributed === 0))
        return fail("invalid attribution coverage");
      if (spend !== undefined) {
        cost = { used: spend, currency: "USD", period: "Last 7 days · attributed" };
        confidence = "estimated";
      }
      details.push({
        title: "Last 7 days · this key",
        rows: [
          { label: "Requests", value: ctx.format.number(requests) },
          { label: "Tokens", value: ctx.format.number(tokens) },
          { label: "Attributed spend", value: spend === undefined ? "Unavailable" : ctx.format.usd(spend) },
          {
            label: "Cost coverage",
            value: `${attributed} / ${requests} requests`,
            secondaryValue: `${partial} partial`,
          },
        ],
      });
    } else {
      details.push({ title: "Last 7 days · this key", rows: [{ label: "Usage", value: "Unavailable" }] });
    }
    return {
      primary: _optionalChain([selected, "access", (_) => _[0], "optionalAccess", (_2) => _2.window]),
      secondary: _optionalChain([selected, "access", (_3) => _3[1], "optionalAccess", (_4) => _4.window]),
      extraWindows: budgets
        .filter((budget) => !selected.includes(budget))
        .map((budget) => ({
          id: budget.id,
          title: budget.title,
          usageKnown: budget.known,
          window: budget.window,
        })),
      cost,
      details,
      dataConfidence: confidence,
      identity: { accountID: keyID, loginMethod: "API key" },
    };
  },
});
