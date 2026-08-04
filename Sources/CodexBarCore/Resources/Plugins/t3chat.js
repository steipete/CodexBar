defineProvider({
  id: "t3chat",
  name: "T3 Chat",
  endpoints: ["https://t3.chat"],
  settings: [],
  capabilities: ["browser-cookies"],
  cookieDomains: ["t3.chat"],
  async fetchUsage(ctx) {
    const cookie = await ctx.browser.cookieHeader("t3.chat");
    const input = encodeURIComponent(JSON.stringify({ "0": { json: { sessionId: null }, meta: { values: { sessionId: ["undefined"] } } } }));
    const response = await ctx.http.get(`https://t3.chat/api/trpc/getCustomerData?batch=1&input=${input}`, {
      headers: {
        Cookie: cookie, Origin: "https://t3.chat", Referer: "https://t3.chat/settings/customization",
        "trpc-accept": "application/jsonl", "x-trpc-source": "web-client", "x-trpc-batch": "true",
      },
    });
    if (response.status !== 200) throw new Error(`T3 Chat API error: HTTP ${response.status}`);
    function find(value) {
      if (!value || typeof value !== "object") return null;
      if ("usageFourHourPercentage" in value || "usageMonthPercentage" in value || (value.subscription && value.usageBand)) return value;
      for (const child of Object.values(value)) { const found = find(child); if (found) return found; }
      return null;
    }
    let data = null;
    for (const line of response.bodyText.split(/\r?\n/)) {
      try { data = find(JSON.parse(line)); } catch (_) {}
      if (data) break;
    }
    if (!data) throw new Error("T3 Chat response is missing customer data");
    const date = value => !value || value <= 0 ? undefined : (value > 10000000000 ? ctx.date.unixMillis(value) : ctx.date.unixSeconds(value));
    const rawPlan = data.subscription && data.subscription.productName || data.subTier;
    const plan = rawPlan && String(rawPlan).split("-").map(part => part.charAt(0).toUpperCase() + part.slice(1)).join(" ");
    return {
      primary: {
        usedPercent: Math.max(0, Math.min(100, Number(data.usageFourHourPercentage || 0))),
        windowMinutes: 240,
        resetsAt: date(data.usageFourHourNextResetAt || data.usageWindowNextResetAt),
        resetDescription: data.usageBand ? `Base - ${String(data.usageBand).trim()}` : "Base",
      },
      secondary: {
        usedPercent: Math.max(0, Math.min(100, Number(data.usageMonthPercentage ?? data.usagePeriodPercentage ?? 0))),
        resetsAt: date(data.subscription && data.subscription.currentPeriodEnd), resetDescription: "Overage",
      },
      identity: { loginMethod: plan || undefined },
    };
  },
});
