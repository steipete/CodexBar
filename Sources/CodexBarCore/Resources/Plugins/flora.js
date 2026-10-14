defineProvider({
  id: "flora",
  name: "FLORA",
  endpoints: ["https://app.flora.ai"],
  auth: { type: "bearer", secret: "FLORA_API_KEY" },
  settings: [
    { key: "FLORA_API_KEY", title: "FLORA API key", type: "secure" },
    { key: "FLORA_WORKSPACE_ID", title: "Workspace ID", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    // Workspace listing can be empty without read permission, so billing uses an explicit workspace ID.
    const workspace = (ctx.settings.get("FLORA_WORKSPACE_ID") || "").trim();
    if (!workspace) {
      throw ctx.fail.missingCredential("Set the FLORA workspace ID (ws_…) in Settings or FLORA_WORKSPACE_ID.");
    }
    if (!/^ws_[A-Za-z0-9]+$/.test(workspace))
      throw ctx.fail.missingCredential("FLORA workspace ID must look like ws_….");

    const now = ctx.date.now();
    const pad = (value) => String(value).padStart(2, "0");
    const month = `${now.getUTCFullYear()}-${pad(now.getUTCMonth() + 1)}`;
    const today = `${month}-${pad(now.getUTCDate())}`;
    const response = await ctx.http.get(
      `https://app.flora.ai/api/v1/workspaces/${workspace}/usage?start_date=${month}-01&end_date=${today}`,
    );
    const message = `FLORA returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) {
      throw ctx.fail.permissionDenied("FLORA rejected the key: it needs billing permission on this workspace.");
    }
    if (response.status === 404) throw ctx.fail.apiFailure("FLORA did not find this workspace ID.");
    if (response.status === 429) {
      const delay = Number(response.headers["retry-after"] ?? 1);
      throw ctx.fail.rateLimited(message, {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    function fail() {
      throw ctx.fail.parseFailure("FLORA returned an unrecognized workspace usage response.");
    }
    const finite = (value) => typeof value === "number" && Number.isFinite(value);
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : null);
    let data;
    try {
      data = record(JSON.parse(response.bodyText));
    } catch {
      return fail();
    }
    if (!data || !finite(data.available_cost)) return fail();
    const currency = typeof data.currency === "string" && /^[A-Z]{3}$/.test(data.currency) ? data.currency : "USD";
    const money = (value) => ctx.format.currency(value, currency);
    const scope = { workspace: "Workspace pool", caller: "Your allowance" }[data.balance_scope];
    const rows = [{ label: "Available", value: money(data.available_cost), secondaryValue: scope ?? null }];

    const limit = record(data.member_limit);
    if (data.balance_scope === "caller" && limit && finite(limit.limit_cost)) {
      const period = { month: "Monthly", all_time: "All time" }[limit.period];
      rows.push({ label: "Member limit", value: money(limit.limit_cost), secondaryValue: period ?? null });
    }

    const spend = record(data.spend);
    if (spend && spend.status === "available") {
      if (!finite(spend.total_cost)) return fail();
      rows.push({ label: "Spent this month", value: money(spend.total_cost) });
      if (Number.isInteger(spend.classified_runs) && spend.classified_runs >= 0) {
        rows.push({ label: "Runs this month", value: ctx.format.number(spend.classified_runs) });
      }
    } else if (spend && spend.status === "unavailable") {
      const reason = {
        entitlement_missing: "Plan has no usage reporting",
        permission_missing: "Needs billing permission",
        summary_unavailable: "Totals not computed; try again",
      }[spend.reason];
      rows.push({ label: "Spent this month", value: "Unavailable", secondaryValue: reason ?? "Not reported" });
    }

    return {
      details: [{ title: "Workspace balance", rows }],
      identity: { loginMethod: "API key" },
      dataConfidence: "exact",
    };
  },
});
