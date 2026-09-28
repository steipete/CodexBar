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
    const text = (value) => (typeof value === "string" ? value : undefined);
    const invalid = (message) => {
      throw ctx.fail.parseFailure(`Could not parse Notion usage: ${message}`);
    };
    const unwrap = (value) => {
      const outer = object(value);
      const inner = object(_optionalChain([outer, "optionalAccess", (_) => _.value]));
      return _nullishCoalesce(
        _nullishCoalesce(object(_optionalChain([inner, "optionalAccess", (_2) => _2.value])), () => inner),
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
      const used = numeric(value.used),
        limit = numeric(value.limit);
      if (used === undefined || limit === undefined || limit <= 0) return undefined;
      let windowMinutes;
      let resetsAt;
      if (rolling) {
        const token = _optionalChain([
          text,
          "call",
          (_3) => _3(value.window),
          "optionalAccess",
          (_4) => _4.trim,
          "call",
          (_5) => _5(),
          "access",
          (_6) => _6.toLowerCase,
          "call",
          (_7) => _7(),
        ]);
        const parts = _optionalChain([
          token,
          "optionalAccess",
          (_8) => _8.match,
          "call",
          (_9) => _9(/^([1-9][0-9]*)([mhdw])$/),
        ]);
        if (parts) {
          const minutes = Number(parts[1]) * _nullishCoalesce({ m: 1, h: 60, d: 1440, w: 10080 }[parts[2]], () => 0);
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
        const spaces = await post("getSpaces", {});
        const ids = Object.keys(spaces).filter(
          (id) =>
            _optionalChain([
              unwrap,
              "call",
              (_10) =>
                _10(
                  _optionalChain([
                    object,
                    "call",
                    (_11) =>
                      _11(
                        _optionalChain([
                          object,
                          "call",
                          (_12) => _12(spaces[id]),
                          "optionalAccess",
                          (_13) => _13.notion_user,
                        ]),
                      ),
                    "optionalAccess",
                    (_14) => _14[id],
                  ]),
                ),
              "optionalAccess",
              (_15) => _15.id,
            ]) === id,
        );
        const userID =
          ids.length === 1
            ? ids[0]
            : ids.length === 0 && Object.keys(spaces).length === 1
              ? Object.keys(spaces)[0]
              : undefined;
        if (!userID) return invalid("getSpaces response did not identify a single user");
        const container = _nullishCoalesce(object(spaces[userID]), () => invalid("getSpaces user is not an object"));
        const users = _nullishCoalesce(object(container.notion_user), () => ({}));
        const user = _nullishCoalesce(unwrap(users[userID]), () => Object.values(users).map(unwrap).find(Boolean));
        const records = _nullishCoalesce(object(container.space), () => ({}));
        const workspaces = Object.keys(records)
          .sort()
          .flatMap((key) => {
            const record = unwrap(records[key]);
            return record ? [{ ...record, id: _nullishCoalesce(text(record.id), () => key) }] : [];
          });
        const preferred = ctx.settings.get("WORKSPACE_ID");
        const workspace = _nullishCoalesce(
          _nullishCoalesce(
            preferred ? workspaces.find((space) => normalize(space.id) === normalize(preferred)) : undefined,
            () =>
              workspaces.find((space) =>
                ["business", "enterprise"].includes(
                  _nullishCoalesce(
                    _optionalChain([
                      text,
                      "call",
                      (_16) => _16(space.subscription_tier),
                      "optionalAccess",
                      (_17) => _17.toLowerCase,
                      "call",
                      (_18) => _18(),
                    ]),
                    () => "",
                  ),
                ),
              ),
          ),
          () => workspaces[0],
        );
        if (!workspace) throw ctx.fail.apiFailure("No Notion workspace found for this account.");
        const usage = await post("getCreditRateLimitStatus", { spaceId: workspace.id });
        for (const field of ["status", "enforcement"]) {
          if (usage[field] != null && typeof usage[field] !== "string") return invalid(`invalid ${field}`);
        }
        numeric(usage.resetsInSeconds);
        for (const raw of [usage.window, usage.billingPeriodWindow]) {
          if (raw == null) continue;
          const value = _nullishCoalesce(object(raw), () => invalid("window is not an object"));
          for (const field of ["creditType", "scope", "window", "cadence"]) {
            if (value[field] != null && typeof value[field] !== "string") return invalid(`invalid ${field}`);
          }
          for (const field of ["used", "limit", "periodEndMs"]) numeric(value[field]);
        }
        if (
          _optionalChain([
            text,
            "call",
            (_19) => _19(usage.status),
            "optionalAccess",
            (_20) => _20.toLowerCase,
            "call",
            (_21) => _21(),
          ]) === "not_applicable"
        )
          throw ctx.fail.apiFailure(
            "Notion AI usage allowance is not tracked for this workspace. Allowances apply to Business and Enterprise workspaces.",
          );
        if (usage.window == null && usage.billingPeriodWindow == null)
          return invalid("getCreditRateLimitStatus returned no usage windows");
        const primary = window(usage.window, true, usage.resetsInSeconds);
        const secondary = window(usage.billingPeriodWindow, false, undefined);
        const tier = _optionalChain([
          text,
          "call",
          (_22) => _22(workspace.subscription_tier),
          "optionalAccess",
          (_23) => _23.trim,
          "call",
          (_24) => _24(),
        ]);
        const result = {
          primary,
          secondary,
          empty: !primary && !secondary,
          identity: {
            email: text(_optionalChain([user, "optionalAccess", (_25) => _25.email])),
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
