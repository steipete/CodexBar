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
  id: "cosmic",
  name: "Cosmic AI",
  endpoints: ["https://dapi.cosmicjs.com"],
  auth: { type: "bearer", secret: "COSMIC_TOKEN" },
  settings: [
    { key: "COSMIC_TOKEN", title: "Personal Access Token", type: "secure" },
    { key: "COSMIC_PROJECT_ID", title: "Project ID", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const project = _optionalChain([
      ctx,
      "access",
      (_) => _.settings,
      "access",
      (_2) => _2.get,
      "call",
      (_3) => _3("COSMIC_PROJECT_ID"),
      "optionalAccess",
      (_4) => _4.trim,
      "call",
      (_5) => _5(),
    ]);
    if (!project) throw ctx.fail.missingCredential("Set a Cosmic Project ID in Settings or COSMIC_PROJECT_ID.");
    const response = await ctx.http.get(
      `https://dapi.cosmicjs.com/v3/projects/usage?project_id=${encodeURIComponent(project)}`,
      { headers: { Origin: "https://app.cosmicjs.com" } },
    );
    const message = `Cosmic AI returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) throw ctx.fail.permissionDenied(message);
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("Cosmic AI returned an unrecognized project AI-token usage response.");
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
    const usage = record(
      _optionalChain([
        record,
        "call",
        (_6) => _6(_optionalChain([root, "optionalAccess", (_7) => _7.usage])),
        "optionalAccess",
        (_8) => _8.ai,
      ]),
    );
    const allowance = record(
      _optionalChain([
        record,
        "call",
        (_9) => _9(_optionalChain([root, "optionalAccess", (_10) => _10.plan_info])),
        "optionalAccess",
        (_11) => _11.ai_tokens,
      ]),
    );
    const count = (value) => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const limit = (value) => {
      if (typeof value !== "string") return count(value);
      const match = /^(\d+(?:\.\d+)?)\s*([km]?)$/i.exec(value.trim());
      if (!match) return undefined;
      return count(Number(match[1]) * (match[2].toLowerCase() === "m" ? 1000000 : match[2] ? 1000 : 1));
    };
    const details = [];
    const window = (name, rawUsed, rawLimit) => {
      const used = count(rawUsed);
      const total = limit(rawLimit);
      const rows = [];
      if (used !== undefined) rows.push({ label: "Used", value: ctx.format.number(used) });
      if (total !== undefined) rows.push({ label: "Allowance", value: ctx.format.number(total) });
      else if (typeof rawLimit === "string" && rawLimit.trim()) {
        rows.push({ label: "Allowance", value: /^unlimited$/i.test(rawLimit.trim()) ? "Unlimited" : "Not reported" });
      }
      if (used !== undefined && total !== undefined) {
        rows.push({ label: "Remaining", value: ctx.format.number(Math.max(0, total - used)) });
        if (used > total) rows.push({ label: "Above allowance", value: ctx.format.number(used - total) });
      }
      if (rows.length) details.push({ title: name, rows });
      return used !== undefined && total !== undefined && total > 0 ? { usedPercent: ctx.pct(used, total) } : undefined;
    };
    const primary = window(
      "Input tokens",
      _optionalChain([usage, "optionalAccess", (_12) => _12.input_tokens]),
      _optionalChain([allowance, "optionalAccess", (_13) => _13.max_input]),
    );
    const secondary = window(
      "Output tokens",
      _optionalChain([usage, "optionalAccess", (_14) => _14.output_tokens]),
      _optionalChain([allowance, "optionalAccess", (_15) => _15.max_output]),
    );
    if (!details.length) return fail();
    return { primary, secondary, details, dataConfidence: "exact" };
  },
});
