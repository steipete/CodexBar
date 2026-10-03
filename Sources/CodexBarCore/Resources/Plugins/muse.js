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
async function _asyncOptionalChain(ops) {
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
      value = await fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = await fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "muse",
  name: "Muse Code",
  endpoints: ["https://api.meta.ai", "https://dev.meta.ai"],
  settings: [
    { key: "MUSE_DEVICE_TOKEN", title: "Muse login", type: "secure" },
    { key: "MUSE_WEB_TEAM_ID", title: "Browser team ID", type: "plain" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["dev.meta.ai"],
  async fetchUsage(ctx) {
    const token = ctx.settings.getSecret("MUSE_DEVICE_TOKEN");
    if (!_optionalChain([token, "optionalAccess", (_) => _.startsWith, "call", (_2) => _2("dca:")])) {
      throw ctx.fail.authenticationExpired("Muse Code requires a device-code login. Run `muse login` again.");
    }
    // Keep the device credential off dev.meta.ai requests, which authenticate with the browser session.
    const response = await ctx.http.post("https://api.meta.ai/muse-code/key", {
      body: {},
      headers: { Authorization: `Bearer ${token}`, "x-api-version": "1.0.0", "User-Agent": "CodexBar" },
      timeoutSeconds: 15,
    });
    if (response.status === 401 || response.status === 403) {
      throw ctx.fail.authenticationExpired("Muse Code login was rejected. Run `muse login` again.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Muse Code usage requests are rate limited.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`Muse Code API returned HTTP ${response.status}.`);
    if (response.status !== 200) throw ctx.fail.apiFailure(`Muse Code API returned HTTP ${response.status}.`);
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Could not parse Muse Code subscription usage: ${field}`);
    };
    const object = (value, field) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (typeof value !== "number" || !Number.isFinite(value)) return fail(field);
      return value;
    };
    const text = (value, field) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value !== "string") return fail(field);
      return value.trim() || undefined;
    };
    const reset = (value) => {
      if (value === undefined || value === null) return undefined;
      const seconds = number(value, "resets_at");
      // Match the native countdown boundary; oversized dates must not discard useful quota data.
      if (seconds <= 0 || seconds > 64092211200) return undefined;
      return ctx.date.unixSeconds(seconds);
    };
    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected a response object");
    for (const key of ["require_payment", "is_subs_active"]) {
      if (root[key] !== undefined && root[key] !== null && typeof root[key] !== "boolean") return fail(key);
    }
    if (root.require_payment === true) {
      throw ctx.fail.permissionDenied("Muse Code requires a payment method. Finish billing at https://dev.meta.ai");
    }
    if (root.is_subs_active !== true) {
      throw ctx.fail.permissionDenied("No Muse Code subscription is active on this login.");
    }
    const plan = text(root.subs_tier_name, "subs_tier_name");
    const rows = [];
    if (plan) rows.push({ label: "Plan", value: plan });
    const snapshot = {
      details: [{ title: "Muse Code subscription", rows }],
      identity: { email: text(root.user_email, "user_email"), loginMethod: _nullishCoalesce(plan, () => "Muse login") },
      dataConfidence: "unknown",
    };
    const percentLabel = (value) => `${ctx.format.number(value, { maximumFractionDigits: 0 })}%`;

    async function webQuota() {
      if (ctx.browser.availability("dev.meta.ai") === "off") return undefined;
      // The browser session must belong to the same Meta account as the CLI login.
      const loginEmail = _optionalChain([
        text,
        "call",
        (_3) => _3(root.user_email, "user_email"),
        "optionalAccess",
        (_4) => _4.toLowerCase,
        "call",
        (_5) => _5(),
      ]);
      if (!loginEmail) return undefined;
      try {
        let requestsLeft = 5;
        const client = (session) => {
          const headers = { Cookie: _nullishCoalesce(session.header, () => ""), "User-Agent": "CodexBar" };
          const state = { rejected: false };
          const get = async (path, forbiddenRejectsSession = true) => {
            if (requestsLeft-- <= 0) throw new Error("Muse browser request budget exhausted");
            const response = await ctx.http.get(`https://dev.meta.ai${path}`, { headers, timeoutSeconds: 8 });
            if (response.status === 401 || (response.status === 403 && forbiddenRejectsSession)) {
              state.rejected = true;
              ctx.browser.rejectCookie("dev.meta.ai", session);
              return undefined;
            }
            if (response.status !== 200) return undefined;
            const value = JSON.parse(response.bodyText);
            return value && typeof value === "object" && !Array.isArray(value) ? value : undefined;
          };
          return { get, state };
        };
        // dev.meta.ai can report a blank email; the session user's team membership then supplies it. Checking
        // membership costs a request, so such sessions wait until no session matches the login by email.
        const unverified = [];
        for await (const session of ctx.browser.sessions("dev.meta.ai")) {
          if (requestsLeft <= 0) break;
          const web = client(session);
          const me = await web.get("/api/auth/me");
          if (!me) continue;
          const webEmail = typeof me.email === "string" ? me.email.trim().toLowerCase() : "";
          if (!webEmail) {
            const userID = numericID(me.userId);
            if (userID) unverified.push({ web, userID });
            continue;
          }
          if (webEmail !== loginEmail) continue;
          const result = await teamQuota(web);
          if (result !== "skip") return result;
        }
        for (const { web, userID } of unverified) {
          if (requestsLeft <= 0) break;
          const result = await teamQuota(web, userID);
          if (result !== "skip") return result;
        }
      } catch (error) {
        void error;
      }
      return undefined;

      // Returns "skip" when the next session should be tried. `userID` asks for a membership check first.
      async function teamQuota(web, userID) {
        const listed = await _asyncOptionalChain([
          await web.get("/api/portal/teams"),
          "optionalAccess",
          async (_6) => _6.teams,
        ]);
        if (web.state.rejected) return "skip";
        // A session not yet bound to the login must not end the search for a later bound session.
        if (!Array.isArray(listed)) return userID ? "skip" : undefined;
        const teams = [];
        for (const entry of listed) {
          const item = entry && typeof entry === "object" ? entry : {};
          const id = numericID(item.team_id);
          if (!id) continue;
          const name = typeof item.team_name === "string" && item.team_name.trim() ? item.team_name.trim() : id;
          teams.push({ id, name });
        }
        const selected = _nullishCoalesce(
          _optionalChain([
            ctx,
            "access",
            (_7) => _7.settings,
            "access",
            (_8) => _8.get,
            "call",
            (_9) => _9("MUSE_WEB_TEAM_ID"),
            "optionalAccess",
            (_10) => _10.trim,
            "call",
            (_11) => _11(),
          ]),
          () => "",
        );
        const team = teams.find((candidate) => candidate.id === selected);
        if (userID) {
          // Accept the session only if a visible team lists its user with the login's email.
          const probe = _nullishCoalesce(team, () => teams[0]);
          if (!probe) return "skip";
          // Member lists can be forbidden to some roles; that does not mean the session expired.
          const members = await _asyncOptionalChain([
            await web.get(`/api/portal/teams/${probe.id}/members`, false),
            "optionalAccess",
            async (_12) => _12.members,
          ]);
          if (web.state.rejected || !Array.isArray(members)) return "skip";
          const own = members
            .map((member) => (member && typeof member === "object" ? member : {}))
            .find((member) => numericID(member.user_id) === userID);
          if (
            typeof _optionalChain([own, "optionalAccess", (_13) => _13.email]) !== "string" ||
            own.email.trim().toLowerCase() !== loginEmail
          )
            return "skip";
        }
        if (!selected) return { teams, note: "Choose a browser team in Muse Code settings" };
        if (!team) return { teams, note: "The selected browser team is not visible to this session" };
        const quota = await _asyncOptionalChain([
          await web.get(`/api/portal/teams/${team.id}/subscription-quota`),
          "optionalAccess",
          async (_14) => _14.subscription_quota,
        ]);
        if (web.state.rejected) return "skip";
        if (!quota || typeof quota !== "object") return { teams, note: "No subscription quota for the selected team" };
        const record = quota;
        // The team's quota must be for the same plan the CLI login reports.
        if (!plan || typeof record.tier !== "string" || record.tier.trim() !== plan) {
          return { teams, note: "The selected team's plan differs from the Muse login" };
        }
        const parsed = parseWebQuota(record);
        return parsed ? { teams, quota: { team, ...parsed } } : { teams };
      }
    }
    function numericID(value) {
      const id = typeof value === "string" ? value.trim() : Number.isSafeInteger(value) ? String(value) : "";
      return /^[0-9]+$/.test(id) ? id : undefined;
    }
    function parseWebQuota(quota) {
      // Limits and usage are weighted token counts encoded as decimal strings.
      const amount = (value) => {
        const parsed = typeof value === "string" && /^[0-9]+$/.test(value) ? Number(value) : value;
        return typeof parsed === "number" && Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
      };
      const percent = (used, limit) => {
        const u = amount(used);
        const l = amount(limit);
        return u === null || l === null || l <= 0 ? null : Math.min(100, (u / l) * 100);
      };
      const resetAt = (value) => {
        const parsed = amount(value);
        return parsed === null || parsed <= 0 || parsed > 64092211200 ? undefined : ctx.date.unixSeconds(parsed);
      };
      const now = ctx.date.now().getTime();
      const weeklyReset = resetAt(quota.weekly_resets_at);
      const weeklyPercent = percent(quota.weekly_weighted_used, quota.weekly_weighted_limit);
      const seconds = amount(quota.window_duration_secs);
      // A weekly quota without a future reset is stale; show nothing rather than an old reading.
      if (weeklyPercent === null || !weeklyReset || weeklyReset.getTime() <= now) return null;
      if (seconds === null || !Number.isSafeInteger(seconds) || seconds < 60) return null;
      const windowReset = resetAt(quota.window_resets_at);
      let primaryPercent = percent(quota.window_weighted_used, quota.window_weighted_limit);
      if (primaryPercent === null) return null;
      const noWindowReset = quota.window_resets_at === undefined || quota.window_resets_at === null;
      if ((!noWindowReset && !windowReset) || (noWindowReset && primaryPercent !== 0)) return null;
      // An idle 5-hour window has no reset time; one whose reset has passed carries no usage into the next window.
      const windowActive = windowReset !== undefined && windowReset.getTime() > now;
      if (!windowActive) primaryPercent = 0;
      return {
        primary: {
          usedPercent: primaryPercent,
          windowMinutes: Math.round(seconds / 60),
          resetsAt: windowActive ? windowReset : undefined,
        },
        secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: weeklyReset },
      };
    }
    if (root.subs_usage === undefined || root.subs_usage === null) {
      // The login response omits quotas while the 5-hour window is idle, even when the weekly limit has usage.
      // The dev.meta.ai usage page reads the same subscription quota with the browser session.
      const web = await webQuota();
      if (!_optionalChain([web, "optionalAccess", (_15) => _15.quota]))
        rows.push({ label: "Quota", value: "Not included in this login response" });
      if (!web) return snapshot;
      const teamRows = _nullishCoalesce(web.teams, () => []).map((team) => ({ label: team.name, value: team.id }));
      if (web.note) teamRows.unshift({ label: "Status", value: web.note });
      _optionalChain([
        snapshot,
        "access",
        (_16) => _16.details,
        "optionalAccess",
        (_17) => _17.push,
        "call",
        (_18) => _18({ title: "Browser teams", rows: teamRows }),
      ]);
      if (!web.quota) return snapshot;
      const { team, primary, secondary } = web.quota;
      const webRows = [
        { label: "Team", value: team.name },
        { label: "5 hours", value: percentLabel(primary.usedPercent) },
        { label: "Weekly", value: percentLabel(secondary.usedPercent) },
      ];
      _optionalChain([
        snapshot,
        "access",
        (_19) => _19.details,
        "optionalAccess",
        (_20) => _20.push,
        "call",
        (_21) => _21({ title: "Browser team quota (dev.meta.ai)", rows: webRows }),
      ]);
      // Weighted usage reported for a user-selected team, not by the CLI login itself.
      return { usage: { ...snapshot, primary, secondary, dataConfidence: "estimated" }, sourceLabel: "oauth+web" };
    }
    const usage = object(root.subs_usage, "subs_usage");
    const window = object(usage.window, "missing subscription window");
    const weekly = object(usage.weekly, "missing weekly window");
    const minutes = Math.round(number(window.window_duration_mins, "window_duration_mins"));
    if (!Number.isSafeInteger(minutes) || minutes <= 0) return fail("window_duration_mins");
    const primaryPercent = Math.min(100, Math.max(0, number(window.used_percent, "window.used_percent")));
    const weeklyPercent = Math.min(100, Math.max(0, number(weekly.used_percent, "weekly.used_percent")));
    rows.push({ label: "5 hours", value: percentLabel(primaryPercent) });
    rows.push({ label: "Weekly", value: percentLabel(weeklyPercent) });
    return {
      ...snapshot,
      primary: { usedPercent: primaryPercent, windowMinutes: minutes, resetsAt: reset(window.resets_at) },
      secondary: { usedPercent: weeklyPercent, windowMinutes: 10080, resetsAt: reset(weekly.resets_at) },
      dataConfidence: "exact",
    };
  },
});
