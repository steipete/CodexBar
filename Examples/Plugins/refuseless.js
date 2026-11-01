defineProvider({
  id: "refuseless",
  name: "Refuseless",
  endpoints: ["https://api.refuseless.com"],
  auth: { type: "bearer", secret: "REFUSELESS_API_KEY" },
  settings: [
    {
      key: "REFUSELESS_API_KEY",
      title: "API key",
      subtitle: "Create an API key in your Refuseless account.",
      type: "secure",
    },
  ],
  capabilities: ["http-status"],

  async fetchUsage(ctx) {
    const fail = () => {
      throw ctx.fail.parseFailure(
        "Refuseless returned an unrecognized credit response. Update the plugin and refresh; contact Refuseless support if it persists.",
      );
    };
    const response = await ctx.http.get("https://api.refuseless.com/v1/credits");
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired("Refuseless rejected the API key. Check it in Settings.");
    }
    if (response.status === 429) {
      throw ctx.fail.rateLimited("Refuseless credits are rate limited. Try refreshing later.");
    }
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable("Refuseless billing is unavailable. Try refreshing later.");
    }
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(
        `Refuseless credits request returned HTTP ${response.status}. Update the plugin and retry; contact Refuseless support if it persists.`,
      );
    }

    let credits;
    try {
      credits = JSON.parse(response.bodyText);
    } catch {
      return fail();
    }
    if (!credits || typeof credits !== "object" || Array.isArray(credits)) {
      return fail();
    }
    if (credits.object !== "credits" || credits.unit !== "usd") {
      return fail();
    }

    const amount = (value) => {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail();
      return value;
    };
    const balance = amount(credits.balance);
    const reserved = amount(credits.reserved);
    const available = amount(credits.available);
    const keyLimit = credits.key_limit === null ? null : amount(credits.key_limit);
    const updatedAt = amount(credits.updated_at);
    if (!Number.isSafeInteger(updatedAt)) return fail();
    const updatedAtDate = new Date(updatedAt * 1000);
    if (!Number.isFinite(updatedAtDate.getTime())) return fail();

    const usd = (value) => {
      const sign = value < 0 ? "-" : "";
      const formatted = ctx.format.number(Math.abs(value), {
        minimumFractionDigits: 2,
        maximumFractionDigits: 6,
      });
      return `${sign}$${formatted}`;
    };
    return {
      details: [
        {
          title: "Credits",
          rows: [
            { label: "Available", value: usd(available), secondaryValue: "Available to reserve for a new request" },
            { label: "Balance", value: usd(balance), secondaryValue: "Includes in-flight requests" },
            { label: "Reserved", value: usd(reserved), secondaryValue: "Held for in-flight requests" },
            {
              label: "Budget remaining",
              value: keyLimit === null ? "No key budget" : usd(keyLimit),
              secondaryValue: keyLimit === null ? undefined : "Key or workspace budget remaining",
            },
            { label: "Updated", value: updatedAtDate.toISOString() },
          ],
        },
      ],
      dataConfidence: "exact",
    };
  },
});
