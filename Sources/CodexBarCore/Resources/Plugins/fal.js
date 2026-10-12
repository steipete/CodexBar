defineProvider({
  id: "fal",
  name: "fal",
  endpoints: ["https://api.fal.ai"],
  auth: { type: "authorization-scheme", scheme: "Key", secret: "FAL_KEY" },
  settings: [{ key: "FAL_KEY", title: "fal API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const response = await ctx.http.get("https://api.fal.ai/v1/account/billing?expand=credits", {
      retryPolicy: "transientIdempotent",
    });
    const message = `fal returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) {
      throw ctx.fail.permissionDenied(
        "fal rejected the key: billing needs the billing:usage:read permission (BILLING, READONLY or FULL preset).",
      );
    }
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    let data;
    try {
      data = JSON.parse(response.bodyText);
    } catch {
      throw ctx.fail.parseFailure("fal returned a non-JSON billing response.");
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw ctx.fail.parseFailure("fal returned an unrecognized billing response.");
    }
    const credits = data.credits;
    if (!credits || typeof credits !== "object" || Array.isArray(credits)) {
      // A successful response without credits cannot establish a balance.
      throw ctx.fail.providerUnavailable("fal did not return the credit balance this time. Try Refresh in a moment.");
    }
    const raw = credits.current_balance;
    const balance =
      typeof raw === "string" && /^\s*-?\d+(?:\.\d+)?\s*$/.test(raw)
        ? Number(raw)
        : typeof raw === "number"
          ? raw
          : NaN;
    if (!Number.isFinite(balance)) {
      const kind = raw === null ? "null" : Array.isArray(raw) ? "array" : typeof raw;
      throw ctx.fail.parseFailure(`fal returned an unrecognized credit balance (${kind}).`);
    }
    const currency =
      typeof credits.currency === "string" && /^[A-Z]{3}$/.test(credits.currency) ? credits.currency : "USD";
    const identity = { loginMethod: "API key" };
    if (typeof data.username === "string" && data.username.trim()) identity.organization = data.username.trim();
    return {
      details: [
        {
          title: "Account balance",
          rows: [{ label: "Credit balance", value: ctx.format.currency(balance, currency) }],
        },
      ],
      identity,
      dataConfidence: "exact",
    };
  },
});
