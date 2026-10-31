defineProvider({
  id: "traecn",
  name: "Trae CN",
  endpoints: ["https://api.trae.cn"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  // Include parent-domain sessions shared by the dashboard and API.
  cookieDomains: ["trae.cn", "api.trae.cn"],
  async fetchUsage(ctx) {
    const domain = ctx.browser.availability("api.trae.cn") === "manual" ? "api.trae.cn" : "trae.cn";
    const signIn = "Sign in to Trae CN at trae.cn, then refresh CodexBar.";
    const malformed = () => {
      throw ctx.fail.parseFailure("Trae CN usage response format changed.");
    };
    const finite = (value) => typeof value === "number" && Number.isFinite(value) && value >= 0;
    const rejected = (response) =>
      response.status === 401 || response.status === 403 || (response.status >= 300 && response.status < 400);
    const read = (response) => {
      const message = "Trae CN request failed. Try refreshing later.";
      if (response.status === 429) throw ctx.fail.rateLimited(message);
      if (response.status === 408 || response.status >= 500) throw ctx.fail.providerUnavailable(message);
      if (response.status !== 200) throw ctx.fail.apiFailure(message);
      try {
        return JSON.parse(response.bodyText);
      } catch {
        return malformed();
      }
    };
    if (ctx.browser.availability(domain) === "off") throw ctx.fail.missingCredential(signIn);
    let sessionRejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const headers = { Cookie: session.header ?? "", Origin: "https://www.trae.cn", Referer: "https://www.trae.cn/" };
      const tokenResponse = await ctx.http.post("https://api.trae.cn/cloudide/api/v3/common/GetUserToken", {
        headers,
        body: {},
        timeoutSeconds: 15,
      });
      if (rejected(tokenResponse)) {
        sessionRejected = true;
        ctx.browser.rejectCookie(domain, session);
        continue;
      }
      const tokenPayload = read(tokenResponse);
      const token = tokenPayload?.Result?.Token;
      if (typeof token !== "string" || !token.trim()) return malformed();
      // The exchanged token lives only for this refresh, and only goes back to the declared API origin.
      const usageResponse = await ctx.http.post("https://api.trae.cn/trae/api/v2/pay/user_current_entitlement_list", {
        headers: { ...headers, Authorization: `Cloud-IDE-JWT ${token}` },
        body: { require_usage: true, full_data: true },
        timeoutSeconds: 15,
      });
      if (rejected(usageResponse)) {
        sessionRejected = true;
        ctx.browser.rejectCookie(domain, session);
        continue;
      }
      const payload = read(usageResponse);
      const { total_amount: total, consumed_amount: used } = payload?.usage_summary ?? {};
      if (payload?.code === 1001) {
        sessionRejected = true;
        ctx.browser.rejectCookie(domain, session);
        continue;
      }
      if (payload?.is_credits_billing !== true || !finite(total) || !finite(used)) return malformed();
      const packs = Array.isArray(payload.user_entitlement_pack_list) ? payload.user_entitlement_pack_list : [];
      const subscription = packs.find(
        (pack) => pack && pack.group_type === 0 && (pack.status === undefined || pack.status === 1),
      );
      const plan = typeof subscription?.display_desc === "string" ? subscription.display_desc.trim() : undefined;
      const remaining = Math.max(0, total - used);
      const hasFraction = [used, total, remaining].some((value) => !Number.isInteger(value));
      const number = (value) =>
        ctx.format.number(value, {
          minimumFractionDigits: hasFraction ? 2 : 0,
          maximumFractionDigits: 2,
        });
      // Pack expiry and billing timestamps do not establish an aggregate reset or subscription renewal.
      return {
        primary: total > 0 ? { usedPercent: Math.min(100, (used / total) * 100) } : undefined,
        identity: plan ? { loginMethod: plan } : undefined,
        details: [
          {
            title: "Credits",
            rows: [
              { label: "Used", value: number(used) },
              { label: "Total", value: number(total) },
              { label: "Remaining", value: number(remaining) },
            ],
          },
        ],
        dataConfidence: "exact",
      };
    }
    throw sessionRejected ? ctx.fail.authenticationExpired(signIn) : ctx.fail.missingCredential(signIn);
  },
});
