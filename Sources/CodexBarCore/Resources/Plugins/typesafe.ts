type TypeSafeRecord = Record<string, unknown>;

const billingOverviewURL = "https://console.typesafe.ai/api/billing/overview";
const billingPageURL = "https://console.typesafe.ai/billing";
const billingOrigin = "https://console.typesafe.ai";
// Cloudflare blocks the Linux default UA (it contains "curl/"), so send a browser-style one.
const userAgent =
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";

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
    // A redirect only means the session is gone when it targets a login/SSO route. The billing overview
    // itself may redirect for benign route moves (for example /settings/billing -> /billing).
    const loginRedirect = (location: string | undefined): boolean => {
      if (typeof location !== "string" || !location.trim()) return false;
      const target = location.trim();
      const loginPath = /(?:^|[/?#])(?:login|sign-?in|signin|auth|oauth|sso)(?:[/?#]|$)/i;
      if (!/^(?:https?:)?\/\//i.test(target)) return loginPath.test(target);
      const hostMatch = /^(?:https?:)?\/\/([^/?#]+)/i.exec(target);
      const hostname = hostMatch ? hostMatch[1].toLowerCase().replace(/:\d+$/, "") : "";
      const knownHost =
        hostname === "typesafe.ai" || hostname === "console.typesafe.ai" || hostname.endsWith(".typesafe.ai");
      return !knownHost || loginPath.test(target);
    };
    const validate = (response: CodexBarHTTPTextResponse): void => {
      if (response.status === 401 || response.status === 403) expired();
      if (response.status >= 300 && response.status < 400) {
        if (loginRedirect(response.headers["location"])) expired();
        throw ctx.fail.apiFailure(
          `TypeSafe billing overview redirected unexpectedly (HTTP ${response.status}). Open ${billingPageURL} to check access; if the page opens, report the integration failure.`,
        );
      }
      if (response.status === 429)
        throw ctx.fail.rateLimited("TypeSafe rate limit reached.", { retryAfterSeconds: retryAfter(response) });
      if (response.status === 408 || response.status >= 500)
        throw ctx.fail.providerUnavailable("TypeSafe billing is unavailable.", {
          retryAfterSeconds: retryAfter(response),
        });
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`TypeSafe returned HTTP ${response.status}.`);
    };
    const cookie = await ctx.browser.cookieHeader("typesafe.ai");
    const response = await ctx.http.get(billingOverviewURL, {
      headers: { Cookie: cookie, Accept: "application/json", "User-Agent": userAgent },
      timeoutSeconds: 10,
    });
    validate(response);
    // A signed-out console can answer with an HTML login page instead of JSON.
    const body = response.bodyText.trim();
    if (body.startsWith("<")) {
      if (/(?:login|sign[-\s]?in|\(auth\))/i.test(body)) expired();
      throw ctx.fail.apiFailure(
        `TypeSafe billing overview returned HTML instead of JSON. Open ${billingPageURL} to check access.`,
      );
    }
    let payload: unknown;
    try {
      payload = JSON.parse(body);
    } catch (error) {
      void error;
      throw ctx.fail.parseFailure(
        `TypeSafe billing overview is not valid JSON. Open ${billingPageURL} to check access; if the page opens, report the integration failure.`,
      );
    }
    const billing = record(record(payload)?.billing);
    if (!billing)
      throw ctx.fail.parseFailure(
        `TypeSafe billing overview format changed: missing billing. Open ${billingPageURL} to check access; if the page opens, report the integration failure.`,
      );
    const number = (value: unknown): number | undefined =>
      typeof value === "number" && Number.isFinite(value) ? value : undefined;
    const spent = number(billing.spent);
    const balance = number(billing.balance);
    if (spent === undefined || balance === undefined)
      throw ctx.fail.parseFailure(
        `TypeSafe billing overview format changed: missing billing numbers. Open ${billingPageURL} to check access; if the page opens, report the integration failure.`,
      );
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
    const availableRows = 24 - rows.length;
    const creditRows: CodexBarDetailRow[] = [];
    let creditCount = 0;
    for (const item of Array.isArray(billing.credits) ? billing.credits : []) {
      const credit = record(item);
      const amount = number(credit?.amount);
      const remaining = number(credit?.remaining);
      const expiresAt = typeof credit?.expiresAt === "string" ? credit.expiresAt : undefined;
      if (amount === undefined || remaining === undefined || remaining <= 0 || !expiresAt) continue;
      const expires = Date.parse(expiresAt);
      if (!Number.isFinite(expires)) continue;
      creditCount++;
      if (creditRows.length >= availableRows) continue;
      creditRows.push({
        label: "Credit",
        value: `${ctx.format.number(remaining)} of ${ctx.format.number(amount)}, expires ${ctx.format.monthDay(expires)}`,
      });
    }
    if (creditCount > availableRows) {
      const shown = availableRows - 1;
      rows.push(...creditRows.slice(0, shown));
      rows.push({ label: "Additional credits", value: String(creditCount - shown) });
    } else {
      rows.push(...creditRows);
    }
    return {
      cost: { used: spent, balance, currency: "USD", period: cycleLabel },
      details: [{ title: "Billing", rows }],
      identity: { loginMethod: `Balance: ${ctx.format.usd(balance)}` },
      dataConfidence: "exact",
    };
  },
});
