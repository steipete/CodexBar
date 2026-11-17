defineProvider({
  id: "qoder",
  name: "Qoder",
  endpoints: ["https://qoder.com", "https://qoder.com.cn"],
  settings: [
    { key: "REQUEST_TIMEOUT", title: "Request timeout", type: "plain" },
    { key: "REQUEST_DEADLINE_MILLIS", title: "Request deadline", type: "plain" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["qoder.com", "qoder.com.cn"],
  async fetchUsage(ctx) {
    const manual = ctx.browser.availability("qoder.com") === "manual";
    const fail = (message) => {
      throw ctx.fail.parseFailure(`Could not parse Qoder usage: ${message}`);
    };
    const field = (object, camel, snake) => object[camel] ?? object[snake];
    const number = (value) =>
      typeof value === "number" && Number.isFinite(value) ? value : fail("invalid quota number");
    const object = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) fail("invalid quota object");
      return value;
    };
    const format = (value) => ctx.format.number(value, { maximumFractionDigits: Number.isInteger(value) ? 0 : 2 });
    const unitOf = (value) => {
      if (value == null) return "credits";
      if (typeof value !== "string") fail("invalid quota unit");
      const normalized = value.trim();
      if (normalized.length === 0 || normalized.length > 32) fail("invalid quota unit");
      return normalized === "credit" ? "credits" : normalized;
    };
    const clamp = (value) => Math.max(0, Math.min(100, value));
    const parseDate = (value) => {
      try {
        if (typeof value === "number")
          return value > 10000000000 ? ctx.date.unixMillis(value) : ctx.date.unixSeconds(value);
        if (typeof value === "string") return ctx.date.iso(value);
      } catch (error) {
        void error;
      }
      return undefined;
    };
    const firstParsedDate = (values) => {
      for (const value of values) {
        const date = parseDate(value);
        if (date !== undefined) return date;
      }
      return undefined;
    };
    const quota = (summary) => {
      object(summary);
      if (summary.unit != null && typeof summary.unit !== "string") fail("invalid quota unit");
      const used = number(field(summary, "usedValue", "used_value"));
      const total = number(field(summary, "limitValue", "limit_value"));
      const remainingValue = field(summary, "remainingValue", "remaining_value");
      const remaining = remainingValue == null ? Math.max(0, total - used) : number(remainingValue);
      const provided = field(summary, "usagePercentage", "usage_percentage");
      if (provided != null) number(provided);
      if (used < 0 || total < 0 || remaining < 0) fail("quota values must be nonnegative");
      return { used, total, remaining, provided, unit: unitOf(summary.unit) };
    };
    const quotaWindow = (value, resetsAt, providedPercent, title) => {
      const unit = unitOf(value.unit);
      const usedPercent =
        value.total > 0 ? (providedPercent != null ? providedPercent : (value.used / value.total) * 100) : 100;
      const window = {
        usedPercent: clamp(usedPercent),
        resetDescription: `${format(value.used)} / ${format(value.total)} ${unit}`,
      };
      if (title) window.title = title;
      if (resetsAt !== undefined) window.resetsAt = resetsAt;
      return window;
    };
    const presentationQuota = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return null;
      const used = value.used;
      const total = value.total ?? value.cap ?? value.limitValue ?? value.limit_value;
      const remainingValue = value.remaining ?? value.remainingValue ?? value.remaining_value;
      if (typeof used !== "number" || !Number.isFinite(used)) return null;
      if (typeof total !== "number" || !Number.isFinite(total)) return null;
      const remaining =
        typeof remainingValue === "number" && Number.isFinite(remainingValue)
          ? remainingValue
          : Math.max(0, total - used);
      if (used < 0 || total < 0 || remaining < 0) return null;
      let unit = "credits";
      if (value.unit != null) {
        if (typeof value.unit !== "string") return null;
        const normalized = value.unit.trim();
        if (normalized.length === 0 || normalized.length > 32) return null;
        unit = normalized === "credit" ? "credits" : normalized;
      }
      return { used, total, remaining, unit };
    };
    const parseMember = (body, source) => {
      let root;
      try {
        root = JSON.parse(body);
      } catch (error) {
        void error;
        fail("invalid JSON");
      }
      if (!root || typeof root !== "object" || Array.isArray(root)) fail("invalid response");
      const summaryOf = (container) => {
        if (container == null) return null;
        object(container);
        const summary = field(container, "quotaSummary", "quota_summary");
        return summary == null ? null : quota(summary);
      };
      const total = summaryOf(field(root, "totalQuota", "total_quota"));
      const shared = summaryOf(field(root, "sharedQuota", "shared_quota"));
      if (total == null) fail("missing totalQuota.quotaSummary");
      const resetsAt = parseDate(field(root, "nextResetAt", "next_reset_at"));
      const used = total.used + (shared?.used ?? 0);
      const totalValue = total.total + (shared?.total ?? 0);
      const remaining = total.remaining + (shared?.remaining ?? 0);
      if (totalValue === 0 && (used !== 0 || remaining !== 0))
        fail("zero total quota must have zero usage and remaining");
      const provided = shared ? null : total.provided;
      const aggregate = shared != null && (shared.total > 0 || shared.used > 0 || shared.remaining > 0);
      const planQuota = { used, total: totalValue, remaining, unit: total.unit };
      return {
        snapshot: {
          primary: quotaWindow(planQuota, resetsAt, provided, aggregate ? "Credits" : "Plan credits"),
          identity: { loginMethod: source },
        },
        planTotal: totalValue,
        planQuota,
      };
    };
    const parsePresentation = (body, source, member) => {
      let root;
      try {
        root = JSON.parse(body);
      } catch (error) {
        void error;
        return null;
      }
      if (!root || typeof root !== "object" || Array.isArray(root)) return null;
      if (root.displayMode !== "qoder") return null;
      const usage = root.qoderUsage;
      if (!usage || typeof usage !== "object" || Array.isArray(usage)) return null;
      if (usage.usageType != null && usage.usageType !== "credits") return null;

      const presentationPlan = presentationQuota(usage.userQuota);
      const orgValue = usage.orgResourcePackage;
      const orgAvailable = orgValue != null && orgValue.available !== false;
      const org = orgAvailable ? presentationQuota(orgValue) : null;
      const addOnValue = usage.addOnQuota;
      const addOnAvailable = addOnValue == null || addOnValue.available !== false;
      const addOn = addOnAvailable ? presentationQuota(addOnValue) : null;
      const orgPool = org != null && org.total > 0 ? org : null;
      const addOnPool = addOn != null && addOn.total > 0 ? addOn : null;
      if (presentationPlan == null && orgPool == null && addOnPool == null) return null;

      const memberPlan = member == null ? null : member.planQuota;
      let plan;
      if (presentationPlan != null && presentationPlan.total > 0) plan = presentationPlan;
      else if (memberPlan != null && memberPlan.total > 0) plan = memberPlan;
      else plan = presentationPlan ?? memberPlan ?? { used: 0, total: 0, remaining: 0, unit: "credits" };

      const memberReset = member == null ? undefined : member.snapshot.primary?.resetsAt;
      const resetsAt = firstParsedDate([usage.refreshAt, usage.expiresAt]) ?? memberReset;
      const secondaryPool =
        [orgPool, addOnPool].find((pool) => pool != null && pool.remaining > 0) ?? orgPool ?? addOnPool;

      const snapshot = {
        primary: quotaWindow(plan, resetsAt, undefined, "Plan credits"),
        identity: { loginMethod: source },
      };
      if (resetsAt !== undefined) snapshot.subscriptionRenewsAt = resetsAt;
      if (secondaryPool != null) {
        const secondaryTitle = secondaryPool === orgPool ? "Organization resource package" : "Add-on credits";
        snapshot.secondary = quotaWindow(secondaryPool, undefined, undefined, secondaryTitle);
      }

      const extraWindows = [];
      if (orgPool != null && orgPool !== secondaryPool) {
        extraWindows.push({
          id: "qoder-org-resource-package",
          title: "Organization resource package",
          usageKnown: true,
          window: quotaWindow(orgPool),
        });
      }
      if (addOnPool != null && addOnPool !== secondaryPool) {
        extraWindows.push({
          id: "qoder-add-on",
          title: "Add-on credits",
          usageKnown: true,
          window: quotaWindow(addOnPool),
        });
      }
      if (extraWindows.length > 0) snapshot.extraWindows = extraWindows;
      return snapshot;
    };
    const headersFor = (session) => ({
      Cookie: session.header,
      Accept: "application/json, text/plain, */*",
      "Accept-Language": "en-US,en;q=0.9",
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
      Origin: session.origin,
      Referer: `${session.origin}/account/usage`,
      "X-Requested-With": "XMLHttpRequest",
      "Bx-V": "2.5.35",
    });
    const timeoutSeconds = Number(ctx.settings.get("REQUEST_TIMEOUT") || 15);
    const hostDeadline = Number(ctx.settings.get("REQUEST_DEADLINE_MILLIS"));
    let rejected = false;
    let terminalError;
    const domains = ["qoder.com", "qoder.com.cn"].filter((domain) => ctx.browser.availability(domain) !== "off");
    const cached = [];
    for (const domain of domains) {
      for await (const session of ctx.browser.sessions(domain, { cachedOnly: true })) {
        cached.push({ domain, session });
        break;
      }
    }
    cached.sort((a, b) => (b.session.cachedAt ?? 0) - (a.session.cachedAt ?? 0));
    async function* candidates() {
      yield* cached;
      // Retain global then China profile order across the supported browsers.
      for (const domain of domains) {
        for await (const session of ctx.browser.sessions(domain)) yield { domain, session };
      }
    }
    for await (const { domain, session } of candidates()) {
      try {
        const response = await ctx.http.get(`${session.origin}/api/v2/me/usages/big_model_credits`, {
          timeoutSeconds,
          headers: headersFor(session),
        });
        if (response.status === 401 || response.status === 403) {
          rejected = true;
          ctx.browser.rejectCookie(domain, session);
          if (manual)
            throw ctx.fail.authenticationExpired("Qoder session is invalid or expired. Please sign in to Qoder again.");
          continue;
        }
        if (response.status < 200 || response.status >= 300)
          throw ctx.fail.apiFailure(`Qoder API returned HTTP ${response.status}.`);
        const source = session.source.endsWith(` / ${domain}`) ? session.source : `${session.source} / ${domain}`;
        const member = parseMember(response.bodyText, source);
        if (member.planTotal > 0) return member.snapshot;

        // Phase 1: the usage presentation covers the captured Teams account, whose merged
        // member quota is empty. It remains an optional same-session request; failures fall back to
        // the member snapshot. Always-fetching it for non-empty plans is a follow-up.
        // Reserve at least one second of the runtime deadline so the optional request cannot
        // consume the valid member snapshot.
        const remainingMs = hostDeadline > 0 ? hostDeadline - Date.now() : Infinity;
        if (remainingMs < 1000) return member.snapshot;
        const presentationTimeoutSeconds = Math.max(
          1,
          Math.min(3, timeoutSeconds, hostDeadline > 0 ? Math.floor((remainingMs - 500) / 1000) : 3),
        );
        try {
          const presentationResponse = await ctx.http.get(`${session.origin}/sash/api/v2/me/usage`, {
            timeoutSeconds: presentationTimeoutSeconds,
            headers: headersFor(session),
          });
          if (presentationResponse.status >= 200 && presentationResponse.status < 300) {
            const presentation = parsePresentation(presentationResponse.bodyText, source, member);
            if (presentation != null) return presentation;
          }
        } catch (error) {
          if (error.transportClass === "cancelled") throw error;
        }
        return member.snapshot;
      } catch (error) {
        if (error.transportClass === "cancelled" || manual) throw error;
        terminalError = error;
      }
    }
    if (terminalError) throw terminalError;
    if (rejected)
      throw ctx.fail.authenticationExpired("Qoder session is invalid or expired. Please sign in to Qoder again.");
    throw ctx.fail.missingCredential(
      `Qoder session cookie not found. Sign in to qoder.com or qoder.com.cn. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste a Cookie header.`,
    );
  },
});
