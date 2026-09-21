defineProvider({
  id: "nous",
  name: "Nous Portal",
  capabilities: ["http-status"],
  endpoints: [{ setting: "PORTAL_URL", policy: "https" }],
  auth: { type: "bearer", secret: "NOUS_PORTAL_ACCESS_TOKEN" },
  settings: [
    { key: "PORTAL_URL", title: "Portal URL", type: "plain" },
    { key: "NOUS_PORTAL_ACCESS_TOKEN", title: "Access token", type: "secure" },
  ],
  async fetchUsage(ctx) {
    const portal = ctx.settings.get("PORTAL_URL");
    const response = await ctx.http.get(`${portal}/api/oauth/account`, { timeoutSeconds: 15 });
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired(
        "Nous Portal rejected the access token. Run `hermes` to refresh your Hermes Agent login.",
      );
    }
    if (response.status === 403) throw ctx.fail.permissionDenied("Nous Portal denied account access.");
    if (response.status === 429) throw ctx.fail.rateLimited("Nous Portal account requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Nous Portal API error: HTTP ${response.status}`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Nous Portal API error: HTTP ${response.status}`);

    const fail = (field: string): never => {
      throw ctx.fail.parseFailure(`Invalid Nous Portal account response: ${field}`);
    };
    const object = (value: unknown, field: string): Record<string, unknown> => {
      if (value === undefined || value === null) return {};
      if (typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value as Record<string, unknown>;
    };
    const number = (value: unknown, field: string): number | undefined => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "number" && typeof value !== "string") return fail(field);
      if (typeof value === "string" && !/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim())) {
        return fail(field);
      }
      const parsed = Number(value);
      return Number.isFinite(parsed) ? parsed : fail(field);
    };
    const text = (value: unknown): string | undefined =>
      typeof value === "string" ? value.trim() || undefined : undefined;
    let decoded: unknown;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected an object");
    if (root.error) throw ctx.fail.apiFailure("Nous Portal account endpoint reported an error.");
    const subscription = object(root.subscription, "subscription");
    const access = object(root.paid_service_access, "paid_service_access");
    const user = object(root.user, "user");
    const organization = object(root.organisation, "organisation");
    const monthly = number(subscription.monthly_credits, "monthly_credits");
    if (monthly !== undefined && monthly < 0) return fail("monthly_credits");
    const remaining =
      number(subscription.credits_remaining, "credits_remaining") ??
      number(access.subscription_credits_remaining, "subscription_credits_remaining");
    const rollover = number(subscription.rollover_credits, "rollover_credits");
    const purchased =
      number(root.purchased_credits_remaining, "purchased_credits_remaining") ??
      number(access.purchased_credits_remaining, "paid_service_access.purchased_credits_remaining");
    const total = number(access.total_usable_credits, "total_usable_credits");
    if ([monthly, remaining, rollover, purchased, total].every((value) => value === undefined)) {
      return fail("no credit amounts");
    }
    let renewal: Date | undefined;
    if (subscription.current_period_end !== undefined && subscription.current_period_end !== null) {
      if (typeof subscription.current_period_end !== "string") return fail("current_period_end");
      try {
        renewal = ctx.date.iso(subscription.current_period_end);
      } catch (error) {
        void error;
        return fail("current_period_end");
      }
    }
    const subscriptionRows: CodexBarDetailRow[] = [];
    if (remaining !== undefined) {
      const grant = monthly !== undefined && monthly > 0 ? ` of ${ctx.format.usd(monthly)}` : "";
      subscriptionRows.push({
        label: "Subscription credits",
        value: `${ctx.format.usd(Math.max(0, remaining))}${grant} left`,
      });
    } else if (monthly !== undefined) {
      subscriptionRows.push({ label: "Monthly grant", value: ctx.format.usd(monthly) });
    }
    if (rollover !== undefined && rollover > 0) {
      subscriptionRows.push({ label: "Rollover credits", value: ctx.format.usd(rollover) });
    }
    if (renewal) subscriptionRows.push({ label: "Renews", value: ctx.format.monthDay(renewal) });
    const creditRows: CodexBarDetailRow[] = [];
    if (purchased !== undefined) creditRows.push({ label: "Top-up credits", value: ctx.format.usd(purchased) });
    if (total !== undefined) creditRows.push({ label: "Total usable", value: ctx.format.usd(total) });
    const details: CodexBarDetailSection[] = [];
    if (subscriptionRows.length) details.push({ title: "Subscription", rows: subscriptionRows });
    if (creditRows.length) details.push({ title: "Credits", rows: creditRows });
    return {
      primary:
        monthly !== undefined && monthly > 0 && remaining !== undefined
          ? { usedPercent: ctx.pct(Math.max(0, monthly - Math.max(0, remaining)), monthly), resetsAt: renewal }
          : undefined,
      details,
      subscriptionRenewsAt: renewal,
      identity: {
        email: text(user.email),
        organization: text(organization.name),
        loginMethod: text(subscription.plan) ?? (access.has_active_subscription === true ? "Subscription" : undefined),
      },
      dataConfidence: "exact",
    };
  },
});
