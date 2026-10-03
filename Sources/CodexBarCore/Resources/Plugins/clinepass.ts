type ClinePassLimit = {
  type?: unknown;
  percentUsed?: unknown;
  resetsAt?: unknown;
};

type ClinePassPayload = {
  success?: unknown;
  data?: unknown;
};

type ClineAccount = {
  id?: unknown;
};

type ClineBalance = {
  balance?: unknown;
};

defineProvider({
  id: "clinepass",
  name: "ClinePass",
  endpoints: ["https://api.cline.bot"],
  auth: { type: "bearer", secret: "CLINE_API_KEY" },
  settings: [
    { key: "CLINE_API_KEY", title: "API key", type: "secure" },
    { key: "CLINE_AUTH_SOURCE", title: "Auth source", type: "plain" },
  ],

  async fetchUsage(ctx) {
    let response;
    try {
      response = await ctx.http.get("https://api.cline.bot/api/v1/users/me/plan/usage-limits", {
        timeoutSeconds: 15,
      });
    } catch (error) {
      if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
      throw ctx.fail.networkFailure(`ClinePass network error: ${(error as Error)?.message || String(error)}`);
    }
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired(
        "ClinePass credentials were rejected. Check your API key or run `cline auth` to refresh your browser session.",
      );
    }
    if (response.status === 429) {
      throw ctx.fail.rateLimited("ClinePass API error: HTTP 429");
    }
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable(`ClinePass API error: HTTP ${response.status}`);
    }
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(`ClinePass API error: HTTP ${response.status}`);
    }

    let payload: ClinePassPayload;
    try {
      payload = JSON.parse(response.bodyText) as ClinePassPayload;
    } catch (error) {
      void error;
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: response was not valid JSON");
    }
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: expected an object");
    }
    if (payload.success !== true) {
      if (payload.success === false) {
        throw ctx.fail.parseFailure("Failed to parse ClinePass response: Response success was false.");
      }
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: success must be a boolean");
    }
    const data = payload.data;
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: data must be an object");
    }
    const limits = (data as { limits?: unknown }).limits;
    if (!Array.isArray(limits)) {
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: data.limits must be an array");
    }

    const windows: Record<string, CodexBarRateWindow> = {};
    const windowMinutes: Record<string, number> = {
      five_hour: 5 * 60,
      weekly: 7 * 24 * 60,
      monthly: 30 * 24 * 60,
    };
    for (const rawLimit of limits) {
      if (!rawLimit || typeof rawLimit !== "object" || Array.isArray(rawLimit)) {
        throw ctx.fail.parseFailure("Failed to parse ClinePass response: limit must be an object");
      }
      const limit = rawLimit as ClinePassLimit;
      if (typeof limit.type !== "string") {
        throw ctx.fail.parseFailure("Failed to parse ClinePass response: limit type must be a string");
      }
      const minutes = windowMinutes[limit.type];
      if (minutes === undefined) continue;
      if (typeof limit.percentUsed !== "number" || !Number.isFinite(limit.percentUsed)) {
        throw ctx.fail.parseFailure(
          `Failed to parse ClinePass response: percentUsed must be a number for ${limit.type}.`,
        );
      }
      let resetsAt: Date | undefined;
      if (limit.resetsAt !== null && limit.resetsAt !== undefined) {
        if (typeof limit.resetsAt !== "string") {
          throw ctx.fail.parseFailure(
            `Failed to parse ClinePass response: Invalid resetsAt timestamp for ${limit.type}.`,
          );
        }
        try {
          resetsAt = ctx.date.iso(limit.resetsAt);
        } catch (error) {
          void error;
          throw ctx.fail.parseFailure(
            `Failed to parse ClinePass response: Invalid resetsAt timestamp for ${limit.type}.`,
          );
        }
      }
      windows[limit.type] = {
        usedPercent: Math.min(100, Math.max(0, limit.percentUsed)),
        windowMinutes: minutes,
        resetsAt,
      };
    }

    return {
      primary: windows.five_hour,
      secondary: windows.weekly,
      tertiary: windows.monthly,
      identity: { loginMethod: ctx.settings.get("CLINE_AUTH_SOURCE") === "oauth" ? "Browser" : "API key" },
      details: await payAsYouGoBalance(ctx),
    };
  },
});

async function clineGet(ctx: CodexBarPluginContext, url: string, label: string): Promise<string> {
  let response;
  try {
    response = await ctx.http.get(url, { timeoutSeconds: 15 });
  } catch (error) {
    if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
    throw ctx.fail.networkFailure(`Cline ${label} network error: ${(error as Error)?.message || String(error)}`);
  }
  if (response.status === 401 || response.status === 403) {
    throw ctx.fail.authenticationExpired(
      "Cline credentials were rejected. Check your API key or run `cline auth` to refresh your browser session.",
    );
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
  return response.bodyText;
}

// Cline's account service unwraps `{success, data}` when success is a boolean
// and returns the parsed object directly otherwise; accept either shape.
function unwrapClineData(bodyText: string, ctx: CodexBarPluginContext, label: string): unknown {
  let parsed: unknown;
  try {
    parsed = JSON.parse(bodyText);
  } catch (error) {
    void error;
    throw ctx.fail.parseFailure(`Failed to parse Cline ${label} response: response was not valid JSON`);
  }
  if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
    const success = (parsed as ClinePassPayload).success;
    if (typeof success === "boolean") {
      if (!success) {
        throw ctx.fail.parseFailure(`Failed to parse Cline ${label} response: Response success was false.`);
      }
      return (parsed as ClinePassPayload).data;
    }
  }
  return parsed;
}

// Best-effort pay-as-you-go balance for the same Cline account. Never fails the
// subscription windows above; cancellation still propagates.
async function payAsYouGoBalance(ctx: CodexBarPluginContext): Promise<CodexBarDetailSection[] | undefined> {
  try {
    const me = unwrapClineData(
      await clineGet(ctx, "https://api.cline.bot/api/v1/users/me", "account"),
      ctx,
      "account",
    ) as ClineAccount;
    if (!me || typeof me !== "object" || Array.isArray(me) || typeof me.id !== "string" || !me.id.trim()) {
      throw ctx.fail.parseFailure("Failed to parse Cline account response: data.id must be a non-empty string");
    }
    const userId = me.id.trim();
    const raw = unwrapClineData(
      await clineGet(
        ctx,
        `https://api.cline.bot/api/v1/users/${encodeURIComponent(userId)}/balance`,
        "balance",
      ),
      ctx,
      "balance",
    ) as ClineBalance;
    if (
      !raw ||
      typeof raw !== "object" ||
      Array.isArray(raw) ||
      typeof raw.balance !== "number" ||
      !Number.isFinite(raw.balance)
    ) {
      throw ctx.fail.parseFailure("Failed to parse Cline balance response: data.balance must be a number");
    }
    // Balances are reported in cents (Cline displays balance / 100).
    return [
      {
        title: "Cline credits",
        rows: [{ label: "Available balance", value: ctx.format.usd(raw.balance / 100) }],
      },
    ];
  } catch (error) {
    if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
    return undefined;
  }
}
