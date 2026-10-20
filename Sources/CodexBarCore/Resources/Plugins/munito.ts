defineProvider({
  id: "munito",
  name: "Munito",
  endpoints: ["https://api.munito.ai"],
  auth: { type: "bearer", secret: "MUNITO_API_KEY" },
  settings: [{ key: "MUNITO_API_KEY", title: "Munito admin API key", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const base = "https://api.munito.ai/admin/v1";
    const response = await ctx.http.getWithOptional(`${base}/limits`, `${base}/organization`, {
      retryPolicy: "transientIdempotent",
    });
    const message = `Munito returned HTTP ${response.status}.`;
    if (response.status === 401) throw ctx.fail.authenticationExpired(message);
    if (response.status === 403) {
      throw ctx.fail.permissionDenied(
        "Munito rejected the key: the Admin API needs a key with Read account data permission.",
      );
    }
    // The native transientIdempotent retry already honors Retry-After; an explicit retry hint
    // here would schedule a second, outer retry cycle (docs/plugins.md plugin retry contract).
    if (response.status === 429) throw ctx.fail.rateLimited(message);
    if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
    if (response.status !== 200) throw ctx.fail.apiFailure(message);
    const fail = () => {
      throw ctx.fail.parseFailure("Munito returned an unrecognized spend limits response.");
    };
    let root: unknown;
    try {
      root = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    if (!root || typeof root !== "object" || Array.isArray(root)) return fail();
    const body = root as Record<string, unknown>;
    const text = (value: unknown): string | undefined =>
      typeof value === "string" && value.trim() ? value.trim() : undefined;
    const money = (value: unknown, field: string): number => {
      const number =
        typeof value === "number"
          ? value
          : typeof value === "string" && /^\s*-?\d+(?:\.\d+)?\s*$/.test(value)
            ? Number(value)
            : NaN;
      if (!Number.isFinite(number) || number < 0) {
        throw ctx.fail.parseFailure(`Munito returned an unusable ${field}.`);
      }
      return number;
    };
    const limit = (value: unknown, field: string): number | undefined =>
      value == null ? undefined : money(value, field);
    if (!Array.isArray(body.periods)) return fail();
    type Period = {
      period: string;
      spent: number;
      limit: number | undefined;
      organizationLimit: number | undefined;
      accountLimit: number | undefined;
      stoppedUntil: Date | undefined;
    };
    const periods: Period[] = [];
    for (const raw of body.periods) {
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) return fail();
      const entry = raw as Record<string, unknown>;
      const kind = text(entry.period);
      if (kind !== "day" && kind !== "month") continue;
      const stopped = text(entry.stopped_until);
      let stoppedUntil: Date | undefined;
      if (stopped) {
        if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(stopped)) return fail();
        try {
          stoppedUntil = ctx.date.iso(stopped);
        } catch (error) {
          void error;
          return fail();
        }
      }
      periods.push({
        period: kind,
        spent: money(entry.spent_usd, `${kind} spend`),
        limit: limit(entry.limit_usd, `${kind} limit`),
        organizationLimit: limit(entry.organization_limit_usd, `${kind} organization limit`),
        accountLimit: limit(entry.account_limit_usd, `${kind} account limit`),
        stoppedUntil,
      });
    }
    const find = (kind: string): Period | undefined => periods.find((entry) => entry.period === kind);
    const day = find("day");
    const month = find("month");
    // The organization is a best-effort companion read; spend and limits stay authoritative.
    let organization: Record<string, unknown> | undefined;
    if (response.optional && response.optional.status === 200) {
      try {
        const parsed: unknown = JSON.parse(response.optional.bodyText);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed))
          organization = parsed as Record<string, unknown>;
      } catch (error) {
        void error;
      }
    }
    const usageTier = text(body.usage_tier) ?? (organization ? text(organization.usage_tier) : undefined);
    const rows: { label: string; value: string; progress?: number; usageValue?: number }[] = [];
    const moneyRow = (label: string, entry: Period): void => {
      const spend = ctx.format.usd(entry.spent);
      rows.push({
        label,
        value: entry.limit && entry.limit > 0 ? `${spend} of ${ctx.format.usd(entry.limit)}` : spend,
        progress: entry.limit && entry.limit > 0 ? Math.min(1, entry.spent / entry.limit) : undefined,
        usageValue: entry.spent,
      });
      const organizational =
        entry.organizationLimit != null && entry.organizationLimit > 0 && entry.organizationLimit !== entry.limit
          ? entry.organizationLimit
          : undefined;
      const account =
        entry.accountLimit != null && entry.accountLimit > 0 && entry.accountLimit !== entry.limit
          ? entry.accountLimit
          : undefined;
      if (organizational != null) {
        rows.push({ label: `${label} organization limit`, value: ctx.format.usd(organizational) });
      }
      if (account != null) {
        rows.push({ label: `${label} account limit`, value: ctx.format.usd(account) });
      }
      if (entry.stoppedUntil) rows.push({ label: `${label} stopped until`, value: entry.stoppedUntil.toISOString() });
    };
    if (day) moneyRow("Today", day);
    if (month) moneyRow("This month", month);
    if (usageTier) rows.push({ label: "Usage tier", value: usageTier });
    const details: Array<{
      title: string;
      rows: Array<{ label: string; value: string; progress?: number; usageValue?: number }>;
    }> = [];
    if (rows.length) details.push({ title: "Spend limits", rows });
    const organizationRows: Array<{ label: string; value: string }> = [];
    if (organization) {
      const status = text(organization.status);
      if (status) organizationRows.push({ label: "Status", value: status.charAt(0).toUpperCase() + status.slice(1) });
      const region = text(organization.data_region);
      if (region) organizationRows.push({ label: "Data region", value: region });
      if (organizationRows.length) details.push({ title: "Organization", rows: organizationRows });
    }
    // The identity keeps the card visible even when every period is temporarily absent;
    // spend windows and cost appear only while Munito reports them.
    return {
      primary:
        day && day.limit && day.limit > 0 ? { usedPercent: ctx.pct(day.spent, day.limit), windowMinutes: 1440 } : null,
      secondary: month && month.limit && month.limit > 0 ? { usedPercent: ctx.pct(month.spent, month.limit) } : null,
      cost:
        month != null || day != null
          ? {
              used: (month ?? day)!.spent,
              limit: (month ?? day)!.limit ?? 0,
              currency: "USD",
              period: month ? "This month" : "Today",
            }
          : null,
      details,
      identity: {
        organization: organization ? text(organization.name) : undefined,
        accountID: organization ? text(organization.id) : undefined,
        loginMethod: "Admin API key",
      },
      dataConfidence: "exact",
    };
  },
});
