defineProvider({
  id: "siliconflow",
  name: "SiliconFlow",
  endpoints: ["https://api.siliconflow.cn", "https://api.siliconflow.com"],
  auth: { type: "bearer", secret: "SILICONFLOW_API_KEY" },
  settings: [
    { key: "SILICONFLOW_API_KEY", title: "API key", type: "secure" },
    { key: "SILICONFLOW_BASE_URL", title: "API URL", type: "plain" },
    { key: "MESSAGES", title: "SiliconFlow", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const origin = ctx.settings.get("SILICONFLOW_BASE_URL");
    const currency =
      origin === "https://api.siliconflow.cn" ? "CNY" : origin === "https://api.siliconflow.com" ? "USD" : "";
    if (!currency) {
      throw ctx.fail.apiFailure(
        message("SiliconFlow API origin must be https://api.siliconflow.cn or https://api.siliconflow.com."),
      );
    }
    const response = await ctx.http.get(`${origin}/v1/user/info`, {
      headers: { Accept: "application/json" },
    });
    // The China balance API was retired on 2026-08-14; its balance is read from the console web source instead.
    const retired = message(
      currency === "CNY"
        ? "The SiliconFlow China balance API was retired. Switch SiliconFlow to Web and sign in to cloud.siliconflow.cn."
        : "SiliconFlow refused the balance query. Check the balance in the SiliconFlow console.",
    );
    const checkKey = message("Check your API key in Settings.");
    const tryLater = message("SiliconFlow request failed. Try refreshing later.");
    if (response.status === 410) throw ctx.fail.providerUnavailable(retired);
    if (response.status === 401 || response.status === 403) throw ctx.fail.authenticationExpired(checkKey);
    if (response.status === 429)
      throw ctx.fail.rateLimited(message("SiliconFlow is rate limiting requests. Try again later."));
    if (response.status >= 500) throw ctx.fail.providerUnavailable(tryLater);
    if (response.status !== 200) throw ctx.fail.apiFailure(tryLater);
    const fail = () => {
      throw ctx.fail.parseFailure(
        message("SiliconFlow returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const root = record(decoded);
    if (!root || typeof root.code !== "number" || !Number.isInteger(root.code)) return fail();
    if (root.code === 20092) throw ctx.fail.providerUnavailable(retired);
    if (root.code === 30014) throw ctx.fail.authenticationExpired(checkKey);
    if (root.code !== 20000 || root.status !== true) return fail();
    const data = record(root.data);
    if (!data) return fail();
    const money = (value) => {
      if (typeof value === "number" && Number.isFinite(value)) return value;
      if (typeof value !== "string" || !/^-?(?:\d+|\d+\.\d+)$/.test(value)) return fail();
      const amount = Number(value);
      return Number.isFinite(amount) ? amount : fail();
    };
    const rows = [{ label: "Balance", value: ctx.format.currency(money(data.totalBalance), currency) }];
    if (data.chargeBalance !== undefined && data.chargeBalance !== null) {
      rows.push({ label: "Purchased", value: ctx.format.currency(money(data.chargeBalance), currency) });
    }
    if (data.balance !== undefined && data.balance !== null) {
      rows.push({ label: "Bonus", value: ctx.format.currency(money(data.balance), currency) });
    }
    const status = data.status;
    if (status !== undefined && status !== null) {
      if (typeof status !== "string" || !/^[A-Za-z0-9_-]{1,32}$/.test(status)) return fail();
      if (status !== "normal") rows.push({ label: "Status", value: status });
    }
    return { details: [{ title: "Balance", rows }], dataConfidence: "exact" };
  },
});
