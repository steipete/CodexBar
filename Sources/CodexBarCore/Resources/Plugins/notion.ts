defineProvider({
  id: "notion",
  name: "Notion AI",
  settings: [
    { key: "WORKSPACE_ID", title: "Workspace ID", type: "plain" },
    { key: "HEADERS", title: "Captured headers", type: "secure" },
  ],
  endpoints: ["https://app.notion.com"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["app.notion.com", "www.notion.com", "notion.com", "www.notion.so", "notion.so"],
  cookiePolicy: {
    selection: "ranked-source-domains",
    sourceDomains: ["app.notion.com", "www.notion.com", "notion.com", "www.notion.so", "notion.so"],
    requiredCookies: ["token_v2"],
    cache: "validated-single-entry",
    imports: "access-gated",
    sessionFile: { tokenField: "tokenV2", cookieName: "token_v2" },
  },
  snapshotPolicy: { percent: "preserve-overage" },
  async fetchUsage(ctx) {
    type ObjectValue = Record<string, unknown>;
    const object = (value: unknown): ObjectValue | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? (value as ObjectValue) : undefined;
    const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
    const invalid = (message: string): never => {
      throw ctx.fail.parseFailure(`Could not parse Notion usage: ${message}`);
    };
    const unwrap = (value: unknown): ObjectValue | undefined => {
      const outer = object(value);
      const inner = object(outer?.value);
      return object(inner?.value) ?? inner ?? outer;
    };
    const normalize = (value: string): string => value.trim().replace(/-/g, "").toLowerCase();
    const domain = "app.notion.com";
    const availability = ctx.browser.availability(domain);
    if (availability === "off") throw ctx.fail.missingCredential("Notion cookies are disabled.");
    const headers: Record<string, string> = {
      Accept: "*/*",
      "Accept-Language": "en-US,en;q=0.9",
      Referer: "https://app.notion.com/",
      "Sec-Fetch-Dest": "empty",
      "Sec-Fetch-Mode": "cors",
      "Sec-Fetch-Site": "same-origin",
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
      ...JSON.parse(ctx.settings.getSecret("HEADERS") || "{}"),
      Origin: "https://app.notion.com",
    };
    const numeric = (value: unknown): number | undefined => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isFinite(value) ? value : invalid("invalid numeric field");
    };
    const window = (raw: unknown, rolling: boolean, resets: unknown): CodexBarRateWindow | undefined => {
      if (raw === undefined || raw === null) return undefined;
      const value = object(raw) ?? invalid("window is not an object");
      const used = numeric(value.used),
        limit = numeric(value.limit);
      if (used === undefined || limit === undefined || limit <= 0) return undefined;
      let windowMinutes: number | undefined;
      let resetsAt: Date | undefined;
      if (rolling) {
        const token = text(value.window)?.trim().toLowerCase();
        const parts = token?.match(/^([1-9][0-9]*)([mhdw])$/);
        if (parts) {
          const minutes = Number(parts[1]) * ({ m: 1, h: 60, d: 1440, w: 10080 }[parts[2]] ?? 0);
          if (Number.isSafeInteger(minutes) && minutes !== 43200) windowMinutes = minutes;
        }
        const seconds = numeric(resets);
        if (seconds !== undefined && seconds >= 0) resetsAt = new Date(ctx.date.now().getTime() + seconds * 1000);
      } else {
        windowMinutes = 43200;
        const end = numeric(value.periodEndMs);
        if (end !== undefined && end > 0) resetsAt = new Date(end);
      }
      return { usedPercent: Math.max(0, (used / limit) * 100), windowMinutes, resetsAt };
    };
    for await (const session of ctx.browser.sessions(domain)) {
      const post = async (endpoint: string, body: Record<string, string>): Promise<ObjectValue> => {
        const response = await ctx.http.post(`https://${domain}/api/v3/${endpoint}`, {
          body,
          headers,
          cookieSession: session.id,
        });
        if (response.status === 401)
          throw Object.assign(ctx.fail.authenticationExpired("Notion session cookie is invalid or expired."), {
            failureKind: "authentication-expired",
          });
        if (response.status !== 200) throw ctx.fail.apiFailure(`Notion HTTP ${response.status} from ${endpoint}`);
        let parsed: unknown;
        try {
          parsed = JSON.parse(response.bodyText);
        } catch (error) {
          void error;
          return invalid(`${endpoint} returned invalid JSON`);
        }
        return object(parsed) ?? invalid(`${endpoint} response is not an object`);
      };
      try {
        const spaces = await post("getSpaces", {});
        const ids = Object.keys(spaces).filter(
          (id) => unwrap(object(object(spaces[id])?.notion_user)?.[id])?.id === id,
        );
        const userID =
          ids.length === 1
            ? ids[0]
            : ids.length === 0 && Object.keys(spaces).length === 1
              ? Object.keys(spaces)[0]
              : undefined;
        if (!userID) return invalid("getSpaces response did not identify a single user");
        const container = object(spaces[userID]) ?? invalid("getSpaces user is not an object");
        const users = object(container.notion_user) ?? {};
        const user = unwrap(users[userID]) ?? Object.values(users).map(unwrap).find(Boolean);
        const records = object(container.space) ?? {};
        const workspaces: Array<ObjectValue & { id: string }> = Object.keys(records)
          .sort()
          .flatMap((key) => {
            const record = unwrap(records[key]);
            return record ? [{ ...record, id: text(record.id) ?? key }] : [];
          });
        const preferred = ctx.settings.get("WORKSPACE_ID");
        const workspace =
          (preferred ? workspaces.find((space) => normalize(space.id) === normalize(preferred)) : undefined) ??
          workspaces.find((space) =>
            ["business", "enterprise"].includes(text(space.subscription_tier)?.toLowerCase() ?? ""),
          ) ??
          workspaces[0];
        if (!workspace) throw ctx.fail.apiFailure("No Notion workspace found for this account.");
        const usage = await post("getCreditRateLimitStatus", { spaceId: workspace.id });
        for (const field of ["status", "enforcement"]) {
          if (usage[field] != null && typeof usage[field] !== "string") return invalid(`invalid ${field}`);
        }
        numeric(usage.resetsInSeconds);
        for (const raw of [usage.window, usage.billingPeriodWindow]) {
          if (raw == null) continue;
          const value = object(raw) ?? invalid("window is not an object");
          for (const field of ["creditType", "scope", "window", "cadence"]) {
            if (value[field] != null && typeof value[field] !== "string") return invalid(`invalid ${field}`);
          }
          for (const field of ["used", "limit", "periodEndMs"]) numeric(value[field]);
        }
        if (text(usage.status)?.toLowerCase() === "not_applicable")
          throw ctx.fail.apiFailure(
            "Notion AI usage allowance is not tracked for this workspace. Allowances apply to Business and Enterprise workspaces.",
          );
        if (usage.window == null && usage.billingPeriodWindow == null)
          return invalid("getCreditRateLimitStatus returned no usage windows");
        const primary = window(usage.window, true, usage.resetsInSeconds);
        const secondary = window(usage.billingPeriodWindow, false, undefined);
        const tier = text(workspace.subscription_tier)?.trim();
        const result = {
          primary,
          secondary,
          empty: !primary && !secondary,
          identity: {
            email: text(user?.email),
            accountID: userID,
            organization: text(workspace.name),
            loginMethod: tier ? tier[0].toUpperCase() + tier.slice(1) : undefined,
          },
        };
        if (availability !== "manual") ctx.browser.acceptCookie(domain, session);
        return result;
      } catch (error) {
        if ((error as { failureKind?: string }).failureKind !== "authentication-expired") throw error;
        ctx.browser.rejectCookie(domain, session);
        if (session.cachedAt === undefined) throw error;
      }
    }
    throw ctx.fail.missingCredential("No Notion cookies found. Sign in to Notion and refresh once to import them.");
  },
});
