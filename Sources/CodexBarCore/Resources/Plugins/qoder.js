defineProvider({
  id: "qoder",
  name: "Qoder",
  endpoints: ["https://qoder.com", "https://qoder.com.cn"],
  settings: [{ key: "REQUEST_TIMEOUT", title: "Request timeout", type: "plain" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["qoder.com", "qoder.com.cn"],
  async fetchUsage(ctx) {
    const startedAt = ctx.date.nowMillis();
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
      return { used, total, remaining, provided };
    };
    const presentationQuota = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return null;
      const used = value.used;
      const total = value.total ?? value.cap ?? value.limitValue ?? value.limit_value;
      const remainingValue = value.remaining ?? value.remainingValue ?? value.remaining_value;
      if (typeof used !== "number" || !Number.isFinite(used)) return null;
      if (typeof total !== "number" || !Number.isFinite(total)) return null;
      let remaining;
      if (remainingValue == null) {
        remaining = undefined;
      } else if (typeof remainingValue === "number" && Number.isFinite(remainingValue)) {
        remaining = remainingValue;
      } else {
        return null;
      }
      if (used < 0 || total < 0 || (remaining != null && remaining < 0)) return null;
      return { used, total, remaining };
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
      const container = object(field(root, "totalQuota", "total_quota"));
      const sharedContainer = field(root, "sharedQuota", "shared_quota");
      if (sharedContainer != null) object(sharedContainer);
      const base = quota(container && field(container, "quotaSummary", "quota_summary"));
      const sharedSummary = sharedContainer && field(sharedContainer, "quotaSummary", "quota_summary");
      const shared = sharedSummary == null ? null : quota(sharedSummary);
      const used = base.used + (shared?.used ?? 0);
      const total = base.total + (shared?.total ?? 0);
      const remaining = base.remaining + (shared?.remaining ?? 0);
      const provided = shared ? null : base.provided;
      if (total === 0 && (used !== 0 || remaining !== 0)) fail("zero total quota must have zero usage and remaining");
      const percentage = total === 0 ? 100 : (provided ?? (used / total) * 100);
      number(percentage);
      const resetsAt = parseDate(field(root, "nextResetAt", "next_reset_at"));
      return {
        snapshot: {
          primary: {
            usedPercent: clamp(percentage),
            resetsAt,
            resetDescription: `${format(used)} / ${format(total)} credits`,
          },
          identity: { loginMethod: source },
        },
        planTotal: total,
      };
    };
    const parseOrganization = (body, member) => {
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
      if (usage.userType !== "teams") return null;
      const orgValue = usage.orgResourcePackage;
      if (!orgValue || typeof orgValue !== "object" || Array.isArray(orgValue)) return null;
      if (orgValue.available === false) return null;
      const org = presentationQuota(orgValue);
      if (org == null || org.total <= 0) return null;

      let usedPercent;
      if (org.remaining != null && org.remaining > 0) {
        usedPercent = (1 - org.remaining / org.total) * 100;
      } else if (org.remaining === 0 || usage.isQuotaExceeded === true) {
        usedPercent = 100;
      } else {
        usedPercent = (org.used / org.total) * 100;
      }
      const refresh = parseDate(usage.refreshAt) ?? parseDate(usage.expiresAt) ?? member.snapshot.primary.resetsAt;
      let displayUsed;
      if (org.remaining != null) {
        displayUsed = Math.max(0, org.total - org.remaining);
      } else if (usage.isQuotaExceeded !== true) {
        displayUsed = org.used;
      }
      const secondary = { usedPercent: clamp(usedPercent) };
      if (displayUsed !== undefined) {
        secondary.resetDescription = `${format(displayUsed)} / ${format(org.total)} credits`;
      }
      const snapshot = {
        primary: { ...member.snapshot.primary, resetsAt: refresh },
        secondary,
        identity: member.snapshot.identity,
      };
      return snapshot;
    };
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
    const timeoutSeconds = Number(ctx.settings.get("REQUEST_TIMEOUT") || 15);
    for await (const { domain, session } of candidates()) {
      try {
        const headers = {
          Cookie: session.header,
          Accept: "application/json, text/plain, */*",
          "Accept-Language": "en-US,en;q=0.9",
          "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
          Origin: session.origin,
          Referer: `${session.origin}/account/usage`,
          "X-Requested-With": "XMLHttpRequest",
          "Bx-V": "2.5.35",
        };
        const response = await ctx.http.get(`${session.origin}/api/v2/me/usages/big_model_credits`, {
          timeoutSeconds,
          headers,
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

        // The supplemental request is only for the captured empty-member Teams shape.
        // Keep four seconds of the runtime deadline for returning the member snapshot.
        if (Date.now() - startedAt > 16000) return member.snapshot;
        try {
          const presentationResponse = await ctx.http.get(`${session.origin}/sash/api/v2/me/usage`, {
            timeoutSeconds: Math.min(timeoutSeconds, 3),
            headers,
          });
          if (presentationResponse.status >= 200 && presentationResponse.status < 300) {
            const presentation = parseOrganization(presentationResponse.bodyText, member);
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
