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
  id: "nanogpt",
  name: "NanoGPT",
  endpoints: ["https://api.nano-gpt.com", "https://nano-gpt.com"],
  dashboardURL: "https://nano-gpt.com/subscription",
  auth: { type: "bearer", secret: "NANOGPT_API_KEY" },
  settings: [
    {
      key: "NANOGPT_API_KEY",
      title: "NanoGPT API key",
      subtitle: "Saved in CodexBar's local config file. Read-only usage access.",
      type: "secure",
    },
  ],
  capabilities: ["http-status"],
  snapshotPolicy: { percent: "preserve-overage" },
  async fetchUsage(ctx) {
    function fail(message) {
      throw ctx.fail.parseFailure(message);
    }

    function record(value) {
      return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    }

    // A finite, non-negative number or undefined. Truly malformed values fail the whole response
    // instead of being silently dropped, matching the numeric-parsing guardrail.
    function counter(value) {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        return fail("NanoGPT returned a non-numeric usage counter.");
      }
      return value;
    }

    // Quotas reset at UNIX epoch milliseconds; a fractional value is still valid.
    function resetAt(value) {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
        return fail("NanoGPT returned an invalid quota reset time.");
      }
      return ctx.date.unixMillis(value);
    }

    // USD amounts arrived as decimal strings in the documented balance response and as numbers in the
    // usage totals. Both convert here; anything else fails parsing.
    function amount(value) {
      if (value === undefined || value === null) return undefined;
      let parsed = value;
      if (typeof value === "string") {
        const text = value.trim();
        // Number("") is 0. An empty or non-decimal string is a malformed amount, not a zero balance.
        if (!/^\d+(?:\.\d+)?$/.test(text)) return fail("NanoGPT returned an invalid non-negative amount.");
        parsed = Number(text);
      }
      if (typeof parsed !== "number" || !Number.isFinite(parsed) || parsed < 0) {
        return fail("NanoGPT returned an invalid non-negative amount.");
      }
      return parsed;
    }

    async function get(path, timeoutSeconds, retryPolicy) {
      try {
        return await ctx.http.get(`https://api.nano-gpt.com${path}`, {
          timeoutSeconds,
          ...(retryPolicy ? { retryPolicy } : {}),
        });
      } catch (error) {
        const transportClass = error.transportClass;
        if (transportClass === "cancelled") throw error;
        const timeout = transportClass === "timeout" || transportClass === "connection";
        const detail = timeout ? "timed out" : "failed";
        throw timeout
          ? ctx.fail.networkFailure(`NanoGPT ${path} ${detail}.`)
          : ctx.fail.apiFailure(`NanoGPT ${path} ${detail}.`);
      }
    }

    // Shared classification for one request's non-2xx response. The quota and usage GETs already opted into
    // transientIdempotent, so a 429 here must not carry retryAfterSeconds: that hint replays the whole strategy.
    function classify(path, status) {
      const message = `NanoGPT ${path} returned HTTP ${status}.`;
      if (status === 401 || status === 403) {
        throw ctx.fail.authenticationExpired("NanoGPT rejected the API key. Paste a fresh key in Settings.");
      }
      if (status === 429) throw ctx.fail.rateLimited(message);
      if (status >= 500) throw ctx.fail.providerUnavailable(message);
      throw ctx.fail.apiFailure(message);
    }

    function decode(bodyText, label) {
      let decoded;
      try {
        decoded = JSON.parse(bodyText);
      } catch (error) {
        void error;
        return fail(`NanoGPT ${label} response is not valid JSON.`);
      }
      const root = record(decoded);
      if (!root) return fail(`NanoGPT ${label} response is not a JSON object.`);
      return root;
    }

    // Month-to-date spend covers the current UTC month. Image-only days cannot sum tokens, so the
    // matching day bucket is dropped rather than undercounting.
    function monthStart(now) {
      return `${now.toISOString().slice(0, 8)}01`;
    }

    // 1. Subscription quotas. Only a 2xx response describes the subscription lanes.
    const quotaPath = "/api/subscription/v1/usage";
    const quotaResponse = await get(quotaPath, 8, "transientIdempotent");
    if (quotaResponse.status !== 200) classify(quotaPath, quotaResponse.status);
    const quota = decode(quotaResponse.bodyText, "subscription");

    const lane = (key) => {
      const value = quota[key];
      if (value === undefined || value === null) return undefined;
      const entry = record(value);
      if (!entry) return fail(`NanoGPT subscription "${key}" lane is malformed.`);
      const used = counter(entry.used);
      const remaining = counter(entry.remaining);
      const percent = counter(entry.percentUsed);
      const degraded = entry.degraded === true;
      // A degraded lane reports null counters. That is "unknown", not a full allowance and not a parse error.
      if (used === undefined && remaining === undefined && percent === undefined && !degraded) {
        return fail(`NanoGPT subscription "${key}" lane has no counters.`);
      }
      return {
        used,
        remaining,
        // Documented as a fraction that may exceed 1. preserve-overage keeps 120% visible as over budget.
        percent: percent === undefined ? undefined : percent * 100,
        resetsAt: resetAt(entry.resetAt),
        degraded,
      };
    };

    const daily = lane("dailyInputTokens");
    const weekly = lane("weeklyInputTokens");
    const images = lane("dailyImages");
    const trial = lane("tokens");

    const state = quota.state;
    if (state !== undefined && state !== null && typeof state !== "string") {
      fail("NanoGPT subscription state is malformed.");
    }

    const percentOf = (entry) => {
      if (!entry) return undefined;
      if (entry.percent !== undefined) return entry.percent;
      if (entry.used !== undefined && entry.remaining !== undefined) {
        const total = entry.used + entry.remaining;
        if (total > 0) return (entry.used / total) * 100;
      }
      return undefined;
    };

    // Image counts are not tokens, so they stay a named extra window beside the token lanes.
    const extraWindows = [];
    if (images) {
      const percent = percentOf(images);
      extraWindows.push({
        id: "daily-images",
        title: "Daily images",
        usageKnown: percent !== undefined && !images.degraded,
        window: {
          usedPercent: _nullishCoalesce(percent, () => 0),
          windowMinutes: 1440,
          resetsAt: images.resetsAt,
          resetDescription: images.degraded ? "Quota unavailable" : undefined,
        },
      });
    }

    // 2. Prepaid USD balance. Documented as POST /api/check-balance with x-api-key, on the API host and the
    // website host. The website host is only used when the API host does not serve the route.
    const apiKey = ctx.settings.getSecret("NANOGPT_API_KEY");
    if (!apiKey) {
      throw ctx.fail.authenticationExpired("Paste a NanoGPT API key in Settings or set NANOGPT_API_KEY.");
    }
    const balanceURLs = ["https://api.nano-gpt.com/api/check-balance", "https://nano-gpt.com/api/check-balance"];
    let balance;
    for (const [index, url] of balanceURLs.entries()) {
      let response;
      try {
        response = await ctx.http.post(url, {
          timeoutSeconds: index === 0 ? 5 : 4,
          headers: { "X-API-Key": apiKey },
          body: {},
        });
      } catch (error) {
        if (error.transportClass === "cancelled") throw error;
      }
      if (!response) continue;
      const path = url.slice(url.indexOf("/", 8));
      if (response.status === 401 || response.status === 403) {
        classify(path, response.status);
      }
      if (response.status === 200) {
        const parsed = amount(decode(response.bodyText, "balance").usd_balance);
        if (parsed === undefined) fail("NanoGPT balance response has no usd_balance.");
        balance = parsed;
        break;
      }
      // A 5xx on the API host, or a 404/429/5xx on the website, leaves the balance unset.
      // Quotas and month-to-date spend are still worth reading.
    }

    // 3. Month-to-date spend and tokens from the authenticated key's own usage totals.
    const now = ctx.date.now();
    const usagePath = `/api/v1/usage?from=${monthStart(now)}&to=${now.toISOString().slice(0, 10)}&group_by=day`;
    const usageResponse = await get(usagePath, 7, "transientIdempotent");
    if (usageResponse.status !== 200) classify(usagePath, usageResponse.status);
    const usage = decode(usageResponse.bodyText, "usage");
    const totals = _nullishCoalesce(record(usage.totals), () => ({}));
    const requests = counter(totals.requests);
    const totalTokens = counter(totals.totalTokens);
    const netCost = amount(totals.netCostUsd);
    const byDay = Array.isArray(usage.byDay) ? usage.byDay.map(record) : [];

    // Detail rows: the lanes first, then billing context. Percent is filled from used + remaining so a
    // clamped or over-budget lane still shows a number the meter can render.
    const rows = [];
    const row = (label, entry, usedLabel) => {
      if (!entry) return;
      const percent = percentOf(entry);
      rows.push({
        label,
        value: entry.degraded
          ? "Unavailable"
          : `${ctx.format.number(_nullishCoalesce(entry.used, () => 0))} ${usedLabel}`,
        ...(entry.remaining !== undefined ? { secondaryValue: `${ctx.format.number(entry.remaining)} left` } : {}),
        ...(percent !== undefined && !entry.degraded
          ? { progress: Math.max(0, Math.min(1, percent / 100)), usageValue: entry.used }
          : { severity: "warning" }),
      });
    };
    row("Daily input tokens", daily, "used");
    row("Weekly input tokens", weekly, "used");
    row("Daily images", images, "used");
    row("Trial tokens", trial, "used");

    const billingRows = [];
    if (requests !== undefined) billingRows.push({ label: "Requests this month", value: ctx.format.number(requests) });
    if (totalTokens !== undefined)
      billingRows.push({ label: "Tokens this month", value: ctx.format.number(totalTokens) });
    if (netCost !== undefined) billingRows.push({ label: "Net spend this month", value: ctx.format.usd(netCost) });

    const routing = record(quota.routing);
    const mode = _optionalChain([routing, "optionalAccess", (_) => _.recommendedMode]);
    if (mode === "subscription" || mode === "paygo" || mode === "unavailable") {
      billingRows.push({
        label: "NanoGPT recommends",
        value: mode === "paygo" ? "Paid balance" : mode === "subscription" ? "Subscription" : "Neither",
        secondaryValue:
          typeof _optionalChain([routing, "optionalAccess", (_2) => _2.reason]) === "string"
            ? routing.reason.slice(0, 120)
            : undefined,
      });
    }

    // Daily spend chart for the current UTC month, drawn only from day buckets that also sum tokens.
    const points = byDay
      .filter((day) => day && day.date !== undefined)
      .map((day) => ({
        label: String(_optionalChain([day, "optionalAccess", (_3) => _3.date])),
        value: _nullishCoalesce(amount(_optionalChain([day, "optionalAccess", (_4) => _4.netCostUsd])), () => 0),
      }))
      .filter((point) => point.value > 0);

    const primaryPercent = percentOf(daily);
    const secondaryPercent = percentOf(weekly);

    return {
      primary:
        primaryPercent !== undefined && daily && !daily.degraded
          ? {
              title: "Daily input tokens",
              usedPercent: primaryPercent,
              windowMinutes: 1440,
              resetsAt: daily.resetsAt,
            }
          : undefined,
      secondary:
        secondaryPercent !== undefined && weekly && !weekly.degraded
          ? {
              title: "Weekly input tokens",
              usedPercent: secondaryPercent,
              windowMinutes: 10080,
              resetsAt: weekly.resetsAt,
            }
          : undefined,
      extraWindows,
      // Spend and balance are independent reads. A failed balance must not drop month-to-date spend,
      // and a missing spend total must not invent one from the chart.
      cost:
        netCost !== undefined || balance !== undefined
          ? {
              used: _nullishCoalesce(netCost, () => points.reduce((sum, point) => sum + point.value, 0)),
              currency: "USD",
              ...(balance !== undefined ? { balance } : {}),
              period: "Month to date",
            }
          : undefined,
      details: [
        ...(rows.length ? [{ title: "Subscription quotas", rows }] : []),
        ...(billingRows.length
          ? [
              {
                title: "Billing",
                rows: billingRows,
                ...(points.length ? { chart: { kind: "bars", title: "Daily spend", unit: "USD", points } } : {}),
              },
            ]
          : []),
      ],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
