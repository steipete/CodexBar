defineProvider({
  id: "opendesign",
  name: "OpenDesign",
  settings: [{ key: "MESSAGES", title: "OpenDesign", type: "plain" }],
  endpoints: ["https://amr-api.open-design.ai"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["amr-api.open-design.ai"],
  cookiePolicy: {
    selection: "request-url",
    cache: "nonpersistent",
    imports: "access-gated",
    // The host's optional name filter excludes dots; validate the opaque session at the endpoint.
  },
  async fetchUsage(ctx) {
    const domain = "amr-api.open-design.ai";
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key) => messages[key] || key;
    const signIn = message("Sign in to OpenDesign, then refresh CodexBar.");
    const expired = ctx.fail.authenticationExpired(signIn);
    const malformed = () => {
      throw ctx.fail.parseFailure(message("OpenDesign usage response format changed."));
    };
    const text = (value) => (typeof value === "string" && value.trim() ? value.trim() : undefined);
    const credits = (value) => {
      if (typeof value === "string" && /^\d+(\.\d+)?$/.test(value)) value = Number(value);
      return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= Number.MAX_SAFE_INTEGER
        ? value
        : malformed();
    };
    if (ctx.browser.availability(domain) === "off") throw ctx.fail.missingCredential(signIn);
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const get = async (path, workspace) => {
        const response = await ctx.http.get(`https://${domain}/api/v1/workspaces/${path}`, {
          cookieSession: session.id,
          headers: { Accept: "application/json", ...(workspace ? { "X-Vela-Workspace-Id": workspace } : {}) },
        });
        if (response.status === 401) throw expired;
        if (response.status === 403) throw ctx.fail.permissionDenied(message("OpenDesign billing access was denied."));
        const failed = message("OpenDesign request failed. Try again later.");
        if (response.status === 429) throw ctx.fail.rateLimited(failed);
        if (response.status >= 500 || response.status === 408) throw ctx.fail.providerUnavailable(failed);
        if (response.status !== 200) throw ctx.fail.apiFailure(failed);
        try {
          return JSON.parse(response.bodyText);
        } catch {
          return malformed();
        }
      };
      try {
        const workspace = await get("current");
        const id = text(workspace?.workspaceId);
        if (!id || !/^[A-Za-z0-9_-]{1,128}$/.test(id)) return malformed();
        const usage = await get(`${id}/billing/coding-plan-usage`, id);
        if (usage?.workspaceId !== id || typeof usage.eligible !== "boolean" || !Array.isArray(usage.windows))
          return malformed();
        const unavailable = () => {
          throw ctx.fail.providerUnavailable(
            message("OpenDesign subscription usage is unavailable for this workspace."),
          );
        };
        if (!usage.eligible) return unavailable();
        const window = (seconds) => {
          const matches = usage.windows.filter((item) => item?.durationSeconds === seconds);
          if (matches.length === 0) return undefined;
          if (matches.length !== 1) return malformed();
          const item = matches[0];
          const used = credits(item.usedCredits);
          const limit = credits(item.limitCredits);
          if (limit <= 0) return malformed();
          const reset = text(item.resetsAt);
          return {
            usedPercent: ctx.pct(used, limit),
            windowMinutes: seconds / 60,
            quotaLimit: limit,
            quotaUnit: "credits",
            resetsAt:
              reset && /^\d{4}-\d{2}-\d{2}T/.test(reset) && Number.isFinite(Date.parse(reset)) ? reset : undefined,
          };
        };
        const primary = window(18000);
        const secondary = window(604800);
        if (!primary && !secondary) return unavailable();
        return {
          primary,
          secondary,
          identity: {
            accountID: id,
            organization: text(workspace.workspaceName),
            loginMethod: text(usage.tier) ?? text(workspace.personalMembershipTier),
          },
        };
      } catch (error) {
        if (error !== expired) throw error;
        ctx.browser.rejectCookie(domain, session);
        rejected = true;
      }
    }
    throw rejected ? expired : ctx.fail.missingCredential(signIn);
  },
});
