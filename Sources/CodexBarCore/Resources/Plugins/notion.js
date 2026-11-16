function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
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
    const object = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    const table = (value, key) =>
      _nullishCoalesce(
        object(_optionalChain([object, "call", (_) => _(value), "optionalAccess", (_2) => _2[key]])),
        () => ({}),
      );
    const text = (value) => (typeof value === "string" ? value : undefined);
    const invalid = (message) => {
      throw ctx.fail.parseFailure(`Could not parse Notion usage: ${message}`);
    };
    const unwrap = (value) => {
      const outer = object(value);
      const inner = object(_optionalChain([outer, "optionalAccess", (_3) => _3.value]));
      return _nullishCoalesce(
        _nullishCoalesce(object(_optionalChain([inner, "optionalAccess", (_4) => _4.value])), () => inner),
        () => outer,
      );
    };
    const normalize = (value) => value.trim().replace(/-/g, "").toLowerCase();
    const domain = "app.notion.com";
    const availability = ctx.browser.availability(domain);
    if (availability === "off") throw ctx.fail.missingCredential("Notion cookies are disabled.");
    const headers = {
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
    const numeric = (value) => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isFinite(value) ? value : invalid("invalid numeric field");
    };
    const window = (raw, rolling, resets) => {
      if (raw === undefined || raw === null) return undefined;
      const value = _nullishCoalesce(object(raw), () => invalid("window is not an object"));
      for (const field of ["creditType", "scope", "window", "cadence"]) {
        if (value[field] != null && typeof value[field] !== "string") return invalid(`invalid ${field}`);
      }
      const used = numeric(value.used),
        limit = numeric(value.limit),
        end = numeric(value.periodEndMs);
      if (used === undefined || limit === undefined || limit <= 0) return undefined;
      let windowMinutes;
      let resetsAt;
      if (rolling) {
        const token = _optionalChain([
          text,
          "call",
          (_5) => _5(value.window),
          "optionalAccess",
          (_6) => _6.trim,
          "call",
          (_7) => _7(),
          "access",
          (_8) => _8.toLowerCase,
          "call",
          (_9) => _9(),
        ]);
        const parts = _optionalChain([
          token,
          "optionalAccess",
          (_10) => _10.match,
          "call",
          (_11) => _11(/^([1-9][0-9]*)([mhdw])$/),
        ]);
        if (parts) {
          const minutes = Number(parts[1]) * _nullishCoalesce({ m: 1, h: 60, d: 1440, w: 10080 }[parts[2]], () => 0);
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
    const personalAllowance = (raw, bucketID, title) => {
      if (!Array.isArray(raw)) return undefined;
      const matches = raw
        .map(object)
        .filter(
          (entry) =>
            _optionalChain([entry, "optionalAccess", (_12) => _12.bucketId]) === bucketID &&
            entry.cadence === "billing_period",
        );
      const entry = matches.length === 1 ? matches[0] : undefined;
      if (!entry || entry.state !== "resolved") return undefined;
      const finite = (value) => (typeof value === "number" && Number.isFinite(value) ? value : undefined);
      const used = finite(entry.used),
        limit = finite(entry.limit);
      if (used === undefined || used < 0 || limit === undefined || limit <= 0) return undefined;
      const percent = (used / limit) * 100;
      if (!Number.isFinite(percent)) return undefined;
      const credits = object(entry.credits);
      const creditUsed = finite(_optionalChain([credits, "optionalAccess", (_13) => _13.used])),
        creditLimit = finite(_optionalChain([credits, "optionalAccess", (_14) => _14.limit]));
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
      const post = async (endpoint, body) => {
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
        let parsed;
        try {
          parsed = JSON.parse(response.bodyText);
        } catch (error) {
          void error;
          return invalid(`${endpoint} returned invalid JSON`);
        }
        return _nullishCoalesce(object(parsed), () => invalid(`${endpoint} response is not an object`));
      };
      try {
        const preferred = normalize(ctx.settings.get("WORKSPACE_ID") || "");
        let userID;
        let user;
        let workspace;
        try {
          const spaces = await post("getSpaces", {});
          const ids = Object.keys(spaces).filter(
            (id) =>
              _optionalChain([
                unwrap,
                "call",
                (_15) => _15(table(spaces[id], "notion_user")[id]),
                "optionalAccess",
                (_16) => _16.id,
              ]) === id,
          );
          userID =
            ids.length === 1
              ? ids[0]
              : ids.length === 0 && Object.keys(spaces).length === 1
                ? Object.keys(spaces)[0]
                : undefined;
          if (!userID) return invalid("getSpaces response did not identify a single user");
          const container = _nullishCoalesce(object(spaces[userID]), () => invalid("getSpaces user is not an object"));
          const users = table(container, "notion_user");
          user = _nullishCoalesce(unwrap(users[userID]), () => Object.values(users).map(unwrap).find(Boolean));
          const records = table(container, "space");
          const workspaces = Object.keys(records)
            .sort()
            .flatMap((key) => {
              const record = unwrap(records[key]);
              return record ? [{ ...record, id: _nullishCoalesce(text(record.id), () => key) }] : [];
            });
          workspace = _nullishCoalesce(
            _nullishCoalesce(
              preferred ? workspaces.find((space) => normalize(space.id) === preferred) : undefined,
              () =>
                workspaces.find((space) =>
                  ["business", "enterprise"].includes(
                    _nullishCoalesce(
                      _optionalChain([
                        text,
                        "call",
                        (_17) => _17(space.subscription_tier),
                        "optionalAccess",
                        (_18) => _18.toLowerCase,
                        "call",
                        (_19) => _19(),
                      ]),
                      () => "",
                    ),
                  ),
                ),
            ),
            () => workspaces[0],
          );
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
        let primary;
        let secondary;
        if (standard || select) {
          primary = _optionalChain([standard, "optionalAccess", (_20) => _20.window]);
          secondary = _optionalChain([select, "optionalAccess", (_21) => _21.window]);
        } else {
          for (const field of ["status", "enforcement"]) {
            if (usage[field] != null && typeof usage[field] !== "string") return invalid(`invalid ${field}`);
          }
          const resets = numeric(usage.resetsInSeconds);
          primary = window(usage.window, true, resets);
          secondary = window(usage.billingPeriodWindow, false, undefined);
          if (
            _optionalChain([
              text,
              "call",
              (_22) => _22(usage.status),
              "optionalAccess",
              (_23) => _23.toLowerCase,
              "call",
              (_24) => _24(),
            ]) === "not_applicable"
          ) {
            const personalSchema =
              Array.isArray(usage.allowances) &&
              usage.allowances.some((entry) =>
                ["auto", "flex"].includes(
                  _nullishCoalesce(
                    text(
                      _optionalChain([object, "call", (_25) => _25(entry), "optionalAccess", (_26) => _26.bucketId]),
                    ),
                    () => "",
                  ),
                ),
              );
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
        const details = [];
        const personalRows = [
          _optionalChain([standard, "optionalAccess", (_27) => _27.remaining]),
          _optionalChain([select, "optionalAccess", (_28) => _28.remaining]),
        ].filter((row) => row !== undefined);
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
              const premium = object(
                _optionalChain([
                  object,
                  "call",
                  (_29) => _29(JSON.parse(response.bodyText)),
                  "optionalAccess",
                  (_30) => _30.premiumCredits,
                ]),
              );
              const balance = _optionalChain([premium, "optionalAccess", (_31) => _31.totalCreditBalance]);
              if (typeof balance === "number" && Number.isFinite(balance)) {
                details.push({
                  title: "Notion Credits",
                  rows: [{ label: "Remaining credits", value: ctx.format.number(balance) }],
                });
              }
            }
          } catch (error) {
            if (error.transportClass === "cancelled") throw error;
            // Missing, unsupported or malformed premium-credit data must not hide the allowances.
          }
        }
        const tier = _optionalChain([
          text,
          "call",
          (_32) => _32(workspace.subscription_tier),
          "optionalAccess",
          (_33) => _33.trim,
          "call",
          (_34) => _34(),
        ]);
        const result = {
          primary,
          secondary,
          details,
          empty: !primary && !secondary,
          identity: {
            email: text(_optionalChain([user, "optionalAccess", (_35) => _35.email])),
            accountID: userID,
            organization: text(workspace.name),
            loginMethod: tier ? tier[0].toUpperCase() + tier.slice(1) : undefined,
          },
        };
        if (availability !== "manual") ctx.browser.acceptCookie(domain, session);
        return result;
      } catch (error) {
        if (error.failureKind !== "authentication-expired") throw error;
        ctx.browser.rejectCookie(domain, session);
        if (session.cachedAt === undefined) throw error;
      }
    }
    throw ctx.fail.missingCredential("No Notion cookies found. Sign in to Notion and refresh once to import them.");
  },
});
