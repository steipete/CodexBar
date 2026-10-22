defineProvider({
  id: "vercel",
  name: "Vercel AI Gateway",
  endpoints: ["https://api.vercel.com"],
  auth: { type: "bearer", secret: "VERCEL_ACCESS_TOKEN" },
  settings: [
    { key: "VERCEL_ACCESS_TOKEN", title: "Vercel access token", type: "secure" },
    { key: "VERCEL_TEAM_ID", title: "Team ID", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const team = ctx.settings.get("VERCEL_TEAM_ID")?.trim();
    if (!team) throw ctx.fail.missingCredential("Set the Vercel Team ID to read your personal budget.");
    if (!/^[A-Za-z0-9_-]{1,128}$/.test(team)) {
      throw ctx.fail.permissionDenied("Invalid Vercel Team ID. Enter the team ID or slug without spaces.");
    }
    function fail() {
      throw ctx.fail.parseFailure("Vercel returned an unrecognized personal budget.");
    }
    async function read(url) {
      const response = await ctx.http.get(url);
      const message = `Vercel API returned HTTP ${response.status}.`;
      if (response.status === 401) throw ctx.fail.authenticationExpired(message);
      if (response.status === 403) throw ctx.fail.permissionDenied(message);
      if (response.status === 429) {
        const delay = Number(response.headers["retry-after"] ?? 1);
        throw ctx.fail.rateLimited(message, {
          retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
        });
      }
      if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
      if (response.status !== 200) throw ctx.fail.apiFailure(message);
      try {
        return JSON.parse(response.bodyText);
      } catch {
        return fail();
      }
    }

    const user = (await read("https://api.vercel.com/v2/user"))?.user;
    if (typeof user?.id !== "string" || !user.id) return fail();

    // At most 20 pages; the plugin deadline bounds slower teams.
    const matches = [];
    const cursors = new Set();
    let cursor = null;
    for (let page = 0; ; page += 1) {
      const query =
        `teamId=${encodeURIComponent(team)}&scopeType=user&limit=200` +
        (cursor === null ? "" : `&cursor=${encodeURIComponent(cursor)}`);
      const body = await read(`https://api.vercel.com/ai-gateway/budgets/list?${query}`);
      if (!Array.isArray(body?.budgets)) return fail();
      for (const budget of body.budgets) {
        if (budget?.scopeType !== "user" || ![user.id, `usr_${user.id}`].includes(budget.scopeId)) continue;
        if (typeof budget.active !== "boolean" || typeof budget.archived !== "boolean") return fail();
        if (budget.source !== undefined && budget.source !== "default") return fail();
        if (budget.active && !budget.archived) matches.push(budget);
      }
      const next = body.nextCursor;
      if (next === undefined || next === null) break;
      if (typeof next !== "string" || !next || cursors.has(next) || page >= 19) return fail();
      cursors.add(next);
      cursor = next;
    }

    const identity = {
      email: typeof user.email === "string" ? user.email : null,
      organization: team,
      loginMethod: "Access token",
      accountID: user.id,
    };
    const custom = matches.filter((budget) => budget.source !== "default");
    const effective = custom.length > 0 ? custom : matches;
    if (effective.length > 1) return fail();
    const budget = effective[0];
    if (!budget) {
      return {
        details: [{ title: "Personal budget", rows: [{ label: "No personal budget configured", value: "—" }] }],
        identity,
        dataConfidence: "exact",
      };
    }
    const limit = budget.limitAmount;
    const spent = budget.currentSpend;
    if (typeof limit !== "number" || !Number.isFinite(limit) || limit <= 0) return fail();
    if (typeof spent !== "number" || !Number.isFinite(spent) || spent < 0) return fail();

    // Documented UTC boundaries: daily midnight, weekly Monday, monthly the 1st; `none` never resets.
    const now = ctx.date.now();
    const year = now.getUTCFullYear();
    const month = now.getUTCMonth();
    const day = now.getUTCDate();
    let start = null;
    let end = null;
    if (budget.refreshPeriod === "daily") {
      start = Date.UTC(year, month, day);
      end = Date.UTC(year, month, day + 1);
    } else if (budget.refreshPeriod === "weekly") {
      start = Date.UTC(year, month, day - ((now.getUTCDay() + 6) % 7));
      end = start + 7 * 24 * 60 * 60 * 1000;
    } else if (budget.refreshPeriod === "monthly") {
      start = Date.UTC(year, month, 1);
      end = Date.UTC(year, month + 1, 1);
    } else if (budget.refreshPeriod !== "none") {
      return fail();
    }
    const spentText = ctx.format.usd(spent);
    const limitText = ctx.format.usd(limit);
    return {
      primary: {
        usedPercent: (spent / limit) * 100,
        windowMinutes: start === null ? null : (end - start) / 60000,
        resetsAt: end === null ? null : new Date(end),
        resetDescription: `${spentText} / ${limitText}`,
      },
      details: [
        {
          title: "Personal budget",
          rows: [
            { label: "Spend", value: spentText },
            { label: "Limit", value: limitText },
            { label: "Remaining", value: ctx.format.usd(Math.max(0, limit - spent)) },
          ],
        },
      ],
      identity,
      dataConfidence: "exact",
    };
  },
});
