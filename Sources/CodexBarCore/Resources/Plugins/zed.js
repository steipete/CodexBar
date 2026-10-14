defineProvider({
  id: "zed",
  name: "Zed",
  endpoints: ["https://cloud.zed.dev", { setting: "API_URL", policy: "https" }],
  settings: [
    { key: "SOURCE", title: "Usage source", type: "plain" },
    { key: "API_URL", title: "Editor API URL", type: "plain" },
    { key: "EDITOR_AUTH", title: "Editor credential", type: "secure" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["zed.dev"],
  async fetchUsage(ctx) {
    const web = ctx.settings.get("SOURCE") === "web";
    const url = web ? "https://cloud.zed.dev/frontend/billing/usage" : ctx.settings.get("API_URL");
    const headers = { Accept: "application/json" };
    if (web) {
      if (ctx.browser.availability("zed.dev") === "off") {
        throw ctx.fail.missingCredential("Enable Zed browser cookies or paste a Cookie header to read token spend.");
      }
      headers.Cookie = await ctx.browser.cookieHeader("zed.dev");
    } else {
      headers.Authorization = ctx.settings.getSecret("EDITOR_AUTH");
      if (!url || !headers.Authorization)
        throw ctx.fail.missingCredential("Sign in from the Zed editor app with GitHub.");
    }
    const response = await ctx.http.get(url, { headers });
    if (response.status === 401 || response.status === 403) {
      if (web) ctx.browser.rejectCookie("zed.dev");
      throw ctx.fail.authenticationExpired(
        web
          ? "Zed browser session expired. Sign in to zed.dev in a supported browser or update the Cookie header."
          : "Zed credentials are invalid or expired. Sign in to Zed again.",
      );
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Zed usage requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Zed cloud API returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Zed cloud API returned HTTP ${response.status}.`);
    const fail = () => {
      throw ctx.fail.parseFailure("Could not parse Zed usage response. Its format may have changed.");
    };
    const object = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail();
      return value;
    };
    const count = (value) => {
      if (!Number.isSafeInteger(value) || value < 0) return fail();
      return value;
    };
    const cents = (value) => {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER)
        return fail();
      return value / 100;
    };
    const text = (value) => {
      if (typeof value !== "string" || !value.trim()) return fail();
      return value;
    };
    let root;
    try {
      root = object(JSON.parse(response.bodyText));
    } catch {
      return fail();
    }
    const plan = web ? text(root.plan) : text(object(root.plan).plan_v3);
    const usage = object(web ? root.current_usage : root.plan.usage);
    const predictions = object(usage.edit_predictions);
    const used = count(predictions.used);
    const rawLimit = predictions.limit;
    const unlimited = rawLimit === "unlimited" || (web && rawLimit === null);
    const limit = unlimited ? null : count(typeof rawLimit === "object" ? object(rawLimit).limited : rawLimit);
    const snapshot = {
      identity: {
        loginMethod: plan
          .replace(/_/g, " ")
          .split(" ")
          .filter(Boolean)
          .map((word) => word[0].toUpperCase() + word.slice(1).toLowerCase())
          .join(" "),
      },
      dataConfidence: "exact",
      primary: unlimited
        ? { usedPercent: 0, resetDescription: "Unlimited" }
        : limit > 0
          ? {
              usedPercent: ctx.pct(used, limit),
              resetDescription: `${Math.min(used, limit)} / ${limit} predictions`,
            }
          : null,
    };
    if (web) {
      const spend = object(usage.token_spend);
      const spent = cents(spend.spend_in_cents);
      const cap = spend.limit_in_cents == null ? null : cents(spend.limit_in_cents);
      if (cap !== null) {
        snapshot.cost = { used: spent, limit: cap, currency: "USD", period: "Current billing period" };
      }
      const rows = [
        { label: "Spent", value: ctx.format.usd(spent), usageValue: spent },
        { label: "Spend limit", value: cap === null ? "Not reported" : ctx.format.usd(cap) },
      ];
      if (cap !== null) rows.push({ label: "Remaining budget", value: ctx.format.usd(Math.max(0, cap - spent)) });
      snapshot.details = [{ title: "Token spend", rows }];
      return snapshot;
    }
    const user = object(root.user);
    count(user.id);
    if (typeof user.github_login !== "string") return fail();
    if (user.github_login.trim()) snapshot.identity.email = user.github_login;
    if (user.name != null) {
      if (typeof user.name !== "string") return fail();
      if (user.name.trim()) snapshot.identity.organization = user.name;
    }
    if (typeof root.plan.has_overdue_invoices !== "boolean") return fail();
    if (root.plan.has_overdue_invoices) {
      snapshot.extraWindows = [
        {
          id: "zed.overdue-invoices",
          title: "Billing",
          usageKnown: false,
          window: { usedPercent: 100, resetDescription: "Overdue invoices" },
        },
      ];
    }
    if (root.plan.subscription_period != null) {
      const period = object(root.plan.subscription_period);
      const start = ctx.date.iso(text(period.started_at));
      const end = ctx.date.iso(text(period.ended_at));
      const now = ctx.date.now();
      const remaining = (end - now) / 1000;
      const hours = Math.floor(remaining / 3600);
      const minutes = Math.floor((remaining % 3600) / 60);
      const resetDescription =
        remaining <= 0
          ? "Cycle ended"
          : hours >= 24
            ? `Cycle ends in ${Math.floor(hours / 24)}d ${hours % 24}h`
            : hours > 0
              ? `Cycle ends in ${hours}h ${minutes}m`
              : `Cycle ends in ${minutes}m`;
      snapshot.secondary = {
        usedPercent: end > start ? ctx.pct(now - start, end - start) : 0,
        resetsAt: end,
        resetDescription,
      };
      snapshot.subscriptionRenewsAt = end;
    }
    return snapshot;
  },
});
