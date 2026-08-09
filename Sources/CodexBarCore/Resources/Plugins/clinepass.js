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

defineProvider({
  id: "clinepass",
  name: "ClinePass",
  endpoints: ["https://api.cline.bot"],
  auth: { type: "bearer", secret: "CLINE_API_KEY" },
  settings: [{ key: "CLINE_API_KEY", title: "API key", type: "secure" }],

  async fetchUsage(ctx) {
    let response;
    try {
      response = await ctx.http.get("https://api.cline.bot/api/v1/users/me/plan/usage-limits", {
        timeoutSeconds: 15,
      });
    } catch (error) {
      throw ctx.fail.networkFailure(
        `ClinePass network error: ${_optionalChain([error, "optionalAccess", (_) => _.message]) || String(error)}`,
      );
    }
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("ClinePass API key was rejected.");
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

    let payload;
    try {
      payload = JSON.parse(response.bodyText);
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
    const limits = data.limits;
    if (!Array.isArray(limits)) {
      throw ctx.fail.parseFailure("Failed to parse ClinePass response: data.limits must be an array");
    }

    const windows = {};
    const windowMinutes = {
      five_hour: 5 * 60,
      weekly: 7 * 24 * 60,
      monthly: 30 * 24 * 60,
    };
    for (const rawLimit of limits) {
      if (!rawLimit || typeof rawLimit !== "object" || Array.isArray(rawLimit)) {
        throw ctx.fail.parseFailure("Failed to parse ClinePass response: limit must be an object");
      }
      const limit = rawLimit;
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
      let resetsAt;
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
      identity: { loginMethod: "API key" },
    };
  },
});
