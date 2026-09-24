defineProvider({
  id: "manus",
  name: "Manus",
  endpoints: ["https://api.manus.im"],
  settings: [{ key: "SESSION_TOKEN", title: "Environment session", type: "secure" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["manus.im"],
  async fetchUsage(ctx) {
    const domain = "manus.im";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("Manus cookies are disabled.");
    const attempted = new Set();
    let rejected = false;
    const attempt = async (raw) => {
      const header = (raw || "").trim();
      const match = /(?:^|;)\s*session_id\s*=\s*([^;]+)/i.exec(header);
      const token = match ? match[1].trim() : !/[=;]/.test(header) ? header : "";
      if (!token || attempted.has(token)) return undefined;
      attempted.add(token);
      const response = await ctx.http.post("https://api.manus.im/user.v1.UserService/GetAvailableCredits", {
        body: {},
        headers: {
          Authorization: `Bearer ${token}`,
          Origin: "https://manus.im",
          Referer: "https://manus.im/",
          "Connect-Protocol-Version": "1",
          "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
        },
      });
      if (response.status === 401 || response.status === 403) {
        rejected = true;
        return undefined;
      }
      if (response.status !== 200) throw ctx.fail.apiFailure(`Manus API error: HTTP ${response.status}`);
      try {
        return JSON.parse(response.bodyText);
      } catch {
        throw ctx.fail.parseFailure("Failed to parse Manus response: invalid JSON");
      }
    };
    let root;
    for await (const session of ctx.browser.sessions(domain)) {
      root = await attempt(session.header);
      if (root !== undefined) break;
      ctx.browser.rejectCookie(domain, session);
    }
    if (root === undefined && policy !== "manual") root = await attempt(ctx.settings.getSecret("SESSION_TOKEN"));
    if (root === undefined) {
      if (rejected) throw ctx.fail.authenticationExpired("Invalid Manus session token.");
      throw ctx.fail.missingCredential(
        policy === "manual" ? "Manus session cookie is invalid." : "No Manus session token provided.",
      );
    }
    const data = root?.data ?? root?.result ?? root?.response ?? root?.availableCredits ?? root;
    const creditKeys = [
      "totalCredits",
      "freeCredits",
      "periodicCredits",
      "addonCredits",
      "refreshCredits",
      "maxRefreshCredits",
      "proMonthlyCredits",
      "eventCredits",
    ];
    if (
      !data ||
      typeof data !== "object" ||
      Array.isArray(data) ||
      !creditKeys.some((key) => Object.prototype.hasOwnProperty.call(data, key))
    ) {
      throw ctx.fail.parseFailure("Manus response missing expected credits fields");
    }
    const number = (key) => {
      const value = typeof data[key] === "number" || typeof data[key] === "string" ? Number(data[key]) : 0;
      return Number.isFinite(value) ? value : 0;
    };
    // Legacy numeric reset dates use Foundation’s 2001 reference epoch.
    const reset = data.nextRefreshTime;
    const resetDate =
      typeof reset === "number"
        ? ctx.date.unixSeconds(reset + 978307200)
        : typeof reset === "string" && /^\d{4}-\d{2}-\d{2}T/.test(reset) && Number.isFinite(Date.parse(reset))
          ? ctx.date.iso(reset)
          : undefined;
    const total = number("totalCredits");
    const free = number("freeCredits");
    const monthly = number("proMonthlyCredits");
    const periodic = number("periodicCredits");
    const refresh = number("refreshCredits");
    const maxRefresh = number("maxRefreshCredits");
    const format = (value) =>
      ctx.format.number(Math.sign(value) * Math.round(Math.abs(value)), { maximumFractionDigits: 0 });
    return {
      primary:
        monthly > 0
          ? {
              usedPercent: ctx.pct(monthly - periodic, monthly),
              resetDescription: `Total ${format(total)} • Free ${format(free)}`,
            }
          : undefined,
      secondary:
        maxRefresh > 0
          ? {
              usedPercent: ctx.pct(maxRefresh - refresh, maxRefresh),
              resetsAt: resetDate,
              resetDescription:
                typeof data.refreshInterval === "string" && data.refreshInterval
                  ? `${data.refreshInterval.toLowerCase().replace(/\b[a-z]/g, (value) => value.toUpperCase())}: ${format(refresh)} / ${format(maxRefresh)}`
                  : `${format(refresh)} / ${format(maxRefresh)}`,
            }
          : undefined,
      identity: { loginMethod: `Balance: ${format(total)} credits` },
    };
  },
});
