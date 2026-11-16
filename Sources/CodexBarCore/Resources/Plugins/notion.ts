defineProvider({
  id: "notion",
  name: "Notion AI",
  settings: [
    { key: "WORKSPACE_ID", title: "Workspace ID", type: "plain" },
    { key: "OPTIONAL_USAGE", title: "Optional usage", type: "plain" },
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
    const table = (value: unknown, key: string): ObjectValue => object(object(value)?.[key]) ?? {};
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
    const window = (raw: unknown, rolling: boolean, resets: number | undefined): CodexBarRateWindow | undefined => {
      if (raw === undefined || raw === null) return undefined;
      const value = object(raw) ?? invalid("window is not an object");
      for (const field of ["creditType", "scope", "window", "cadence"]) {
        if (value[field] != null && typeof value[field] !== "string") return invalid(`invalid ${field}`);
      }
      const used = numeric(value.used),
        limit = numeric(value.limit),
        end = numeric(value.periodEndMs);
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
        if (resets !== undefined && resets >= 0) resetsAt = new Date(ctx.date.now().getTime() + resets * 1000);
      } else {
        windowMinutes = 43200;
        if (end !== undefined && end > 0) resetsAt = new Date(end);
      }
      return {
        usedPercent: Math.max(0, (used / limit) * 100),
        windowMinutes,
        resetsAt,
        quotaLimit: limit,
        quotaUnit: "credits",
      };
    };
    // November's personal pools coexist with a top-level legacy status of not_applicable.
    // Treat each resolved billing-period bucket independently; never infer a missing allowance.
    const personalAllowance = (
      raw: unknown,
      bucketID: string,
      title: string,
    ): { window: CodexBarRateWindow; remaining?: CodexBarDetailRow } | undefined => {
      if (!Array.isArray(raw)) return undefined;
      const matches = raw
        .map(object)
        .filter((entry) => entry?.bucketId === bucketID && entry.cadence === "billing_period");
      const entry = matches.length === 1 ? matches[0] : undefined;
      if (!entry || entry.state !== "resolved") return undefined;
      const finite = (value: unknown): number | undefined =>
        typeof value === "number" && Number.isFinite(value) ? value : undefined;
      const used = finite(entry.used),
        limit = finite(entry.limit);
      if (used === undefined || used < 0 || limit === undefined || limit <= 0) return undefined;
      const percent = (used / limit) * 100;
      if (!Number.isFinite(percent)) return undefined;
      const credits = object(entry.credits);
      const creditUsed = finite(credits?.used),
        creditLimit = finite(credits?.limit);
      const hasCredits =
        creditUsed !== undefined &&
        creditUsed >= 0 &&
        creditLimit !== undefined &&
        creditLimit > 0 &&
        Number.isFinite((creditUsed / creditLimit) * 100);
      const start = finite(entry.periodStartMs),
        end = finite(entry.periodEndMs);
      const resetsAt =
        end !== undefined && end > 0 && Number.isFinite(new Date(end).getTime()) ? new Date(end) : undefined;
      const minutes = start !== undefined && start > 0 && end !== undefined ? (end - start) / 60000 : undefined;
      const windowMinutes = minutes !== undefined && Number.isSafeInteger(minutes) && minutes > 0 ? minutes : undefined;
      return {
        window: {
          title,
          // The credit counts retain more precision than the rounded percentage-scale fields.
          usedPercent: hasCredits ? (creditUsed / creditLimit) * 100 : percent,
          windowMinutes,
          resetsAt,
          quotaLimit: hasCredits ? creditLimit : undefined,
          quotaUnit: hasCredits ? "credits" : undefined,
        },
        remaining: hasCredits
          ? {
              label: `${title} remaining`,
              value: `${ctx.format.number(Math.max(0, creditLimit - creditUsed))} credits`,
              secondaryValue: `${ctx.format.number(creditUsed)} / ${ctx.format.number(creditLimit)} used`,
              usageValue: creditUsed,
            }
          : undefined,
      };
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
        const preferred = normalize(ctx.settings.get("WORKSPACE_ID") || "");
        let userID: string | undefined;
        let user: ObjectValue | undefined;
        let workspace: (ObjectValue & { id: string }) | undefined;
        try {
          const spaces = await post("getSpaces", {});
          const ids = Object.keys(spaces).filter((id) => unwrap(table(spaces[id], "notion_user")[id])?.id === id);
          userID =
            ids.length === 1
              ? ids[0]
              : ids.length === 0 && Object.keys(spaces).length === 1
                ? Object.keys(spaces)[0]
                : undefined;
          if (!userID) return invalid("getSpaces response did not identify a single user");
          const container = object(spaces[userID]) ?? invalid("getSpaces user is not an object");
          const users = table(container, "notion_user");
          user = unwrap(users[userID]) ?? Object.values(users).map(unwrap).find(Boolean);
          const records = table(container, "space");
          const workspaces: Array<ObjectValue & { id: string }> = Object.keys(records)
            .sort()
            .flatMap((key) => {
              const record = unwrap(records[key]);
              return record ? [{ ...record, id: text(record.id) ?? key }] : [];
            });
          workspace =
            (preferred ? workspaces.find((space) => normalize(space.id) === preferred) : undefined) ??
            workspaces.find((space) =>
              ["business", "enterprise"].includes(text(space.subscription_tier)?.toLowerCase() ?? ""),
            ) ??
            workspaces[0];
        } catch (error) {
          // A pinned workspace can fetch allowances without the oversized identity record map.
          if (!/Provider plugin HTTP error: response exceeded the \d+-byte limit/.test(String(error))) throw error;
          if (!/^[a-f0-9]{32}$/.test(preferred))
            throw ctx.fail.apiFailure(
              "Notion workspace discovery is too large. Set Workspace ID to a valid workspace UUID in Notion AI settings.",
            );
          workspace = { id: preferred.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, "$1-$2-$3-$4-$5") };
        }
        if (!workspace) throw ctx.fail.apiFailure("No Notion workspace found for this account.");
        const usage = await post("getCreditRateLimitStatus", { spaceId: workspace.id });
        const standard = personalAllowance(usage.allowances, "auto", "Standard");
        const select = personalAllowance(usage.allowances, "flex", "Select");
        let primary: CodexBarRateWindow | undefined;
        let secondary: CodexBarRateWindow | undefined;
        if (standard || select) {
          primary = standard?.window;
          secondary = select?.window;
        } else {
          for (const field of ["status", "enforcement"]) {
            if (usage[field] != null && typeof usage[field] !== "string") return invalid(`invalid ${field}`);
          }
          const resets = numeric(usage.resetsInSeconds);
          primary = window(usage.window, true, resets);
          secondary = window(usage.billingPeriodWindow, false, undefined);
          if (text(usage.status)?.toLowerCase() === "not_applicable") {
            const personalSchema =
              Array.isArray(usage.allowances) &&
              usage.allowances.some((entry) => ["auto", "flex"].includes(text(object(entry)?.bucketId) ?? ""));
            if (!personalSchema)
              throw ctx.fail.apiFailure(
                "Notion AI usage allowance is not tracked for this workspace. Allowances apply to Business and Enterprise workspaces.",
              );
            if (!primary && !secondary)
              throw ctx.fail.apiFailure("Notion AI personal allowances are not resolved for this workspace.");
          }
          if (usage.window == null && usage.billingPeriodWindow == null)
            return invalid("getCreditRateLimitStatus returned no usage windows");
        }
        // Premium credits are a separate workspace balance, not an allowance window.
        // Keep this request independent of session validation and required allowance parsing.
        const details: CodexBarDetailSection[] = [];
        const personalRows = [standard?.remaining, select?.remaining].filter(
          (row): row is CodexBarDetailRow => row !== undefined,
        );
        if (personalRows.length) details.push({ title: "Personal credits", rows: personalRows });
        if (ctx.settings.get("OPTIONAL_USAGE") !== "false") {
          try {
            const response = await ctx.http.post(`https://${domain}/api/v3/getAIUsageEligibilityV2`, {
              body: { spaceId: workspace.id },
              headers,
              cookieSession: session.id,
              timeoutSeconds: 3,
            });
            if (response.status === 200) {
              const premium = object(object(JSON.parse(response.bodyText))?.premiumCredits);
              const balance = premium?.totalCreditBalance;
              if (typeof balance === "number" && Number.isFinite(balance)) {
                details.push({
                  title: "Notion Credits",
                  rows: [{ label: "Remaining credits", value: ctx.format.number(balance) }],
                });
              }
            }
          } catch (error) {
            if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
            // Missing, unsupported or malformed premium-credit data must not hide the allowances.
          }
        }
        const tier = text(workspace.subscription_tier)?.trim();
        const result = {
          primary,
          secondary,
          details,
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
