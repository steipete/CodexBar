function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
defineProvider({
  id: "claudeplatform",
  name: "Claude Platform",
  settings: [],
  endpoints: ["https://platform.claude.com"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["platform.claude.com"],
  cookiePolicy: {
    selection: "request-url",
    cache: "nonpersistent",
    imports: "access-gated",
    requiredCookies: ["sessionKey"],
  },
  async fetchUsage(ctx) {
    const domain = "platform.claude.com";
    if (ctx.browser.availability(domain) === "off")
      throw ctx.fail.missingCredential("Claude Platform cookies are disabled.");

    const invalid = (field) => {
      throw ctx.fail.parseFailure(
        `Could not parse Claude Console ${field}. The Console response format may have changed; update CodexBar or report this.`,
      );
    };
    const object = (value, field) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : invalid(field);
    const minorUnits = (value, field) =>
      typeof value === "number" && Number.isSafeInteger(value) ? value : invalid(field);
    const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
    // A malformed date means an unknown expiry, never a failed refresh.
    const timestamp = (value) => {
      const raw = text(value);
      if (!raw || !/^\d{4}-\d{2}-\d{2}T/.test(raw) || !Number.isFinite(Date.parse(raw))) return undefined;
      try {
        const date = ctx.date.iso(raw);
        return Number.isFinite(date.getTime()) ? date : undefined;
      } catch (error) {
        void error;
        return undefined;
      }
    };
    const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    const now = ctx.date.now();
    // Console grants expire at UTC midnight; show that UTC calendar date instead of shifting it into the local zone.
    const expiry = (date) => {
      const [year, month, day] = date.toISOString().slice(0, 10).split("-").map(Number);
      const label = `${months[month - 1]} ${day}`;
      return `Expires ${year === now.getUTCFullYear() ? label : `${label}, ${year}`} (UTC)`;
    };
    const sessionRejected = ctx.fail.authenticationExpired("Claude Console session expired.");
    const billingDenied = ctx.fail.permissionDenied(
      "Claude Console billing access was denied. Ask the organization owner for billing access.",
    );
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const request = async (path, forbidden) => {
        const response = await ctx.http.get(`https://${domain}${path}`, {
          cookieSession: session.id,
          headers: { Accept: "application/json" },
        });
        if (response.status === 401) throw sessionRejected;
        if (response.status === 403) throw forbidden;
        if (response.status === 429) {
          throw ctx.fail.rateLimited("Claude Console requests are rate limited. Try again in a few minutes.");
        }
        if (response.status >= 500) {
          throw ctx.fail.providerUnavailable("Claude Console is unavailable. Try again later.");
        }
        if (response.status !== 200) {
          throw ctx.fail.apiFailure(`Claude Console returned HTTP ${response.status}. Try again later or report this.`);
        }
        try {
          return JSON.parse(response.bodyText);
        } catch (error) {
          void error;
          return invalid("JSON response");
        }
      };
      try {
        // The organizations list doubles as the session check; a rejected cookie answers 403.
        const organizations = await request("/api/organizations", sessionRejected);
        if (!Array.isArray(organizations)) return invalid("organizations");
        // Claude.ai chat organizations share this list; only API organizations own Console billing.
        const candidates = organizations
          .map((value) => object(value, "organization"))
          .filter((value) => Array.isArray(value.capabilities) && value.capabilities.some((item) => item === "api"))
          .map((organization) => {
            const id = text(organization.uuid);
            if (!id || !/^[A-Za-z0-9-]{1,64}$/.test(id)) return invalid("organization ID");
            return { id, name: text(organization.name) };
          });
        if (candidates.length === 0)
          throw ctx.fail.permissionDenied(
            "This Claude account has no Claude Console API organization. Create one at platform.claude.com.",
          );

        // Try API organizations in listed order; the first one whose billing this member can read wins.
        let selected;
        for (const candidate of candidates) {
          try {
            const credits = object(
              await request(`/api/organizations/${candidate.id}/prepaid/credits`, billingDenied),
              "credit balance",
            );
            selected = { ...candidate, credits };
            break;
          } catch (error) {
            if (error !== billingDenied) throw error;
          }
        }
        if (!selected) throw billingDenied;
        const credits = selected.credits;
        const currency = _nullishCoalesce(text(credits.currency), () => "USD");
        if (!/^[A-Z]{3}$/.test(currency)) return invalid("currency");
        let exponent = 2;
        if (credits.balance !== undefined && credits.balance !== null) {
          const reported = object(
            _nullishCoalesce(object(credits.balance, "balance").credits, () => ({})),
            "balance credits",
          ).exponent;
          if (reported !== undefined && reported !== null) {
            if (typeof reported !== "number" || !Number.isInteger(reported) || reported < 0 || reported > 4)
              return invalid("currency exponent");
            exponent = reported;
          }
        }
        const scale = 10 ** exponent;
        const money = (minor) => ctx.format.currency(minor / scale, currency);
        const balance = minorUnits(credits.amount, "credit balance") / scale;

        const grants = [];
        for (const [field, purchased] of [
          ["promo_tranches", false],
          ["tranches", true],
        ]) {
          const list = credits[field];
          if (list === undefined || list === null) continue;
          if (!Array.isArray(list)) return invalid(field);
          for (const raw of list) {
            const tranche = object(raw, "credit grant");
            const granted = minorUnits(tranche.granted_amount_minor_units, "granted credit");
            const remaining = minorUnits(tranche.remaining_amount_minor_units, "remaining credit");
            const expiresAt = timestamp(tranche.expires_at);
            if (granted <= 0 || (expiresAt && expiresAt.getTime() <= now.getTime())) continue;
            grants.push({
              label: _nullishCoalesce(text(tranche.name), () => (purchased ? "Purchased credit" : "API credit")),
              program: text(tranche.program_id),
              purchased,
              remaining: Math.max(0, remaining),
              granted,
              expiresAt,
            });
          }
        }
        grants.sort((lhs, rhs) => {
          if (!lhs.expiresAt && !rhs.expiresAt) return 0;
          if (!lhs.expiresAt) return 1;
          if (!rhs.expiresAt) return -1;
          return lhs.expiresAt.getTime() - rhs.expiresAt.getTime();
        });
        // The soonest-expiring grant that still has credit is the one about to be lost. An exhausted subscription
        // grant is not a lane: the menu bar falls back to purchased credit and the grant moves to the detail list.
        const subscription = grants.find((grant) => grant.program === "subscription_api_credit" && grant.remaining > 0);
        const purchasedGrants = grants.filter((grant) => grant.purchased);
        const purchased = _nullishCoalesce(
          purchasedGrants.find((grant) => grant.remaining > 0),
          () => purchasedGrants[0],
        );
        const amounts = (grant) => `${money(grant.remaining)} of ${money(grant.granted)} left`;
        const [primary, secondary] = [subscription, purchased].map((grant) =>
          grant
            ? {
                usedPercent: ctx.pct(grant.granted - grant.remaining, grant.granted),
                resetDescription: grant.expiresAt ? `${amounts(grant)} · ${expiry(grant.expiresAt)}` : amounts(grant),
              }
            : undefined,
        );

        const details = [];
        const otherGrants = grants.filter((grant) => grant !== subscription && grant !== purchased);
        if (otherGrants.length > 0) {
          details.push({
            title: "Other credit grants",
            rows: otherGrants.map((grant) => ({
              label: grant.label,
              value: amounts(grant),
              secondaryValue: grant.expiresAt ? expiry(grant.expiresAt) : null,
              progress: (grant.granted - Math.min(grant.remaining, grant.granted)) / grant.granted,
            })),
          });
        }

        // Spend is optional: a broken report must not discard an authenticated balance.
        let spendRow;
        try {
          const spend = object(
            await request(`/api/organizations/${selected.id}/current_spend`, billingDenied),
            "spend",
          );
          const amount = minorUnits(spend.amount, "spend");
          if (amount < 0) return invalid("spend");
          spendRow = { label: "This month (UTC)", value: money(amount) };
        } catch (error) {
          if (error.transportClass === "cancelled") throw error;
          spendRow = { label: "Spend", value: "Unavailable" };
        }
        details.push({ title: "Billing", rows: [spendRow] });

        return {
          primary,
          secondary,
          cost: { used: balance, currency, period: "Prepaid credits", balance },
          details,
          identity: { organization: selected.name, loginMethod: "Console session" },
          dataConfidence: "exact",
        };
      } catch (error) {
        if (error !== sessionRejected) throw error;
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
      }
    }
    if (rejected)
      throw ctx.fail.authenticationExpired(
        "Claude Console session expired. Sign in at platform.claude.com or paste a fresh Cookie header.",
      );
    throw ctx.fail.missingCredential(
      `Sign in at platform.claude.com. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste its Cookie header.`,
    );
  },
});
