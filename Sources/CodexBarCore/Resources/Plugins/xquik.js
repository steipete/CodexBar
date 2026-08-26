defineProvider({
  id: "xquik",
  name: "Xquik",
  endpoints: ["https://xquik.com"],
  auth: { type: "x-api-key", secret: "XQUIK_API_KEY" },
  settings: [
    {
      key: "XQUIK_API_KEY",
      title: "API key",
      subtitle: "Xquik API key used for the read-only credit endpoint.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://xquik.com/api/v1/credits");
    const payload = response.json;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw ctx.fail.parseFailure("Xquik credits response must be an object");
    }

    function requiredCreditString(value, field) {
      if (typeof value !== "string") {
        throw ctx.fail.parseFailure(`Xquik ${field} must be an integer string`);
      }
      const trimmed = value.trim();
      if (!/^[0-9]+$/.test(trimmed) || trimmed.length > 84) {
        throw ctx.fail.parseFailure(`Xquik ${field} must be a non-negative integer string of at most 84 digits`);
      }
      return trimmed.replace(/^0+(?=\d)/, "");
    }

    function formatCredits(value) {
      let formatted = "";
      for (let index = 0; index < value.length; index += 1) {
        if (index > 0 && (value.length - index) % 3 === 0) formatted += ",";
        formatted += value[index];
      }
      return `${formatted} credits`;
    }

    const balance = requiredCreditString(payload.balance, "balance");
    const lifetimePurchased = requiredCreditString(payload.lifetime_purchased, "lifetime_purchased");
    const lifetimeUsed = requiredCreditString(payload.lifetime_used, "lifetime_used");
    const autoTopupThreshold = requiredCreditString(payload.auto_topup_threshold, "auto_topup_threshold");
    if (typeof payload.auto_topup_enabled !== "boolean") {
      throw ctx.fail.parseFailure("Xquik auto_topup_enabled must be a boolean");
    }
    if (
      typeof payload.auto_topup_amount_dollars !== "number" ||
      !Number.isFinite(payload.auto_topup_amount_dollars) ||
      payload.auto_topup_amount_dollars < 0
    ) {
      throw ctx.fail.parseFailure("Xquik auto_topup_amount_dollars must be a non-negative number");
    }

    const autoTopupRow = {
      label: "Automatic top-up",
      value: payload.auto_topup_enabled ? "Enabled" : "Disabled",
    };
    if (payload.auto_topup_enabled) {
      autoTopupRow.secondaryValue = `${ctx.format.usd(payload.auto_topup_amount_dollars)} at ${formatCredits(autoTopupThreshold)}`;
    }

    return {
      primary: {
        usedPercent: balance === "0" ? 100 : 0,
        resetDescription: `${formatCredits(balance)} available`,
      },
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
      details: [
        {
          title: "Credit usage",
          rows: [
            { label: "Available", value: formatCredits(balance) },
            { label: "Lifetime used", value: formatCredits(lifetimeUsed) },
            { label: "Lifetime purchased", value: formatCredits(lifetimePurchased) },
            autoTopupRow,
          ],
        },
      ],
    };
  },
});
