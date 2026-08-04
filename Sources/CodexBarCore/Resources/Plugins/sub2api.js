defineProvider({
  id: "sub2api",
  name: "sub2api",
  endpoints: [{ setting: "SUB2API_BASE_URL", policy: "https-or-loopback-http" }],
  auth: { type: "bearer", secret: "SUB2API_API_KEY" },
  settings: [
    { key: "SUB2API_API_KEY", title: "API key", type: "secure" },
    { key: "SUB2API_BASE_URL", title: "Base URL", type: "plain" },
  ],
  async fetchUsage(ctx) {
    let base = ctx.settings.get("SUB2API_BASE_URL").replace(/\/$/, "");
    if (!/\/v1(?:\/usage)?$/.test(base)) base += "/v1";
    if (!/\/usage$/.test(base)) base += "/usage";
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    const response = await ctx.http.getJSON(`${base}?days=30&timezone=${encodeURIComponent(timezone)}`);
    if (response.status < 200 || response.status >= 300) throw new Error(`sub2api API error: HTTP ${response.status}`);
    const data = response.json || {};
    if (data.isValid === false) throw new Error("sub2api credentials are invalid");
    const unit = data.unit || (data.quota && data.quota.unit) || "USD";
    const amount = (used, limit, valueUnit = "USD") => `${valueUnit.toUpperCase() === "USD" ? `$${Number(used).toFixed(2)}` : `${Number(used).toFixed(2)} ${valueUnit}`} / ${valueUnit.toUpperCase() === "USD" ? `$${Number(limit).toFixed(2)}` : `${Number(limit).toFixed(2)} ${valueUnit}`}`;
    const window = (used, limit, minutes, valueUnit = "USD") => limit > 0 ? ({
      usedPercent: ctx.pct(used, limit), windowMinutes: minutes,
      resetDescription: amount(used, limit, valueUnit),
    }) : null;
    let primary = null;
    let secondary = null;
    let tertiary = null;
    if (data.subscription) {
      primary = window(data.subscription.daily_usage_usd || 0, data.subscription.daily_limit_usd, 1440);
      secondary = window(data.subscription.weekly_usage_usd || 0, data.subscription.weekly_limit_usd, 10080);
      tertiary = window(data.subscription.monthly_usage_usd || 0, data.subscription.monthly_limit_usd, 43200);
    } else if (data.quota) {
      primary = window(data.quota.used, data.quota.limit, null, data.quota.unit || unit);
      if (primary) delete primary.windowMinutes;
    }
    const minuteMap = { "5h": 300, "1d": 1440, "7d": 10080 };
    const titleMap = { "5h": "5 hour limit", "1d": "Daily limit", "7d": "7 day limit" };
    const extraWindows = (data.rate_limits || []).map(rate => ({
      id: rate.window,
      title: titleMap[rate.window.toLowerCase()] || `${rate.window} limit`,
      window: {
        usedPercent: ctx.pct(rate.used, rate.limit),
        windowMinutes: minuteMap[rate.window.toLowerCase()],
        resetsAt: rate.reset_at ? ctx.date.iso(rate.reset_at) : undefined,
        resetDescription: amount(rate.used, rate.limit),
      },
    }));
    const rows = [];
    if (data.balance !== undefined && data.balance !== null) rows.push({ label: "Balance", value: amount(data.balance, data.balance, unit).split(" / ")[0] });
    for (const [title, totals] of [["Today", data.usage && data.usage.today], ["All time", data.usage && data.usage.total]]) {
      if (!totals) continue;
      rows.push({ label: `${title} requests`, value: new Intl.NumberFormat("en-US").format(totals.requests || 0) });
      rows.push({ label: `${title} tokens`, value: new Intl.NumberFormat("en-US").format(totals.total_tokens || 0), secondaryValue: `$${Number(totals.actual_cost || 0).toFixed(2)}` });
    }
    return {
      primary, secondary, tertiary, extraWindows,
      subscriptionExpiresAt: (data.subscription && data.subscription.expires_at) || data.expires_at,
      identity: { organization: data.planName, loginMethod: data.planName },
      details: rows.length ? [{ title: "Usage summary", rows }] : undefined,
    };
  },
});
