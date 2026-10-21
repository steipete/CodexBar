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
                (_12) => _12(table(spaces[id], "notion_user")[id]),
                "optionalAccess",
                (_13) => _13.id,
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
                        (_14) => _14(space.subscription_tier),
                        "optionalAccess",
                        (_15) => _15.toLowerCase,
                        "call",
                        (_16) => _16(),
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
        for (const field of ["status", "enforcement"]) {
          if (usage[field] != null && typeof usage[field] !== "string") return invalid(`invalid ${field}`);
        }
        const resets = numeric(usage.resetsInSeconds);
        const primary = window(usage.window, true, resets);
        const secondary = window(usage.billingPeriodWindow, false, undefined);
        if (
          _optionalChain([
            text,
            "call",
            (_17) => _17(usage.status),
            "optionalAccess",
            (_18) => _18.toLowerCase,
            "call",
            (_19) => _19(),
          ]) === "not_applicable"
        )
          throw ctx.fail.apiFailure(
            "Notion AI usage allowance is not tracked for this workspace. Allowances apply to Business and Enterprise workspaces.",
          );
        if (usage.window == null && usage.billingPeriodWindow == null)
          return invalid("getCreditRateLimitStatus returned no usage windows");
        const tier = _optionalChain([
          text,
          "call",
          (_20) => _20(workspace.subscription_tier),
          "optionalAccess",
          (_21) => _21.trim,
          "call",
          (_22) => _22(),
        ]);
        const result = {
          primary,
          secondary,
          empty: !primary && !secondary,
          identity: {
            email: text(_optionalChain([user, "optionalAccess", (_23) => _23.email])),
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
