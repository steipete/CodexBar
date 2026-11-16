defineProvider({
  id: "openai",
  name: "OpenAI",
  settings: [],
  // Requests go to api.openai.com only. The platform.openai.com origin is read from browser storage and never fetched.
  endpoints: ["https://api.openai.com"],
  capabilities: ["browser-local-storage", "http-status"],
  localStorage: [{ origin: "https://platform.openai.com", keys: ["oai-auth:onboard"] }],
  async fetchUsage(ctx) {
    const api = "https://api.openai.com/v1/dashboard";
    const subscriptionPrefix = "chatgpt_api_credits_promo_";
    const now = ctx.date.now();
    const nowSeconds = now.getTime() / 1000;
    const invalid = (what: string): never => {
      throw ctx.fail.parseFailure(`Could not parse OpenAI ${what}. The response format may have changed.`);
    };
    const object = (value: unknown, what: string): Record<string, unknown> =>
      value !== null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : invalid(what);
    const optionalNumber = (value: unknown, what: string): number | undefined =>
      value === undefined || value === null
        ? undefined
        : typeof value === "number" && Number.isFinite(value)
          ? value
          : invalid(what);
    // The JWT exp claim only skips a token that is already dead. OpenAI stays the judge of validity.
    const expiry = (token: string): number | undefined => {
      try {
        const exp = ctx.jwt.decode<{ exp?: unknown }>(token).exp;
        return typeof exp === "number" && Number.isFinite(exp) ? exp : undefined;
      } catch (error) {
        void error;
        return undefined;
      }
    };
    // Null means OpenAI answered 401, so the caller tries the next browser profile.
    const send = async (request: Promise<CodexBarHTTPTextResponse>): Promise<string | null> => {
      const response = await request;
      if (response.status === 401) return null;
      if (response.status === 429) throw ctx.fail.rateLimited(`OpenAI Platform error: HTTP ${response.status}`);
      if (response.status >= 500) throw ctx.fail.providerUnavailable(`OpenAI Platform error: HTTP ${response.status}`);
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`OpenAI Platform error: HTTP ${response.status}`);
      return response.bodyText;
    };
    const parse = (text: string, what: string): Record<string, unknown> => {
      try {
        return object(JSON.parse(text), what);
      } catch (error) {
        void error;
        return invalid(what);
      }
    };
    const grantsFor = async (accessToken: string): Promise<string | null> => {
      const login = await send(
        ctx.http.post(`${api}/onboarding/login`, {
          headers: { Authorization: `Bearer ${accessToken}` },
          body: { app: "api" },
        }),
      );
      if (login === null) return null;
      const user = object(parse(login, "session response").user, "session response");
      const sessionKey = object(user.session, "session response").sensitive_id;
      if (typeof sessionKey !== "string" || !sessionKey) return invalid("session response");
      return await send(
        ctx.http.get(`${api}/billing/credit_grants`, { headers: { Authorization: `Bearer ${sessionKey}` } }),
      );
    };

    // Each profile's access token is tried in browser order. Nothing is refreshed, stored, or rotated.
    const entries = await ctx.browser.localStorage("https://platform.openai.com", "oai-auth:onboard");
    let found = false;
    let body: string | null = null;
    for (const entry of entries) {
      let accessToken: unknown;
      try {
        accessToken = (JSON.parse(entry.value) as { accessToken?: unknown }).accessToken;
      } catch (error) {
        void error;
        continue;
      }
      if (typeof accessToken !== "string" || !accessToken) continue;
      found = true;
      const exp = expiry(accessToken);
      if (exp !== undefined && exp <= nowSeconds) continue;
      body = await grantsFor(accessToken);
      if (body !== null) break;
    }
    if (body === null) {
      throw found
        ? ctx.fail.authenticationExpired(
            "OpenAI Platform session expired. Open platform.openai.com in the browser you signed in with to renew it, then refresh.",
          )
        : ctx.fail.missingCredential(
            "Sign in at platform.openai.com in Chrome (or another Chromium browser), then refresh.",
          );
    }

    const payload = parse(body, "credit grants");
    const available = optionalNumber(payload.total_available, "credit total");
    if (available === undefined) return invalid("credit total");
    const rawGrants =
      payload.grants === undefined || payload.grants === null ? [] : object(payload.grants, "credit grants").data;
    if (!Array.isArray(rawGrants)) return invalid("credit grants");
    type Grant = { id: string; amount: number; used: number; scheduled: boolean; expiresAt: number | undefined };
    const grants: Grant[] = rawGrants
      .map((raw) => {
        const grant = object(raw, "credit grant");
        if (typeof grant.id !== "string") return invalid("credit grant");
        const amount = optionalNumber(grant.grant_amount, "credit grant") ?? 0;
        const effectiveAt = optionalNumber(grant.effective_at, "credit grant");
        return {
          id: grant.id,
          amount,
          used: Math.min(optionalNumber(grant.used_amount, "credit grant") ?? 0, amount),
          scheduled: grant.is_scheduled === true || (effectiveAt ?? 0) > nowSeconds,
          expiresAt: optionalNumber(grant.expires_at, "credit grant"),
        };
      })
      .filter((grant) => grant.amount > 0 && (grant.expiresAt ?? Infinity) > nowSeconds)
      .sort((lhs, rhs) => (lhs.expiresAt ?? Infinity) - (rhs.expiresAt ?? Infinity));
    const amounts = (grant: Grant): string =>
      `${ctx.format.usd(grant.amount - grant.used)} of ${ctx.format.usd(grant.amount)} left`;
    const expires = (grant: Grant): string | null => {
      if (grant.expiresAt === undefined) return null;
      const date = ctx.date.unixSeconds(grant.expiresAt);
      const day = ctx.format.monthDay(date);
      return `Expires ${date.getFullYear() === now.getFullYear() ? day : `${day}, ${date.getFullYear()}`}`;
    };
    // Grants expire rather than reset, so the lane is the subscription grant about to be lost.
    const subscription = grants.find(
      (grant) => grant.id.startsWith(subscriptionPrefix) && !grant.scheduled && grant.used < grant.amount,
    );
    const others = grants.filter((grant) => grant !== subscription);
    const soonest = grants[0]?.expiresAt;
    return {
      primary: subscription
        ? {
            usedPercent: ctx.pct(subscription.used, subscription.amount),
            resetDescription: [amounts(subscription), expires(subscription)].filter(Boolean).join(" · "),
          }
        : null,
      cost: {
        used: available,
        limit: 0,
        currency: "USD",
        period: "Prepaid credits",
        resetsAt: soonest === undefined ? null : ctx.date.unixSeconds(soonest),
        balance: available,
      },
      details: others.length
        ? [
            {
              title: "Other credit grants",
              rows: others.map((grant) => ({
                label: grant.scheduled
                  ? "Scheduled credit"
                  : grant.id.startsWith(subscriptionPrefix)
                    ? "ChatGPT subscription credit"
                    : "Credit grant",
                value: amounts(grant),
                secondaryValue: expires(grant),
                progress: grant.used / grant.amount,
              })),
            },
          ]
        : [],
      identity: { loginMethod: "Platform session" },
      dataConfidence: "exact",
    };
  },
});
