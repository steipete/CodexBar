defineProvider({
  id: "zai",
  name: "z.ai / GLM",
  endpoints: [
    "https://api.z.ai",
    "https://open.bigmodel.cn",
    { setting: "Z_AI_QUOTA_ENDPOINT", policy: "https" },
    { setting: "Z_AI_MODEL_USAGE_ENDPOINT", policy: "https" },
  ],
  auth: { type: "bearer", secret: "Z_AI_API_KEY" },
  settings: [
    { key: "Z_AI_API_KEY", title: "API key", type: "secure" },
    { key: "Z_AI_REGION", title: "API region", type: "plain" },
    { key: "Z_AI_USAGE_SCOPE", title: "Usage scope", type: "plain" },
    { key: "Z_AI_ORGANIZATION", title: "Organization", type: "plain" },
    { key: "Z_AI_PROJECT", title: "Project", type: "plain" },
    { key: "Z_AI_QUOTA_ENDPOINT", title: "Quota endpoint", type: "plain" },
    { key: "Z_AI_MODEL_USAGE_ENDPOINT", title: "Model usage endpoint", type: "plain" },
  ],

  async fetchUsage(ctx) {
    const region = ctx.settings.get("Z_AI_REGION") || "global";
    const scope = ctx.settings.get("Z_AI_USAGE_SCOPE") || "personal";
    const organization = ctx.settings.get("Z_AI_ORGANIZATION");
    const project = ctx.settings.get("Z_AI_PROJECT");
    if (region !== "global" && region !== "bigmodel-cn") throw new Error("Unsupported z.ai region");
    if (scope !== "personal" && scope !== "team") throw new Error("Unsupported z.ai usage scope");
    if (scope === "team" && (!organization || !project))
      throw new Error("z.ai team scope needs organization and project");
    const base = region === "bigmodel-cn" ? "https://open.bigmodel.cn" : "https://api.z.ai";
    const quotaEndpoint = ctx.settings.get("Z_AI_QUOTA_ENDPOINT") || `${base}/api/monitor/usage/quota/limit`;
    const modelUsageEndpoint = ctx.settings.get("Z_AI_MODEL_USAGE_ENDPOINT") || `${base}/api/monitor/usage/model-usage`;
    const headers = scope === "team" ? { "Bigmodel-Organization": organization, "Bigmodel-Project": project } : {};
    function withType(url, value) {
      const parts = String(url).split("?");
      const query = parts.length > 1 ? parts.slice(1).join("?").split("&").filter(Boolean) : [];
      const filtered = query.filter((item) => decodeURIComponent(item.split("=", 1)[0]) !== "type");
      filtered.push(`type=${value}`);
      return `${parts[0]}?${filtered.join("&")}`;
    }
    const quotaURL = scope === "team" ? withType(quotaEndpoint, 2) : quotaEndpoint;
    const quotaResponse = await ctx.http.getJSON(quotaURL, { headers });
    if (quotaResponse.status !== 200) throw new Error(`z.ai quota API error: HTTP ${quotaResponse.status}`);
    const root = quotaResponse.json;
    if (!root || typeof root !== "object" || Array.isArray(root) || root.success !== true || root.code !== 200) {
      throw new Error(`z.ai quota API error: ${root && root.msg ? root.msg : "invalid response"}`);
    }
    if (!root.data || typeof root.data !== "object" || !Array.isArray(root.data.limits)) {
      throw new Error("Failed to parse z.ai quota data");
    }

    function optionalInteger(value, field) {
      if (value === null || value === undefined) return null;
      if (!Number.isInteger(value)) throw new Error(`z.ai ${field} must be an integer`);
      return value;
    }
    function parseLimit(raw) {
      if (
        !raw ||
        typeof raw !== "object" ||
        Array.isArray(raw) ||
        typeof raw.type !== "string" ||
        !Number.isInteger(raw.unit) ||
        !Number.isInteger(raw.number) ||
        !Number.isInteger(raw.percentage)
      ) {
        throw new Error("Failed to parse z.ai limit entry");
      }
      if (raw.type !== "TOKENS_LIMIT" && raw.type !== "TIME_LIMIT" && raw.type !== "CREDIT_LIMIT") return null;
      const usage = optionalInteger(raw.usage, "limit.usage");
      const current = optionalInteger(raw.currentValue, "limit.currentValue");
      const remaining = optionalInteger(raw.remaining, "limit.remaining");
      let percent = raw.percentage;
      if (usage !== null && usage > 0) {
        let used = null;
        if (remaining !== null) used = Math.max(usage - remaining, current === null ? usage - remaining : current);
        else if (current !== null) used = current;
        if (used !== null) percent = ctx.pct(Math.max(0, Math.min(usage, used)), usage);
      }
      percent = Math.max(0, Math.min(100, percent));
      const multipliers = { 1: 1440, 3: 60, 5: 1, 6: 10080 };
      const windowMinutes = raw.number > 0 && multipliers[raw.unit] ? raw.number * multipliers[raw.unit] : null;
      const reset = optionalInteger(raw.nextResetTime, "limit.nextResetTime");
      const details = raw.usageDetails === null || raw.usageDetails === undefined ? [] : raw.usageDetails;
      if (!Array.isArray(details)) throw new Error("z.ai usageDetails must be an array");
      return { raw, usage, current, remaining, percent, windowMinutes, reset, details };
    }
    function window(limit) {
      const result = { usedPercent: limit.percent };
      if ((limit.raw.type === "TOKENS_LIMIT" || limit.raw.type === "CREDIT_LIMIT") && limit.windowMinutes !== null) {
        result.windowMinutes = limit.windowMinutes;
      }
      if (limit.reset !== null) result.resetsAt = ctx.date.unixMillis(limit.reset);
      if (limit.raw.type === "TIME_LIMIT") result.resetDescription = "MCP";
      else if (limit.windowMinutes === 300) result.resetDescription = "5-hour";
      else if (limit.windowMinutes !== null) {
        const units = { 1: "day", 3: "hour", 5: "minute", 6: "week" };
        const name = units[limit.raw.unit];
        if (name) result.resetDescription = `${limit.raw.number} ${name}${limit.raw.number === 1 ? "" : "s"} window`;
      }
      return result;
    }
    function limitRow(label, limit) {
      const parts = [];
      if (limit.usage !== null) parts.push(`${limit.usage} limit`);
      if (limit.remaining !== null) parts.push(`${limit.remaining} remaining`);
      return {
        label,
        value: `${limit.percent.toFixed(limit.percent % 1 ? 1 : 0)}% used`,
        secondaryValue: parts.join(" · ") || undefined,
      };
    }
    // Mirrors UsageFormatter.resetCountdownDescription so the row reads like native reset text.
    function countdownText(millis) {
      const seconds = Math.max(0, millis / 1000);
      if (seconds < 1) return "now";
      const totalMinutes = Math.max(1, Math.ceil(seconds / 60));
      const days = Math.floor(totalMinutes / 1440);
      const hours = Math.floor(totalMinutes / 60) % 24;
      const minutes = totalMinutes % 60;
      if (days > 0) {
        if (hours > 0) return `in ${days}d ${hours}h`;
        if (minutes > 0) return `in ${days}d ${minutes}m`;
        return `in ${days}d`;
      }
      if (hours > 0) return minutes > 0 ? `in ${hours}h ${minutes}m` : `in ${hours}h`;
      return `in ${totalMinutes}m`;
    }
    // Peak is Mon-Fri 06:00-10:00 UTC (14:00-18:00 UTC+8); weekends are off-peak all day.
    // Credit plans charge 1x peak / 0.5x off-peak (docs.z.ai/devpack/overview); legacy
    // TOKENS_LIMIT plans charge model-dependent flat rates, so the row is credit-only.
    // No z.ai endpoint exposes this - it is purely a function of the injected clock.
    function quotaRateRow() {
      const PEAK_START = 6;
      const PEAK_END = 10;
      const now = new Date(ctx.date.nowMillis());
      const day = now.getUTCDay();
      const hour = now.getUTCHours();
      const isPeak = day >= 1 && day <= 5 && hour >= PEAK_START && hour < PEAK_END;
      const boundary = new Date(
        Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), isPeak ? PEAK_END : PEAK_START),
      );
      if (!isPeak) {
        if (hour >= PEAK_START) boundary.setUTCDate(boundary.getUTCDate() + 1);
        while (boundary.getUTCDay() === 0 || boundary.getUTCDay() === 6) {
          boundary.setUTCDate(boundary.getUTCDate() + 1);
        }
      }
      const countdown = countdownText(boundary.getTime() - now.getTime());
      return {
        label: "Quota rate",
        value: isPeak ? "Peak" : "Off-peak",
        secondaryValue: `${isPeak ? "off-peak" : "peak"} ${countdown}`,
      };
    }

    const limits = root.data.limits.map(parseLimit).filter(Boolean);
    const tokenLimits = limits
      .filter((item) => item.raw.type === "TOKENS_LIMIT" || item.raw.type === "CREDIT_LIMIT")
      .sort((a, b) => (a.windowMinutes || Number.MAX_SAFE_INTEGER) - (b.windowMinutes || Number.MAX_SAFE_INTEGER));
    const timeLimit = limits.filter((item) => item.raw.type === "TIME_LIMIT").pop() || null;
    const tokenLimit = tokenLimits.length ? tokenLimits[tokenLimits.length - 1] : null;
    const sessionLimit = tokenLimits.length >= 2 ? tokenLimits[0] : null;
    const primaryLimit = sessionLimit || tokenLimit || timeLimit;
    const result = {
      primary: primaryLimit ? window(primaryLimit) : { usedPercent: 0 },
      identity: {},
      details: [{ title: "Quota details", rows: [] }],
    };
    if (sessionLimit && tokenLimit) result.secondary = window(tokenLimit);
    if ((tokenLimit || sessionLimit) && timeLimit) {
      result.extraWindows = [{ id: "zai-mcp", title: "MCP", window: window(timeLimit) }];
    }
    if (tokenLimit)
      result.details[0].rows.push(
        limitRow(tokenLimit.raw.type === "CREDIT_LIMIT" ? "Credit quota" : "Token quota", tokenLimit),
      );
    if (sessionLimit)
      result.details[0].rows.push(
        limitRow(
          sessionLimit.raw.type === "CREDIT_LIMIT" ? "Session credit quota" : "Session token quota",
          sessionLimit,
        ),
      );
    const hasCreditLimit = [tokenLimit, sessionLimit].some((item) => item && item.raw.type === "CREDIT_LIMIT");
    if (hasCreditLimit) result.details[0].rows.push(quotaRateRow());
    if (timeLimit) {
      result.details[0].rows.push(limitRow("MCP quota", timeLimit));
      for (const detail of timeLimit.details.slice(0, 20)) {
        if (detail && typeof detail.modelCode === "string" && Number.isInteger(detail.usage)) {
          result.details[0].rows.push({ label: detail.modelCode, value: String(detail.usage) });
        }
      }
    }
    const plan = [root.data.planName, root.data.plan, root.data.plan_type, root.data.packageName, root.data.level].find(
      (value) => typeof value === "string" && value.trim(),
    );
    if (plan) result.identity.loginMethod = plan.trim();

    async function modelUsage(daysBack) {
      const end = ctx.date.now();
      const start = new Date(end);
      start.setHours(0, 0, 0, 0);
      start.setDate(start.getDate() - Math.max(1, daysBack));
      const rangeEnd = new Date(end);
      rangeEnd.setMinutes(59, 59, 0);
      const pad = (value) => String(value).padStart(2, "0");
      const stamp = (date) =>
        `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
        `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
      const type = scope === "team" ? "&type=3" : "";
      const modelUsageBase = modelUsageEndpoint.split("?", 1)[0];
      const url =
        `${modelUsageBase}?startTime=${encodeURIComponent(stamp(start))}` +
        `&endTime=${encodeURIComponent(stamp(rangeEnd))}${type}`;
      const response = await ctx.http.getJSON(url, { headers });
      if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
      const body = response.json;
      if (!body || body.success !== true || body.code !== 200) throw new Error("invalid model usage response");
      const data = body.data || {};
      const labels = Array.isArray(data.x_time) ? data.x_time : [];
      const models = Array.isArray(data.modelDataList) ? data.modelDataList : [];
      const points = labels
        .map((label, index) => {
          let total = 0;
          for (const model of models) {
            const value = model && Array.isArray(model.tokensUsage) ? model.tokensUsage[index] : null;
            if (Number.isInteger(value) && value > 0) total += value;
          }
          return { label: String(label), value: total };
        })
        .filter((point) => point.value > 0);
      const totals = models
        .map((model) => ({
          name: model && typeof model.modelName === "string" ? model.modelName : "Unknown",
          tokens:
            model && Array.isArray(model.tokensUsage)
              ? model.tokensUsage.reduce((sum, value) => sum + (Number.isInteger(value) && value > 0 ? value : 0), 0)
              : 0,
        }))
        .filter((item) => item.tokens > 0)
        .sort((a, b) => b.tokens - a.tokens || a.name.localeCompare(b.name));
      return { points, totals };
    }

    for (const [days, title] of [
      [1, "Hourly tokens"],
      [30, "Daily tokens"],
    ]) {
      try {
        const usage = await modelUsage(days);
        if (usage.points.length) {
          result.details.push({
            title,
            rows: usage.totals.slice(0, 20).map((item) => ({ label: item.name, value: String(item.tokens) })),
            chart: { kind: "bars", title, unit: "tokens", points: usage.points },
          });
        }
      } catch {}
    }
    return result;
  },
});
