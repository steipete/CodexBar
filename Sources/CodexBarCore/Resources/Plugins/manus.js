defineProvider({
  id: "manus",
  name: "Manus",
  endpoints: ["https://api.manus.im"],
  settings: [],
  capabilities: ["browser-cookies"],
  cookieDomains: ["manus.im"],
  async fetchUsage(ctx) {
    const cookies = await ctx.browser.cookieHeader("manus.im");
    const match = /(?:^|;\s*)session_id=([^;]+)/i.exec(cookies);
    if (!match) throw new Error("Manus session cookie is missing");
    const response = await ctx.http.postJSON("https://api.manus.im/user.v1.UserService/GetAvailableCredits", {
      body: {}, headers: {
        Authorization: `Bearer ${match[1]}`, Origin: "https://manus.im", Referer: "https://manus.im/",
        "Connect-Protocol-Version": "1",
      },
    });
    if (response.status !== 200) throw new Error(`Manus API error: HTTP ${response.status}`);
    const root = response.json || {};
    const data = root.data || root.result || root.response || root.availableCredits || root;
    const number = key => Number(data[key] || 0);
    const total = number("totalCredits");
    const free = number("freeCredits");
    const monthly = number("proMonthlyCredits");
    const periodic = number("periodicCredits");
    const refresh = number("refreshCredits");
    const maxRefresh = number("maxRefreshCredits");
    const format = value => new Intl.NumberFormat("en-US", { maximumFractionDigits: 0 }).format(Math.round(value));
    return {
      primary: monthly > 0 ? {
        usedPercent: ctx.pct(monthly - periodic, monthly),
        resetDescription: `Total ${format(total)} • Free ${format(free)}`,
      } : undefined,
      secondary: maxRefresh > 0 ? {
        usedPercent: ctx.pct(maxRefresh - refresh, maxRefresh),
        resetsAt: data.nextRefreshTime ? ctx.date.iso(data.nextRefreshTime) : undefined,
        resetDescription: data.refreshInterval
          ? `${String(data.refreshInterval).replace(/^./, value => value.toUpperCase())}: ${format(refresh)} / ${format(maxRefresh)}`
          : `${format(refresh)} / ${format(maxRefresh)}`,
      } : undefined,
      identity: { loginMethod: `Balance: ${format(total)} credits` },
    };
  },
});
