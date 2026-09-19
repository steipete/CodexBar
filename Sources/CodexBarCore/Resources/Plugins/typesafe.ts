type TypeSafeRecord = Record<string, unknown>;

const billingURL = "https://console.typesafe.ai/settings/billing";
const billingOrigin = "https://console.typesafe.ai";
const actionCacheKey = "typesafe.billing.next-action";
const actionCacheTTL = 12 * 60 * 60;
const maximumChunkCount = 60;
const chunkBatchSize = 8;

defineProvider({
  id: "typesafe",
  name: "TypeSafe",
  endpoints: [billingOrigin],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["console.typesafe.ai", "typesafe.ai"],
  async fetchUsage(ctx) {
    const record = (value: unknown): TypeSafeRecord | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? (value as TypeSafeRecord) : undefined;
    const expired = (): never => {
      throw ctx.fail.authenticationExpired("TypeSafe session expired. Sign in again or paste a fresh Cookie header.");
    };
    const retryAfter = (response: CodexBarHTTPTextResponse): number => {
      const raw = response.headers["retry-after"];
      const value = raw && /^\d+(?:\.\d+)?$/.test(raw.trim()) ? Number(raw) : 1;
      return Number.isFinite(value) ? Math.min(10, value) : 1;
    };
    const validate = (response: CodexBarHTTPTextResponse): void => {
      if (response.status === 401 || response.status === 403 || (response.status >= 300 && response.status < 400))
        expired();
      if (response.status === 429)
        throw ctx.fail.rateLimited("TypeSafe rate limit reached.", { retryAfterSeconds: retryAfter(response) });
      if (response.status === 408 || response.status >= 500)
        throw ctx.fail.providerUnavailable("TypeSafe billing is unavailable.", {
          retryAfterSeconds: retryAfter(response),
        });
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`TypeSafe returned HTTP ${response.status}.`);
    };
    // Same-origin redirects are followed, so a signed-out request lands on the login page with HTTP 200.
    // Its Next.js route tree carries the `(auth)` → `login` segment; signed-in billing pages do not.
    const isLoginLanding = (body: string): boolean => /\\?"\(auth\)\\?",\{\\?"children\\?":\[\\?"login\\?"/.test(body);
    const validateBody = (response: CodexBarHTTPTextResponse): void => {
      validate(response);
      if (isLoginLanding(response.bodyText)) expired();
    };
    const actionIDPattern = /"([0-9a-f]{40,})"[^)]{0,150}"getBillingOverviewResult"/i;
    const discoverActionID = async (cookie: string): Promise<string> => {
      const page = await ctx.http.get(billingURL, {
        headers: { Cookie: cookie, Accept: "text/html" },
        timeoutSeconds: 6,
      });
      validateBody(page);
      const scriptPattern = /<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/gi;
      const chunkURLs: string[] = [];
      let match: RegExpExecArray | null;
      while ((match = scriptPattern.exec(page.bodyText)) && chunkURLs.length < maximumChunkCount) {
        const source = match[1];
        const normalized = source.startsWith("/") ? `${billingOrigin}${source}` : source;
        if (!normalized.startsWith(`${billingOrigin}/`) || !/\.js(?:$|\?)/i.test(normalized)) continue;
        if (!chunkURLs.includes(normalized)) chunkURLs.push(normalized);
      }
      for (let offset = 0; offset < chunkURLs.length; offset += chunkBatchSize) {
        const batch = chunkURLs.slice(offset, offset + chunkBatchSize);
        const bodies = await Promise.all(
          batch.map(async (url) => {
            try {
              const chunk = await ctx.http.get(url, { timeoutSeconds: 2 });
              return chunk.status >= 200 && chunk.status < 300 ? chunk.bodyText : null;
            } catch (error) {
              void error;
              return null;
            }
          }),
        );
        for (const body of bodies) {
          const action = body && actionIDPattern.exec(body)?.[1];
          if (action) return action;
        }
      }
      throw ctx.fail.parseFailure("TypeSafe billing page format changed: action id not found.");
    };
    const cookie = await ctx.browser.cookieHeader("typesafe.ai");
    let actionID = ctx.cache.get<string>(actionCacheKey);
    if (!actionID || !/^[0-9a-f]{40,}$/i.test(actionID)) {
      actionID = await discoverActionID(cookie);
      ctx.cache.set(actionCacheKey, actionID, actionCacheTTL);
    }
    const post = async (id: string): Promise<CodexBarHTTPTextResponse> =>
      ctx.http.post(billingURL, {
        headers: {
          Cookie: cookie,
          Origin: billingOrigin,
          "Next-Action": id,
          Accept: "text/x-component",
          "Content-Type": "application/json",
        },
        body: [],
        timeoutSeconds: 6,
      });
    let response = await post(actionID);
    if (response.status === 404 && response.headers["x-nextjs-action-not-found"] === "1") {
      ctx.cache.set(actionCacheKey, "", 1);
      actionID = await discoverActionID(cookie);
      ctx.cache.set(actionCacheKey, actionID, actionCacheTTL);
      response = await post(actionID);
    }
    validateBody(response);

    let result: TypeSafeRecord | undefined;
    for (const line of response.bodyText.split(/\r?\n/)) {
      const separator = line.indexOf(":");
      if (separator < 1) continue;
      let candidate: unknown;
      try {
        candidate = JSON.parse(line.slice(separator + 1));
      } catch (error) {
        void error;
        continue;
      }
      const object = record(candidate);
      if (object && Object.prototype.hasOwnProperty.call(object, "ok")) {
        result = object;
        break;
      }
    }
    if (!result) throw ctx.fail.parseFailure("TypeSafe billing response format changed: missing result.");
    if (result.ok !== true) throw ctx.fail.apiFailure("TypeSafe billing request failed.");
    const billing = record(record(result.data)?.billing);
    if (!billing) throw ctx.fail.parseFailure("TypeSafe billing response format changed: missing billing.");
    const number = (value: unknown): number | undefined =>
      typeof value === "number" && Number.isFinite(value) ? value : undefined;
    const spent = number(billing.spent);
    const balance = number(billing.balance);
    if (spent === undefined || balance === undefined)
      throw ctx.fail.parseFailure("TypeSafe billing response format changed: missing billing numbers.");
    const cycleLabel =
      typeof billing.cycleLabel === "string" && billing.cycleLabel.trim() ? billing.cycleLabel.trim() : undefined;
    const plan = typeof billing.plan === "string" && billing.plan.trim() ? billing.plan.trim() : undefined;
    const planLabel =
      plan === "free_plan"
        ? "Free"
        : plan
            ?.split(/[_-]+/)
            .filter(Boolean)
            .map((part) => part.charAt(0).toUpperCase() + part.slice(1).toLowerCase())
            .join(" ");
    const rows: CodexBarDetailRow[] = [
      { label: cycleLabel ? `Spent (${cycleLabel})` : "Spent", value: ctx.format.usd(spent) },
    ];
    if (planLabel) rows.push({ label: "Plan", value: planLabel });
    if (Array.isArray(billing.credits)) {
      for (const item of billing.credits) {
        const credit = record(item);
        const amount = number(credit?.amount);
        const remaining = number(credit?.remaining);
        const expiresAt = typeof credit?.expiresAt === "string" ? credit.expiresAt : undefined;
        if (amount === undefined || remaining === undefined || remaining <= 0 || !expiresAt) continue;
        const expires = Date.parse(expiresAt);
        if (!Number.isFinite(expires)) continue;
        rows.push({
          label: "Credit",
          value: `${ctx.format.number(remaining)} of ${ctx.format.number(amount)}, expires ${ctx.format.monthDay(expires)}`,
        });
      }
    }
    return {
      cost: { used: spent, balance, currency: "USD", period: cycleLabel },
      details: [{ title: "Billing", rows }],
      identity: { loginMethod: `Balance: ${ctx.format.usd(balance)}` },
      dataConfidence: "exact",
    };
  },
});
