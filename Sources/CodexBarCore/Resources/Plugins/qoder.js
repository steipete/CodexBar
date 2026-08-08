defineProvider({
  id: "qoder",
  name: "Qoder",
  endpoints: ["https://qoder.com", "https://qoder.com.cn"],
  settings: [],
  capabilities: ["browser-cookies"],
  cookieDomains: ["qoder.com", "qoder.com.cn"],
  async fetchUsage(ctx) {
    let response = null;
    for (const site of ["qoder.com", "qoder.com.cn"]) {
      const cookie = await ctx.browser.cookieHeader(site);
      const origin = `https://${site}`;
      const candidate = await ctx.http.getJSON(`${origin}/api/v2/me/usages/big_model_credits`, {
        headers: {
          Cookie: cookie, Origin: origin, Referer: `${origin}/account/usage`,
          "X-Requested-With": "XMLHttpRequest", "Bx-V": "2.5.35",
        },
      });
      if (candidate.status >= 200 && candidate.status < 300) { response = candidate; break; }
    }
    if (!response) throw new Error("Qoder credentials were rejected");
    const root = response.json || {};
    const container = root.totalQuota || root.total_quota;
    const sharedContainer = root.sharedQuota || root.shared_quota;
    const summary = container && (container.quotaSummary || container.quota_summary);
    const shared = sharedContainer && (sharedContainer.quotaSummary || sharedContainer.quota_summary);
    if (!summary) throw new Error("Qoder response is missing quota summary");
    const read = (value, camel, snake) => Number(value[camel] ?? value[snake]);
    const used = read(summary, "usedValue", "used_value") + (shared ? read(shared, "usedValue", "used_value") : 0);
    const total = read(summary, "limitValue", "limit_value") + (shared ? read(shared, "limitValue", "limit_value") : 0);
    const percentage = shared ? ctx.pct(used, total) : Number(summary.usagePercentage ?? summary.usage_percentage ?? ctx.pct(used, total));
    const reset = root.nextResetAt ?? root.next_reset_at;
    const resetDate = typeof reset === "number"
      ? (reset > 10000000000 ? ctx.date.unixMillis(reset) : ctx.date.unixSeconds(reset))
      : (reset ? ctx.date.iso(reset) : undefined);
    const format = value => ctx.format.number(value, { maximumFractionDigits: Number.isInteger(value) ? 0 : 2 });
    return { primary: {
      usedPercent: Math.max(0, Math.min(100, percentage)), resetsAt: resetDate,
      resetDescription: `${format(used)} / ${format(total)} credits`,
    } };
  },
});
