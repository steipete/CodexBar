defineProvider({
  id: "perplexity",
  name: "Perplexity",
  endpoints: ["https://www.perplexity.ai"],
  settings: [],
  capabilities: ["browser-cookies"],
  cookieDomains: ["www.perplexity.ai"],
  async fetchUsage(ctx) {
    const cookie = await ctx.browser.cookieHeader("www.perplexity.ai");
    const response = await ctx.http.getJSON(
      "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default",
      {
        headers: {
          Cookie: cookie,
          Origin: "https://www.perplexity.ai",
          Referer: "https://www.perplexity.ai/account/usage",
        },
      },
    );
    if (response.status !== 200) throw new Error(`Perplexity API error: HTTP ${response.status}`);
    const data = response.json;
    const grants = data.credit_grants || data.creditGrants || [];
    const now = Date.now() / 1000;
    const amount = (grant) => Number(grant.amount_cents ?? grant.amountCents ?? 0);
    const recurring = grants
      .filter((grant) => grant.type === "recurring")
      .reduce((sum, grant) => sum + amount(grant), 0);
    const promoGrants = grants.filter(
      (grant) => grant.type === "promotional" && Number(grant.expires_at_ts ?? grant.expiresAtTs ?? Infinity) > now,
    );
    const promo = promoGrants.reduce((sum, grant) => sum + amount(grant), 0);
    const purchasedGrants = grants
      .filter((grant) => grant.type === "purchased")
      .reduce((sum, grant) => sum + amount(grant), 0);
    const purchased = Math.max(
      purchasedGrants,
      Number(data.current_period_purchased_cents ?? data.currentPeriodPurchasedCents ?? 0),
    );
    let remaining = Number(data.total_usage_cents ?? data.totalUsageCents ?? 0);
    const recurringUsed = Math.min(remaining, recurring);
    remaining -= recurringUsed;
    const purchasedUsed = Math.min(remaining, purchased);
    remaining -= purchasedUsed;
    const promoUsed = Math.min(remaining, promo);
    const renewal = Number(data.renewal_date_ts ?? data.renewalDateTs);
    const promoExpiry = promoGrants
      .map((grant) => Number(grant.expires_at_ts ?? grant.expiresAtTs))
      .filter(Number.isFinite)
      .sort()[0];
    const integer = (value) => String(Math.round(value));
    const promoDescription = `${integer(promoUsed)}/${integer(promo)} bonus`;
    return {
      primary:
        recurring > 0
          ? {
              usedPercent: ctx.pct(recurringUsed, recurring),
              resetsAt: ctx.date.unixSeconds(renewal),
              resetDescription: `${integer(recurringUsed)}/${integer(recurring)} credits`,
            }
          : promo > 0 || purchased > 0
            ? undefined
            : {
                usedPercent: 100,
                resetsAt: ctx.date.unixSeconds(renewal),
                resetDescription: "0/0 credits",
              },
      secondary: {
        usedPercent: promo > 0 ? ctx.pct(promoUsed, promo) : 100,
        resetDescription: promoExpiry
          ? `${promoDescription} · exp. ${ctx.format.monthDay(new Date(promoExpiry * 1000))}`
          : promoDescription,
      },
      tertiary: {
        usedPercent: purchased > 0 ? ctx.pct(purchasedUsed, purchased) : 100,
        resetDescription: `${integer(purchasedUsed)}/${integer(purchased)} credits`,
      },
      identity: { loginMethod: recurring <= 0 ? undefined : recurring < 5000 ? "Pro" : "Max" },
    };
  },
});
