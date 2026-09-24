defineProvider({
  id: "t3chat",
  name: "T3 Chat",
  endpoints: ["https://t3.chat"],
  settings: [
    { key: "TIMEOUT_SECONDS", title: "Web timeout", type: "plain" },
    { key: "MANUAL_COOKIE", title: "Manual cookie", type: "secure" },
    { key: "CAPTURED_HEADERS", title: "Captured headers", type: "secure" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["t3.chat"],
  async fetchUsage(ctx) {
    const policy = ctx.browser.availability("t3.chat");
    if (policy === "off") throw ctx.fail.missingCredential("T3 Chat cookies are disabled.");
    const cookie =
      (policy === "manual" && ctx.settings.getSecret("MANUAL_COOKIE")) || (await ctx.browser.cookieHeader("t3.chat"));
    const captured = policy === "manual" ? JSON.parse(ctx.settings.getSecret("CAPTURED_HEADERS") || "{}") : {};
    const input = encodeURIComponent(
      JSON.stringify({ 0: { json: { sessionId: null }, meta: { values: { sessionId: ["undefined"] } } } }),
    );
    const response = await ctx.http.get(`https://t3.chat/api/trpc/getCustomerData?batch=1&input=${input}`, {
      timeoutSeconds: Number(ctx.settings.get("TIMEOUT_SECONDS") || 60),
      headers: {
        Accept: "*/*",
        "Accept-Language": "en-US,en;q=0.9",
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
        "Sec-Fetch-Dest": "empty",
        "Sec-Fetch-Mode": "cors",
        "Sec-Fetch-Site": "same-origin",
        Priority: "u=4",
        Pragma: "no-cache",
        "Cache-Control": "no-cache",
        Referer: "https://t3.chat/settings/customization",
        "trpc-accept": "application/jsonl",
        "x-trpc-source": "web-client",
        "x-trpc-batch": "true",
        ...captured,
        Cookie: cookie,
        Origin: "https://t3.chat",
      },
    });
    if (response.status === 401 || response.status === 403) {
      ctx.browser.rejectCookie("t3.chat");
      throw ctx.fail.authenticationExpired("T3 Chat session cookie is invalid or expired.");
    }
    if (response.status === 429 && response.headers["x-vercel-mitigated"] === "challenge")
      throw ctx.fail.apiFailure(
        "T3 Chat returned a Vercel security challenge. Paste the full browser cURL request, not just the Cookie header.",
      );
    if (response.status !== 200) throw ctx.fail.apiFailure(`T3 Chat API error: HTTP ${response.status}`);
    function find(value) {
      if (!value || typeof value !== "object") return null;
      if (
        "usageFourHourPercentage" in value ||
        "usageMonthPercentage" in value ||
        ("subscription" in value && "usageBand" in value)
      )
        return value;
      for (const child of Object.values(value)) {
        const found = find(child);
        if (found) return found;
      }
      return null;
    }
    let data = null;
    for (const line of response.bodyText.split(/\r?\n/)) {
      try {
        data = find(JSON.parse(line));
      } catch {}
      if (data) break;
    }
    const invalid = () => {
      throw ctx.fail.parseFailure("Could not parse T3 Chat usage: invalid customer data.");
    };
    if (!data) invalid();
    for (const key of [
      "usageFourHourPercentage",
      "usageMonthPercentage",
      "usagePeriodPercentage",
      "usageFourHourNextResetAt",
      "usageWindowNextResetAt",
      "billingNextResetAt",
      "lifetimeBalance",
    ]) {
      if (data[key] != null && (typeof data[key] !== "number" || !Number.isFinite(data[key]))) invalid();
    }
    for (const key of ["subTier", "usageBand"]) {
      if (data[key] != null && typeof data[key] !== "string") invalid();
    }
    if (data.subscription != null) {
      if (typeof data.subscription !== "object" || Array.isArray(data.subscription)) invalid();
      for (const key of ["productId", "productName", "status"]) {
        if (data.subscription[key] != null && typeof data.subscription[key] !== "string") invalid();
      }
      for (const key of ["currentPeriodStart", "currentPeriodEnd", "canceledAt", "trialEndsAt"]) {
        if (data.subscription[key] != null && typeof data.subscription[key] !== "number") invalid();
      }
    }
    const date = (value) =>
      !value || value <= 0 ? undefined : value > 10000000000 ? ctx.date.unixMillis(value) : ctx.date.unixSeconds(value);
    const rawPlan = (data.subscription?.productName ?? data.subTier)?.trim();
    const band = data.usageBand?.trim();
    const plan =
      rawPlan &&
      String(rawPlan)
        .split("-")
        .filter(Boolean)
        .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
        .join(" ");
    return {
      primary: {
        usedPercent: Math.max(0, Math.min(100, Number(data.usageFourHourPercentage || 0))),
        windowMinutes: 240,
        resetsAt: date(data.usageFourHourNextResetAt) || date(data.usageWindowNextResetAt),
        resetDescription: band ? `Base - ${band}` : "Base",
      },
      secondary: {
        usedPercent: Math.max(0, Math.min(100, Number(data.usageMonthPercentage ?? data.usagePeriodPercentage ?? 0))),
        resetsAt: date(data.subscription && data.subscription.currentPeriodEnd),
        resetDescription: "Overage",
      },
      identity: { loginMethod: plan || undefined },
    };
  },
});
