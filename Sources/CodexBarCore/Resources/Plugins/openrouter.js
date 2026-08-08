defineProvider({
  id: "openrouter",
  name: "OpenRouter",
  endpoints: ["https://openrouter.ai", { setting: "OPENROUTER_API_URL", policy: "https" }],
  auth: { type: "bearer", secret: "OPENROUTER_API_KEY" },
  settings: [
    {
      key: "OPENROUTER_API_KEY",
      title: "API key",
      subtitle: "OpenRouter API key used for credits and key quota.",
      type: "secure",
    },
    { key: "OPENROUTER_API_URL", title: "API URL", type: "plain" },
    { key: "OPENROUTER_HTTP_REFERER", title: "HTTP referer", type: "plain" },
    { key: "OPENROUTER_X_TITLE", title: "Client title", type: "plain" },
  ],

  async fetchUsage(ctx) {
    function finite(value, field, optional) {
      if (optional && (value === null || value === undefined)) return null;
      if (typeof value !== "number" || !Number.isFinite(value)) {
        throw ctx.fail.parseFailure(`Failed to parse OpenRouter response: ${field} must be a finite number`);
      }
      return value;
    }

    const base = (ctx.settings.get("OPENROUTER_API_URL") || "https://openrouter.ai/api/v1").replace(/\/+$/, "");
    const headers = { "X-Title": ctx.settings.get("OPENROUTER_X_TITLE") || "CodexBar" };
    const referer = ctx.settings.get("OPENROUTER_HTTP_REFERER");
    if (referer) headers["HTTP-Referer"] = referer;
    const creditsResponse = await ctx.http.get(`${base}/credits`, { headers });
    if (creditsResponse.status !== 200) {
      throw ctx.fail.apiFailure(`OpenRouter API error: HTTP ${creditsResponse.status}`);
    }
    let creditsPayload;
    try {
      creditsPayload = JSON.parse(creditsResponse.bodyText);
    } catch (_) {
      throw ctx.fail.parseFailure("Failed to parse OpenRouter response: response was not valid JSON");
    }
    const credits = creditsPayload && creditsPayload.data;
    if (!credits || typeof credits !== "object" || Array.isArray(credits)) {
      throw ctx.fail.parseFailure("Failed to parse OpenRouter credits: data must be an object");
    }

    const totalCredits = finite(credits.total_credits, "total_credits", false);
    const totalUsage = finite(credits.total_usage, "total_usage", false);
    const balance = Math.max(0, totalCredits - totalUsage);
    let keyData = null;
    try {
      const keyResponse = await ctx.http.get(`${base}/key`, { timeoutSeconds: 1 });
      const keyPayload = keyResponse.status === 200 ? JSON.parse(keyResponse.bodyText) : null;
      if (keyPayload && keyPayload.data && typeof keyPayload.data === "object" &&
          !Array.isArray(keyPayload.data)) {
        const candidate = keyPayload.data;
        for (const field of [
          "limit", "limit_remaining", "usage", "usage_daily", "usage_weekly", "usage_monthly",
        ]) finite(candidate[field], `key.${field}`, true);
        if (candidate.limit_reset !== null && candidate.limit_reset !== undefined &&
            typeof candidate.limit_reset !== "string") throw new TypeError("key.limit_reset must be a string");
        if (candidate.rate_limit !== null && candidate.rate_limit !== undefined &&
            (!candidate.rate_limit || typeof candidate.rate_limit !== "object" ||
             !Number.isInteger(candidate.rate_limit.requests) ||
             typeof candidate.rate_limit.interval !== "string")) {
          throw new TypeError("key.rate_limit is invalid");
        }
        keyData = candidate;
      }
    } catch (_) {}

    // /activity is management-key-only and optional. Credits and key quota remain valid
    // when analytics is forbidden, unsupported by an endpoint override, slow, or malformed.
    let openRouterActivityUsage = null;
    try {
      const activityResponse = await ctx.http.get(`${base}/activity`, { timeoutSeconds: 1 });
      if (activityResponse.status === 200) {
        const activityPayload = JSON.parse(activityResponse.bodyText);
        if (activityPayload && Array.isArray(activityPayload.data)) {
          openRouterActivityUsage = {
            data: activityPayload.data.map(item => ({
              date: item.date,
              model: item.model,
              prompt_tokens: item.prompt_tokens,
              completion_tokens: item.completion_tokens,
              reasoning_tokens: item.reasoning_tokens,
              requests: item.requests,
              usage: item.usage,
            })),
          };
        }
      }
    } catch (_) {}

    function resetWindowUsage(reset) {
      const windowKey =
        reset === "daily" ? "usage_daily" :
        reset === "weekly" ? "usage_weekly" :
        reset === "monthly" ? "usage_monthly" : null;
      if (!windowKey) return null;
      return finite(keyData[windowKey], `key.${windowKey}`, true);
    }

    // Match the Swift quota path: prefer the server-reported remaining amount, then the
    // usage field matching the declared reset window, and finally cumulative usage.
    function keyUsedForQuota() {
      const limitRemaining = finite(keyData.limit_remaining, "key.limit_remaining", true);
      if (limitRemaining !== null) {
        // Clamp to [0, keyLimit] like Swift so remaining above the configured
        // limit renders 0% used instead of suppressing the meter.
        return keyLimit - Math.min(keyLimit, Math.max(0, limitRemaining));
      }
      const windowUsage = resetWindowUsage(keyData.limit_reset);
      if (windowUsage !== null) return windowUsage;
      return keyUsage;
    }

    let primary;
    let keyLimit = null;
    let keyUsage = null;
    let keyRemaining = null;
    if (keyData) {
      keyLimit = finite(keyData.limit, "key.limit", true);
      keyUsage = finite(keyData.usage, "key.usage", true);
      const used = keyUsedForQuota();
      if (keyLimit !== null && keyLimit > 0 && used !== null && Number.isFinite(used) && used >= 0) {
        primary = { usedPercent: ctx.pct(used, keyLimit) };
        keyRemaining = Math.max(0, keyLimit - used);
      }
    }

    const currency = value => `$${Math.max(0, value).toFixed(2)}`;
    const details = [{
      title: "Credits",
      rows: [
        { label: "Remaining", value: currency(balance) },
        { label: "Used", value: currency(totalUsage) },
        { label: "Total added", value: currency(totalCredits) },
      ],
    }];

    if (keyData) {
      const rows = [];
      if (keyLimit !== null && keyLimit > 0) {
        rows.push({ label: "API key budget", value: currency(keyLimit) });
        if (keyRemaining !== null) rows.push({ label: "API key remaining", value: currency(keyRemaining) });
        if (keyUsage !== null) rows.push({ label: "API key used", value: currency(keyUsage) });
      } else {
        rows.push({ label: "API key budget", value: "No limit configured" });
      }
      const resetWindow = typeof keyData.limit_reset === "string" ? keyData.limit_reset.trim() : "";
      if (resetWindow) rows.push({ label: "Reset window", value: resetWindow });
      const periods = [
        ["Today", "usage_daily"],
        ["This week", "usage_weekly"],
        ["This month", "usage_monthly"],
      ];
      const points = [];
      for (const [label, key] of periods) {
        const value = finite(keyData[key], `key.${key}`, true);
        if (value !== null) {
          rows.push({ label, value: currency(value) });
          points.push({ label, value });
        }
      }
      if (keyData.rate_limit && typeof keyData.rate_limit === "object") {
        const requests = keyData.rate_limit.requests;
        const interval = keyData.rate_limit.interval;
        if (Number.isInteger(requests) && typeof interval === "string") {
          rows.push({ label: "Rate limit", value: `${requests} requests / ${interval}` });
        }
      }
      const section = { title: "API key", rows };
      if (points.length) {
        section.chart = { kind: "bars", title: "Key spend", unit: "USD", points };
      }
      details.push(section);
    } else {
      details.push({
        title: "API key",
        rows: [{ label: "API key budget", value: "Unavailable right now" }],
      });
    }

    const result = {
      identity: { loginMethod: `Balance: ${currency(balance)}` },
      details,
    };
    if (primary) result.primary = primary;
    if (openRouterActivityUsage) result.openRouterActivityUsage = openRouterActivityUsage;
    return result;
  },
});
