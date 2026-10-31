defineProvider({
  id: "perplexity",
  name: "Perplexity",
  endpoints: ["https://www.perplexity.ai"],
  settings: [{ key: "SESSION_COOKIE", title: "Environment session", type: "secure" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["www.perplexity.ai"],
  async fetchUsage(ctx) {
    const domain = "www.perplexity.ai";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("Perplexity cookies are disabled.");
    const names = [
      "__Secure-authjs.session-token",
      "authjs.session-token",
      "__Secure-next-auth.session-token",
      "next-auth.session-token",
    ];
    const cookies = (raw) => {
      if (!raw) return [];
      const text = raw.trim();
      if (!text.includes("=") && !text.includes(";")) return names.map((name) => `${name}=${text}`);
      const pairs = new Map();
      for (const part of text.replace(/^cookie:\s*/i, "").split(";")) {
        const separator = part.indexOf("=");
        if (separator < 1) continue;
        const name = part.slice(0, separator).trim();
        const value = part.slice(separator + 1).trim();
        if (value) pairs.set(name.toLowerCase(), { name, value });
      }
      for (const expected of names) {
        const direct = pairs.get(expected.toLowerCase());
        if (direct) return [`${direct.name}=${direct.value}`];
        const indexed = new Map();
        for (const [name, pair] of pairs) {
          if (!name.startsWith(`${expected.toLowerCase()}.`)) continue;
          const suffix = name.slice(expected.length + 1);
          if (!/^[+-]?\d+$/.test(suffix)) continue;
          const index = Number(suffix);
          if (Number.isSafeInteger(index) && index >= 0) indexed.set(index, { index, ...pair });
        }
        const chunks = [...indexed.values()].sort((a, b) => a.index - b.index);
        if (chunks.length && chunks.every((chunk, index) => chunk.index === index)) {
          return [
            `${chunks[0].name.slice(0, chunks[0].name.lastIndexOf("."))}=${chunks.map((chunk) => chunk.value).join("")}`,
          ];
        }
      }
      return [];
    };
    let rejected = false;
    const attempted = new Set();
    const attempt = async (header) => {
      for (const cookie of cookies(header)) {
        if (attempted.has(cookie)) continue;
        attempted.add(cookie);
        const response = await ctx.http.get(`https://${domain}/rest/billing/credits?version=2.18&source=default`, {
          timeoutSeconds: 15,
          headers: {
            Cookie: cookie,
            Origin: `https://${domain}`,
            Referer: `https://${domain}/account/usage`,
            "User-Agent":
              "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
          },
        });
        if (response.status === 401 || response.status === 403) {
          rejected = true;
          continue;
        }
        if (response.status !== 200) throw ctx.fail.apiFailure(`Perplexity API error: HTTP ${response.status}`);
        try {
          return JSON.parse(response.bodyText);
        } catch (error) {
          void error;
          throw ctx.fail.parseFailure("Failed to parse Perplexity usage data: invalid JSON");
        }
      }
      return undefined;
    };
    let data;
    for await (const session of ctx.browser.sessions(domain)) {
      data = await attempt(session.header);
      if (data !== undefined) break;
      ctx.browser.rejectCookie(domain, session);
    }
    if (data === undefined && policy !== "manual") data = await attempt(ctx.settings.getSecret("SESSION_COOKIE"));
    if (data === undefined) {
      if (rejected)
        throw ctx.fail.authenticationExpired("Perplexity session token is invalid or expired. Please log in again.");
      throw ctx.fail.missingCredential(
        "Perplexity session token is missing or invalid. Please log into Perplexity in your browser.",
      );
    }
    const fail = () => {
      throw ctx.fail.parseFailure("Failed to parse Perplexity usage data: invalid credit fields");
    };
    const number = (value) => (typeof value === "number" && Number.isFinite(value) ? value : fail());
    if (!data || typeof data !== "object" || Array.isArray(data)) fail();
    const balance = number(data.balance_cents ?? data.balanceCents);
    const renewal = number(data.renewal_date_ts ?? data.renewalDateTs);
    const purchasedField = number(data.current_period_purchased_cents ?? data.currentPeriodPurchasedCents);
    let remaining = number(data.total_usage_cents ?? data.totalUsageCents);
    const grants = data.credit_grants ?? data.creditGrants;
    if (!Array.isArray(grants)) fail();
    for (const grant of grants) {
      if (!grant || typeof grant.type !== "string") fail();
      number(grant.amount_cents ?? grant.amountCents);
      const expiry = grant.expires_at_ts ?? grant.expiresAtTs;
      if (expiry !== undefined && expiry !== null) number(expiry);
    }
    const sum = (values) =>
      Math.max(
        0,
        values.reduce((total, grant) => total + (grant.amount_cents ?? grant.amountCents), 0),
      );
    const recurring = sum(grants.filter((grant) => grant.type === "recurring"));
    const promoGrants = grants.filter(
      (grant) =>
        grant.type === "promotional" &&
        (grant.expires_at_ts ?? grant.expiresAtTs ?? Infinity) > ctx.date.nowMillis() / 1000,
    );
    const promo = sum(promoGrants);
    const purchased = Math.max(sum(grants.filter((grant) => grant.type === "purchased")), purchasedField, 0);
    const recurringUsed = Math.min(remaining, recurring);
    remaining -= recurringUsed;
    const purchasedUsed = Math.min(remaining, purchased);
    remaining -= purchasedUsed;
    const promoUsed = Math.min(remaining, promo);
    const optional = (value) => (value === undefined || value === null ? undefined : number(value));
    const orgDraws = optional(data.org_pool_draws_cents ?? data.orgPoolDrawsCents);
    const orgCap = optional(data.org_user_cap_cents ?? data.orgUserCapCents);
    const orgDepleted = data.is_org_pool_depleted ?? data.isOrgPoolDepleted;
    if (orgDepleted !== undefined && orgDepleted !== null && typeof orgDepleted !== "boolean") fail();
    const promoExpiry = promoGrants
      .map((grant) => grant.expires_at_ts ?? grant.expiresAtTs)
      .filter(Number.isFinite)
      .sort((a, b) => a - b)[0];
    const integer = (value) => BigInt(value).toString();
    const description = (used, total, unit) =>
      Number.isFinite(used) && Number.isFinite(total)
        ? `${integer(Math.sign(used) * Math.round(Math.abs(used)))}/${integer(Math.trunc(total))} ${unit}`
        : undefined;
    const percent = (used, total) => (total > 0 ? Math.max(0, Math.min(100, (used / total) * 100)) : 100);
    const promoDescription = description(promoUsed, promo, "bonus");
    let extraWindows;
    if (orgDraws !== undefined || orgCap !== undefined) {
      // Org members draw on the organization pool after seat credits. balance_cents is the account's total
      // available credits, so the org share is whatever the personal pools do not cover.
      const orgUsed = Math.max(0, orgDraws ?? 0);
      const personalLeft = recurring - recurringUsed + (purchased - purchasedUsed) + (promo - promoUsed);
      const orgAvailable = orgDepleted === true ? 0 : Math.max(0, balance - personalLeft);
      extraWindows = [
        {
          id: "org-credits",
          title: "Organization",
          window: {
            usedPercent: percent(orgUsed, orgUsed + orgAvailable),
            resetDescription: description(orgUsed, orgUsed + orgAvailable, "credits"),
          },
        },
      ];
    }
    return {
      primary:
        recurring > 0
          ? {
              usedPercent: percent(recurringUsed, recurring),
              resetsAt: ctx.date.unixSeconds(renewal),
              resetDescription: description(recurringUsed, recurring, "credits"),
            }
          : promo > 0 || purchased > 0
            ? undefined
            : { usedPercent: 100, resetsAt: ctx.date.unixSeconds(renewal), resetDescription: "0/0 credits" },
      secondary: {
        usedPercent: percent(promoUsed, promo),
        resetDescription:
          promoExpiry !== undefined && promoDescription !== undefined
            ? `${promoDescription} · exp. ${ctx.format.monthDay(new Date(promoExpiry * 1000))}`
            : promoDescription,
      },
      tertiary: {
        usedPercent: percent(purchasedUsed, purchased),
        resetDescription: description(purchasedUsed, purchased, "credits"),
      },
      extraWindows,
      identity: { loginMethod: recurring <= 0 ? undefined : recurring < 5000 ? "Pro" : "Max" },
    };
  },
});
