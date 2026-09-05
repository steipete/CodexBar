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
    {
      key: "OPENROUTER_MANAGEMENT_API_KEY",
      title: "Management API key",
      subtitle: "Optional key used only for exact 30-day Activity spend.",
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
    } catch {
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
    let keyDegradation = null;
    let costUsage = null;
    let activitySummary = null;
    let activityDegradation = null;
    const managementKeyConfigured = Boolean(ctx.settings.getSecret("OPENROUTER_MANAGEMENT_API_KEY"));
    const injectedOptionalTimeout = ctx.__codexbarOptionalRequestTimeoutSeconds;
    const optionalRequestTimeoutSeconds =
      typeof injectedOptionalTimeout === "number" && Number.isFinite(injectedOptionalTimeout)
        ? injectedOptionalTimeout
        : 1;
    function degradationReason(error) {
      const message = error && typeof error.message === "string" ? error.message : String(error);
      if (/timed out|-1001/i.test(message)) return "Request timed out";
      if (/json|parse|invalid|must be|conflict|duplicate|overflow|exceed/i.test(message)) return "Response was invalid";
      return "Request failed";
    }
    try {
      const keyResponse = await ctx.http.get(`${base}/key`, {
        timeoutSeconds: optionalRequestTimeoutSeconds,
      });
      if (keyResponse.status !== 200) keyDegradation = `Request returned HTTP ${keyResponse.status}`;
      const keyPayload = keyResponse.status === 200 ? JSON.parse(keyResponse.bodyText) : null;
      if (keyPayload && keyPayload.data && typeof keyPayload.data === "object" && !Array.isArray(keyPayload.data)) {
        const candidate = keyPayload.data;
        for (const field of ["limit", "limit_remaining", "usage", "usage_daily", "usage_weekly", "usage_monthly"])
          finite(candidate[field], `key.${field}`, true);
        if (
          candidate.limit_reset !== null &&
          candidate.limit_reset !== undefined &&
          typeof candidate.limit_reset !== "string"
        )
          throw new TypeError("key.limit_reset must be a string");
        if (
          candidate.rate_limit !== null &&
          candidate.rate_limit !== undefined &&
          (!candidate.rate_limit ||
            typeof candidate.rate_limit !== "object" ||
            !Number.isInteger(candidate.rate_limit.requests) ||
            typeof candidate.rate_limit.interval !== "string")
        ) {
          throw new TypeError("key.rate_limit is invalid");
        }
        if (
          candidate.is_management_key !== null &&
          candidate.is_management_key !== undefined &&
          typeof candidate.is_management_key !== "boolean"
        ) {
          throw new TypeError("key.is_management_key must be a boolean");
        }
        keyData = candidate;
      }
    } catch (error) {
      keyDegradation = degradationReason(error);
    }
    if (!keyData && !keyDegradation) keyDegradation = "Response was unavailable";

    function activityDegradationReason(status, error) {
      if (status === 403) return "Management API key required";
      if (status) return `Request returned HTTP ${status}`;
      return degradationReason(error);
    }

    function isOfficialAPIBase(value) {
      const match = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]+)(\/[^?#]*)?$/.exec(value);
      if (!match) return false;
      const scheme = match[1].toLowerCase();
      const authority = match[2].toLowerCase();
      const path = match[3] || "";
      return (
        scheme === "https" && (authority === "openrouter.ai" || authority === "openrouter.ai:443") && path === "/api/v1"
      );
    }

    // OpenRouter exposes the credential kind through /key. Accept a management key from the
    // legacy API-key slot only on the official API origin; a custom endpoint must never be able
    // to redirect that credential to OpenRouter Activity by claiming it is a management key.
    const standardKeyIsOfficialManagementKey = isOfficialAPIBase(base) && keyData && keyData.is_management_key === true;
    const activityCredentialConfigured = managementKeyConfigured || standardKeyIsOfficialManagementKey;

    if (!activityCredentialConfigured) {
      activityDegradation = "Management API key not configured";
    } else
      try {
        const now = ctx.date.now();
        const latestCompletedDate = new Date(now.getTime() - 24 * 60 * 60 * 1000);
        const latestCompleted = latestCompletedDate.toISOString().slice(0, 10);
        const cutoffDate = new Date(latestCompletedDate.getTime() - 29 * 24 * 60 * 60 * 1000);
        const cutoff = cutoffDate.toISOString().slice(0, 10);
        // A management credential must never follow the user-configurable API base to a proxy.
        const activityURL = "https://openrouter.ai/api/v1/activity";
        const activityOptions = { timeoutSeconds: optionalRequestTimeoutSeconds };
        if (managementKeyConfigured) activityOptions.openRouterManagementAuth = true;
        const [historyResponse, latestCompletedResponse] = await Promise.all([
          ctx.http.get(activityURL, activityOptions),
          ctx.http.get(`${activityURL}?date=${encodeURIComponent(latestCompleted)}`, {
            ...activityOptions,
          }),
        ]);
        if (historyResponse.status !== 200 || latestCompletedResponse.status !== 200) {
          const failed = historyResponse.status !== 200 ? historyResponse : latestCompletedResponse;
          activityDegradation = activityDegradationReason(failed.status);
        } else {
          const payloads = [historyResponse, latestCompletedResponse].map((response) => JSON.parse(response.bodyText));
          const rows = payloads.flatMap((payload) => {
            if (!payload || !Array.isArray(payload.data)) throw new TypeError("activity.data must be an array");
            return payload.data;
          });
          if (rows.length > 20000) throw new TypeError("activity.data exceeds 20000 rows");
          const seen = new Map();
          const entries = [];
          let aggregateInputTokens = 0;
          let aggregateOutputTokens = 0;
          let aggregateReasoningTokens = 0;
          let aggregateRequests = 0;
          let aggregateCost = 0;
          let aggregateEstimatedCost = 0;
          for (const [index, row] of rows.entries()) {
            if (!row || typeof row !== "object" || Array.isArray(row)) {
              throw new TypeError(`activity.data[${index}] must be an object`);
            }
            const rawDate = typeof row.date === "string" ? row.date.trim() : "";
            if (!/^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}:\d{2})?$/.test(rawDate)) {
              throw new TypeError(`activity.data[${index}].date must be YYYY-MM-DD or YYYY-MM-DD HH:MM:SS`);
            }
            const date = rawDate.slice(0, 10);
            const parsedDate = new Date(`${date}T00:00:00Z`);
            if (!Number.isFinite(parsedDate.getTime()) || parsedDate.toISOString().slice(0, 10) !== date) {
              throw new TypeError(`activity.data[${index}].date must be a real calendar date`);
            }
            if (date > latestCompleted) {
              throw new TypeError(`activity.data[${index}].date must be a completed UTC day`);
            }
            if (date < cutoff) continue;
            const rawModel = row.model_permaslug ?? row.model;
            const model = typeof rawModel === "string" && rawModel.trim() ? rawModel.trim() : null;
            if (model !== null && model.length > 64) {
              throw new TypeError(`activity.data[${index}].model exceeds 64 characters`);
            }
            const inputTokens = finite(row.prompt_tokens, `activity.data[${index}].prompt_tokens`, false);
            const outputTokens = finite(row.completion_tokens, `activity.data[${index}].completion_tokens`, false);
            const reasoningTokens = finite(row.reasoning_tokens, `activity.data[${index}].reasoning_tokens`, true);
            const requests = finite(row.requests, `activity.data[${index}].requests`, false);
            const meteredCost = finite(row.usage, `activity.data[${index}].usage`, false);
            const estimatedCost =
              finite(row.byok_usage_inference, `activity.data[${index}].byok_usage_inference`, true) ?? 0;
            const cost = meteredCost + estimatedCost;
            for (const [field, value] of [
              ["prompt_tokens", inputTokens],
              ["completion_tokens", outputTokens],
              ["reasoning_tokens", reasoningTokens],
              ["requests", requests],
            ]) {
              if (value !== null && (!Number.isSafeInteger(value) || value < 0)) {
                throw new TypeError(`activity.data[${index}].${field} must be a nonnegative safe integer`);
              }
            }
            if (reasoningTokens !== null && reasoningTokens > outputTokens) {
              throw new TypeError(`activity.data[${index}].reasoning_tokens must not exceed completion_tokens`);
            }
            if (meteredCost < 0 || estimatedCost < 0 || !Number.isFinite(cost)) {
              throw new TypeError(`activity.data[${index}] spend must be finite and nonnegative`);
            }
            if (!Number.isSafeInteger(inputTokens + outputTokens)) {
              throw new TypeError(`activity.data[${index}] token total overflowed`);
            }
            const identity = JSON.stringify([
              date,
              model,
              row.endpoint_id || null,
              row.provider_name || null,
              row.workspace_id || null,
            ]);
            const signature = JSON.stringify([
              inputTokens,
              outputTokens,
              reasoningTokens,
              requests,
              meteredCost,
              estimatedCost,
            ]);
            if (seen.has(identity)) {
              if (seen.get(identity) !== signature) {
                throw new TypeError(`activity.data[${index}] conflicts with a duplicate activity row`);
              }
              continue;
            }
            seen.set(identity, signature);
            aggregateInputTokens += inputTokens;
            aggregateOutputTokens += outputTokens;
            aggregateReasoningTokens += reasoningTokens ?? 0;
            aggregateRequests += requests;
            aggregateCost += cost;
            aggregateEstimatedCost += estimatedCost;
            if (
              !Number.isSafeInteger(aggregateInputTokens) ||
              !Number.isSafeInteger(aggregateOutputTokens) ||
              !Number.isSafeInteger(aggregateInputTokens + aggregateOutputTokens) ||
              !Number.isSafeInteger(aggregateReasoningTokens) ||
              !Number.isSafeInteger(aggregateRequests)
            ) {
              throw new TypeError("activity aggregate exceeded the safe integer range");
            }
            if (!Number.isFinite(aggregateCost) || !Number.isFinite(aggregateEstimatedCost)) {
              throw new TypeError("activity spend aggregate overflowed");
            }
            entries.push({
              date,
              inputTokens,
              outputTokens,
              reasoningTokens,
              requests,
              cost,
              estimatedCost,
              model,
            });
            if (entries.length > 10000) throw new TypeError("activity.data exceeds 10000 distinct rows");
          }
          costUsage = {
            currency: "USD",
            historyDays: 30,
            historyLabel: "Last 30 days (UTC)",
            windowEnd: latestCompleted,
            entries,
          };
          const models = [...new Set(entries.map((entry) => entry.model).filter(Boolean))].sort();
          activitySummary = {
            tokens: aggregateInputTokens + aggregateOutputTokens,
            inputTokens: aggregateInputTokens,
            outputTokens: aggregateOutputTokens,
            reasoningTokens: aggregateReasoningTokens,
            requests: aggregateRequests,
            cost: aggregateCost,
            models,
          };
        }
      } catch (error) {
        activityDegradation = activityDegradationReason(null, error);
      }
    if (!costUsage && !activityDegradation) activityDegradation = "Response was unavailable";

    function resetWindowUsage(reset) {
      const windowKey =
        reset === "daily"
          ? "usage_daily"
          : reset === "weekly"
            ? "usage_weekly"
            : reset === "monthly"
              ? "usage_monthly"
              : null;
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

    const currency = (value) => `$${Math.max(0, value).toFixed(2)}`;
    const integer = (value) => String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    const modelSummary = (models) => {
      if (!models.length) return "No model names returned";
      const maximumLength = 120;
      for (let count = models.length; count > 0; count -= 1) {
        const suffix = count < models.length ? ` · +${models.length - count} more` : "";
        const candidate = `${models.slice(0, count).join(", ")}${suffix}`;
        if (candidate.length <= maximumLength) return candidate;
      }
      // Individual Activity model names are already capped at 64 characters, so this is defensive only.
      return `${models.length} models`;
    };
    const details = [
      {
        title: "Credits",
        rows: [
          { label: "Remaining", value: currency(balance) },
          { label: "Used", value: currency(totalUsage) },
          { label: "Total added", value: currency(totalCredits) },
        ],
      },
    ];

    if (keyData) {
      const rows = [];
      if (keyLimit !== null && keyLimit > 0) {
        rows.push({
          label: "API key limit",
          value: currency(keyLimit),
          secondaryValue: "Spending cap, not balance",
        });
        if (keyRemaining !== null) rows.push({ label: "API key remaining", value: currency(keyRemaining) });
        if (keyUsage !== null) rows.push({ label: "API key used", value: currency(keyUsage) });
      } else {
        rows.push({ label: "API key limit", value: "No limit configured" });
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
        rows: [
          {
            label: "API key limit",
            value: "Unavailable right now",
            secondaryValue: keyDegradation,
          },
        ],
      });
    }

    if (costUsage && activitySummary) {
      details.push({
        title: "Activity (last 30 completed UTC days)",
        rows: [
          {
            label: "Tracked tokens",
            value: integer(activitySummary.tokens),
            secondaryValue: `${integer(activitySummary.inputTokens)} input · ${integer(activitySummary.outputTokens)} output`,
          },
          { label: "Requests", value: integer(activitySummary.requests) },
          { label: "Spend", value: currency(activitySummary.cost) },
          {
            label: "Models",
            value: integer(activitySummary.models.length),
            secondaryValue: modelSummary(activitySummary.models),
          },
        ],
      });
    } else {
      details.push({
        title: "Spend history",
        rows: [
          {
            label: "Last 30 days",
            value: "Unavailable right now",
            secondaryValue: activityDegradation,
          },
        ],
      });
    }

    const result = {
      identity: { loginMethod: `Balance: ${currency(balance)}` },
      details,
    };
    if (costUsage) result.costUsage = costUsage;
    if (primary) result.primary = primary;
    return result;
  },
});
