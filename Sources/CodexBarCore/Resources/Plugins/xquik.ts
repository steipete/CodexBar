type XquikCreditsPayload = {
  balance: unknown;
  lifetime_purchased: unknown;
  lifetime_used: unknown;
  auto_topup_enabled: unknown;
  auto_topup_amount_dollars: unknown;
  auto_topup_threshold: unknown;
};

defineProvider({
  id: "xquik",
  name: "Xquik",
  endpoints: ["https://xquik.com"],
  auth: { type: "x-api-key", secret: "XQUIK_API_KEY" },
  settings: [
    {
      key: "XQUIK_API_KEY",
      title: "API key",
      subtitle: "Xquik account API key. The credits request is non-mutating.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    let response;
    try {
      response = await ctx.http.get("https://xquik.com/api/v1/credits");
    } catch (error) {
      throw ctx.fail.networkFailure(`Xquik network error: ${(error as Error)?.message || String(error)}`);
    }
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("Xquik API key was rejected.");
    }
    if (response.status === 429) {
      throw ctx.fail.rateLimited("Xquik credits API error: HTTP 429");
    }
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable(`Xquik credits API error: HTTP ${response.status}`);
    }
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(`Xquik credits API error: HTTP ${response.status}`);
    }

    let payload: XquikCreditsPayload;
    try {
      payload = JSON.parse(response.bodyText) as XquikCreditsPayload;
    } catch (error) {
      void error;
      throw ctx.fail.parseFailure("Xquik credits response was not valid JSON");
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw ctx.fail.parseFailure("Xquik credits response must be an object");
    }

    function requiredCreditString(value: unknown, field: string): string {
      if (typeof value !== "string") {
        throw ctx.fail.parseFailure(`Xquik ${field} must be an integer string`);
      }
      const trimmed = value.trim();
      if (!/^[0-9]+$/.test(trimmed) || trimmed.length > 84) {
        throw ctx.fail.parseFailure(`Xquik ${field} must be a non-negative integer string of at most 84 digits`);
      }
      return trimmed.replace(/^0+(?=\d)/, "");
    }

    function formatCredits(value: string): string {
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

    const autoTopupRow: { label: string; value: string; secondaryValue?: string } = {
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
