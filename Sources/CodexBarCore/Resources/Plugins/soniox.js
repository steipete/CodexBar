defineProvider({
  id: "soniox",
  name: "Soniox",
  endpoints: ["https://api.soniox.com"],
  auth: { type: "bearer", secret: "SONIOX_ORG_API_KEY" },
  settings: [{ key: "SONIOX_ORG_API_KEY", title: "Organization API key", type: "secure" }],
  async fetchUsage(ctx) {
    const invalid = (field) => {
      throw ctx.fail.parseFailure(
        `Soniox returned invalid billing data: ${field}. Refresh to try again. If this persists, update CodexBar or report the issue.`,
      );
    };
    const money = (value, field, signed = false) => {
      if (typeof value !== "string" || !/^-?\d+(?:\.\d+)?$/.test(value.trim())) return invalid(field);
      const amount = Number(value);
      if (!Number.isFinite(amount) || (!signed && amount < 0)) return invalid(field);
      return amount;
    };
    const get = async (path) => {
      const response = await ctx.http.get(`https://api.soniox.com/v1/organization/${path}`);
      if (response.status === 401) {
        throw ctx.fail.authenticationExpired(
          "Soniox rejected the organization API key. Check that it has not been revoked.",
        );
      }
      if (response.status === 403) {
        throw ctx.fail.permissionDenied(
          "Soniox requires an organization API key with Balance and spend and Usage and limits access. Project API keys are not supported.",
        );
      }
      if (response.status === 429) {
        throw ctx.fail.rateLimited("Soniox rate limit reached (HTTP 429). Wait a moment, then refresh.");
      }
      if (response.status >= 500) {
        throw ctx.fail.providerUnavailable(
          `Soniox is temporarily unavailable (HTTP ${response.status}). Try again later or check https://status.soniox.com.`,
        );
      }
      if (response.status !== 200) {
        throw ctx.fail.apiFailure(
          `Soniox billing request failed (HTTP ${response.status}). Refresh to try again. If this persists, update CodexBar or report the issue.`,
        );
      }
      let data;
      try {
        data = JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return invalid("invalid JSON");
      }
      if (!data || typeof data !== "object" || Array.isArray(data)) return invalid("expected an object");
      return data;
    };

    const billing = await get("balance");
    const available = money(billing.available_balance_usd, "available_balance_usd", true);
    if (typeof billing.invoice_billing_enabled !== "boolean") return invalid("invoice_billing_enabled");
    const monthly = await get("usage/monthly");
    const used = money(monthly.usage_usd, "usage_usd");
    const budget = money(monthly.monthly_budget_usd, "monthly_budget_usd");
    if (typeof monthly.month !== "string" || !/^\d{4}-(0[1-9]|1[0-2])$/.test(monthly.month)) {
      return invalid("month");
    }
    const resetsAt = new Date(`${monthly.month}-01T00:00:00Z`);
    resetsAt.setUTCMonth(resetsAt.getUTCMonth() + 1);

    return {
      primary:
        budget > 0
          ? {
              usedPercent: ctx.pct(used, budget),
              resetsAt,
              resetDescription: `${ctx.format.usd(used)} / ${ctx.format.usd(budget)}`,
            }
          : undefined,
      cost: {
        used,
        limit: budget,
        currency: "USD",
        period: "This month",
        resetsAt,
        balance: billing.invoice_billing_enabled ? undefined : available,
      },
      details: [
        {
          title: "Billing",
          rows: [
            { label: billing.invoice_billing_enabled ? "Invoice billing" : "Prepaid", value: "USD" },
            ...(budget === 0 ? [{ label: "Monthly budget", value: ctx.format.usd(budget) }] : []),
          ],
        },
      ],
      dataConfidence: "exact",
    };
  },
});
