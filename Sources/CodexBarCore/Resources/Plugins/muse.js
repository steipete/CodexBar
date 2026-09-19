function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
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
  id: "muse",
  name: "Muse Code",
  endpoints: ["https://api.meta.ai"],
  auth: { type: "bearer", secret: "MUSE_DEVICE_TOKEN" },
  settings: [{ key: "MUSE_DEVICE_TOKEN", title: "Muse login", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    if (
      !_optionalChain([
        ctx,
        "access",
        (_) => _.settings,
        "access",
        (_2) => _2.getSecret,
        "call",
        (_3) => _3("MUSE_DEVICE_TOKEN"),
        "optionalAccess",
        (_4) => _4.startsWith,
        "call",
        (_5) => _5("dca:"),
      ])
    ) {
      throw ctx.fail.authenticationExpired("Muse Code requires a device-code login. Run `muse login` again.");
    }
    const response = await ctx.http.post("https://api.meta.ai/muse-code/key", {
      body: {},
      headers: { "x-api-version": "1.0.0", "User-Agent": "CodexBar" },
      timeoutSeconds: 15,
    });
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("Muse Code login was rejected. Run `muse login` again.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Muse Code usage requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Muse Code API returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Muse Code API returned HTTP ${response.status}.`);
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Could not parse Muse Code subscription usage: ${field}`);
    };
    const object = (value, field) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    };
    const text = (value, field) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    };
    const reset = (value) => {
      if (value === undefined || value === null) return undefined;
      const seconds = number(value, "resets_at");
      // Match the native countdown boundary; oversized dates must not discard useful quota data.
      if (seconds <= 0 || seconds > 64092211200) return undefined;
      return ctx.date.unixSeconds(seconds);
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected a response object");
    for (const key of ["require_payment", "is_subs_active"]) {
      if (root[key] !== undefined && root[key] !== null && typeof root[key] !== "boolean") return fail(key);
    }
    if (root.require_payment === true) {
      throw ctx.fail.permissionDenied("Muse Code requires a payment method. Finish billing at https://dev.meta.ai");
    }
    if (root.is_subs_active !== true) {
      throw ctx.fail.permissionDenied("No Muse Code subscription is active on this login.");
    }
    const usage = object(root.subs_usage, "missing subs_usage");
    const window = object(usage.window, "missing subscription window");
    const weekly = object(usage.weekly, "missing weekly window");
    const minutes = Math.round(number(window.window_duration_mins, "window_duration_mins"));
    if (!Number.isSafeInteger(minutes) || minutes <= 0) return fail("window_duration_mins");
    const primaryPercent = Math.min(100, Math.max(0, number(window.used_percent, "window.used_percent")));
    const weeklyPercent = Math.min(100, Math.max(0, number(weekly.used_percent, "weekly.used_percent")));
    const plan = text(root.subs_tier_name, "subs_tier_name");
    const rows = [];
    if (plan) rows.push({ label: "Plan", value: plan });
    rows.push({ label: "5 hours", value: `${ctx.format.number(primaryPercent, { maximumFractionDigits: 0 })}%` });
    rows.push({ label: "Weekly", value: `${ctx.format.number(weeklyPercent, { maximumFractionDigits: 0 })}%` });
    return {
      primary: { usedPercent: primaryPercent, windowMinutes: minutes, resetsAt: reset(window.resets_at) },
      secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: reset(weekly.resets_at) },
      details: [{ title: "Muse Code subscription", rows }],
      identity: { email: text(root.user_email, "user_email"), loginMethod: _nullishCoalesce(plan, () => "Muse login") },
      dataConfidence: "exact",
    };
  },
});
