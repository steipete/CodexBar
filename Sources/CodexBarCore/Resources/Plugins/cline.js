function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}

function parseEnvelope(bodyText, ctx, label) {
  let payload;
  try {
    payload = JSON.parse(bodyText);
  } catch (error) {
    void error;
    throw ctx.fail.parseFailure(`Failed to parse Cline ${label} response: response was not valid JSON`);
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw ctx.fail.parseFailure(`Failed to parse Cline ${label} response: expected an object`);
  }
  if (payload.success !== true) {
    const detail = typeof payload.error === "string" && payload.error.trim() ? `: ${payload.error.trim()}` : ".";
    throw ctx.fail.parseFailure(`Failed to parse Cline ${label} response: Response success was false${detail}`);
  }
  return payload.data;
}

function failAuth(ctx) {
  throw ctx.fail.authenticationExpired(
    "Cline credentials were rejected. Check your API key or run `cline auth` to refresh your browser session.",
  );
}

async function getJSON(ctx, url, label) {
  let response;
  try {
    response = await ctx.http.get(url, { timeoutSeconds: 15 });
  } catch (error) {
    throw ctx.fail.networkFailure(
      `Cline network error: ${_optionalChain([error, "optionalAccess", (_) => _.message]) || String(error)}`,
    );
  }
  if (response.status === 401 || response.status === 403) {
    failAuth(ctx);
  }
  if (response.status === 429) {
    throw ctx.fail.rateLimited(`Cline ${label} requests are rate limited.`);
  }
  if (response.status >= 500) {
    throw ctx.fail.providerUnavailable(`Cline API error: HTTP ${response.status}`);
  }
  if (response.status !== 200) {
    throw ctx.fail.apiFailure(`Cline API error: HTTP ${response.status}`);
  }
  return response;
}

defineProvider({
  id: "cline",
  name: "Cline",
  endpoints: ["https://api.cline.bot"],
  auth: { type: "bearer", secret: "CLINE_API_KEY" },
  settings: [
    { key: "CLINE_API_KEY", title: "API key", type: "secure" },
    { key: "CLINE_AUTH_SOURCE", title: "Auth source", type: "plain" },
  ],

  async fetchUsage(ctx) {
    const meResponse = await getJSON(ctx, "https://api.cline.bot/api/v1/users/me", "account");
    const meData = parseEnvelope(meResponse.bodyText, ctx, "account");
    if (!meData || typeof meData !== "object" || Array.isArray(meData)) {
      throw ctx.fail.parseFailure("Failed to parse Cline account response: data must be an object");
    }
    if (typeof meData.id !== "string" || !meData.id.trim()) {
      throw ctx.fail.parseFailure("Failed to parse Cline account response: data.id must be a non-empty string");
    }
    const userId = meData.id.trim();
    const email = typeof meData.email === "string" && meData.email.trim() ? meData.email.trim() : undefined;

    const balanceResponse = await getJSON(
      ctx,
      `https://api.cline.bot/api/v1/users/${encodeURIComponent(userId)}/balance`,
      "balance",
    );
    const balanceData = parseEnvelope(balanceResponse.bodyText, ctx, "balance");
    if (!balanceData || typeof balanceData !== "object" || Array.isArray(balanceData)) {
      throw ctx.fail.parseFailure("Failed to parse Cline balance response: data must be an object");
    }
    if (typeof balanceData.balance !== "number" || !Number.isFinite(balanceData.balance)) {
      throw ctx.fail.parseFailure("Failed to parse Cline balance response: data.balance must be a number");
    }
    // Balances are reported in cents (see Cline getUserCredits: currentBalance = balance / 100).
    const dollars = balanceData.balance / 100;

    return {
      details: [
        {
          title: "Cline credits",
          rows: [{ label: "Available balance", value: ctx.format.usd(dollars) }],
        },
      ],
      identity: {
        email,
        loginMethod: ctx.settings.get("CLINE_AUTH_SOURCE") === "oauth" ? "Browser" : "API key",
      },
      dataConfidence: "exact",
    };
  },
});
