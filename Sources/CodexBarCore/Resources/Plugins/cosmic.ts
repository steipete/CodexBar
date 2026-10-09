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
    const project = ctx.settings.get("COSMIC_PROJECT_ID")?.trim();
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
    const fail = (): never => {
      throw ctx.fail.parseFailure("Cosmic AI returned an unrecognized project AI-token usage response.");
    };
    const record = (value: unknown): Record<string, unknown> | undefined =>
      value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
    let decoded: unknown;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const root = record(decoded);
    const usage = record(record(root?.usage)?.ai);
    const allowance = record(record(root?.plan_info)?.ai_tokens);
    const count = (value: unknown): number | undefined => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const limit = (value: unknown): number | undefined => {
      if (typeof value !== "string") return count(value);
      const match = /^(\d+(?:\.\d+)?)\s*([km]?)$/i.exec(value.trim());
      if (!match) return undefined;
      return count(Number(match[1]) * (match[2].toLowerCase() === "m" ? 1000000 : match[2] ? 1000 : 1));
    };
    const details: CodexBarDetailSection[] = [];
    const window = (name: string, rawUsed: unknown, rawLimit: unknown) => {
      const used = count(rawUsed);
      const total = limit(rawLimit);
      const rows: CodexBarDetailRow[] = [];
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
    const primary = window("Input tokens", usage?.input_tokens, allowance?.max_input);
    const secondary = window("Output tokens", usage?.output_tokens, allowance?.max_output);
    if (!details.length) return fail();
    return { primary, secondary, details, dataConfidence: "exact" };
  },
});
