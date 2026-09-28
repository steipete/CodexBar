defineProvider({
  id: "zoommate",
  name: "ZoomMate",
  settings: [
    { key: "AUTHORIZATION", title: "Captured authorization", type: "secure" },
    { key: "HEADERS", title: "Captured headers", type: "secure" },
    { key: "HOST", title: "Captured host", type: "plain" },
  ],
  endpoints: ["https://ai.zoom.us", "https://zoommate.zoom.us"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["zoom.us", "ai.zoom.us", "zoommate.zoom.us"],
  cookiePolicy: {
    selection: "request-url",
    cache: "validated-single-entry",
    imports: "access-gated",
    missingCookies: "omit",
  },
  async fetchUsage(ctx) {
    type ObjectValue = Record<string, unknown>;
    type Token = { token: string; email?: string };
    const object = (value: unknown): ObjectValue | undefined =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? (value as ObjectValue) : undefined;
    const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
    const invalid = (message: string): never => {
      throw Object.assign(ctx.fail.parseFailure(`Could not parse ZoomMate usage: ${message}`), {
        failureKind: "parse-failure",
      });
    };
    const numeric = (value: unknown): number | undefined => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isFinite(value) ? value : invalid("invalid numeric field");
    };
    const manualHost = ctx.settings.get("HOST");
    const hosts =
      manualHost === "zoommate.zoom.us" ? ["zoommate.zoom.us", "ai.zoom.us"] : ["ai.zoom.us", "zoommate.zoom.us"];
    const domain = hosts[0];
    const availability = ctx.browser.availability(domain);
    if (availability === "off") throw ctx.fail.missingCredential("ZoomMate cookies are disabled.");
    const headers: Record<string, string> = {
      Accept: "application/json, text/plain, */*",
      "Accept-Language": "en-US,en;q=0.9",
      "User-Agent":
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
      "Sec-Fetch-Dest": "empty",
      "Sec-Fetch-Mode": "cors",
      "Sec-Fetch-Site": "same-site",
      ...JSON.parse(ctx.settings.getSecret("HEADERS") || "{}"),
      Origin: "https://zoommate.zoom.us",
      Referer: "https://zoommate.zoom.us",
    };
    const bearer = (token: string): string =>
      /^bearer /i.test(token.trim()) ? token.trim() : `Bearer ${token.trim()}`;
    const failover = async <T>(operation: (host: string) => Promise<T>): Promise<T> => {
      let failure: unknown;
      for (const host of hosts) {
        try {
          return await operation(host);
        } catch (error) {
          const classified = error as CodexBarHTTPError & { failureKind?: string };
          if (
            classified.transportClass === "cancelled" ||
            ["authentication-expired", "parse-failure"].includes(classified.failureKind ?? "")
          )
            throw error;
          failure = error;
        }
      }
      throw failure;
    };
    let lastError: unknown;
    for await (const session of ctx.browser.sessions(domain)) {
      const request = async (host: string, path: string, token?: string): Promise<ObjectValue> => {
        const response = await ctx.http.get(`https://${host}/ai-computer/api/v1/${path}`, {
          headers: token ? { ...headers, Authorization: bearer(token) } : headers,
          cookieSession: session.id,
        });
        if (response.status === 401 || response.status === 403)
          throw Object.assign(
            ctx.fail.authenticationExpired(
              "ZoomMate rejected the current credentials. Sign in again or paste a fresh cURL capture.",
            ),
            { failureKind: "authentication-expired" },
          );
        if (response.status !== 200) throw ctx.fail.apiFailure(`ZoomMate HTTP ${response.status}`);
        let parsed: unknown;
        try {
          parsed = JSON.parse(response.bodyText);
        } catch (error) {
          void error;
          return invalid("invalid JSON");
        }
        return object(object(parsed)?.data) ?? invalid("missing data object");
      };
      const key = session.cacheKey;
      const evict = () => {
        if (key) ctx.cache.set(key, null, 1);
      };
      try {
        let minted: Token;
        if (availability === "manual") {
          const token = ctx.settings.getSecret("AUTHORIZATION");
          if (!token)
            throw ctx.fail.missingCredential("Paste a cURL capture of the HTTPS ZoomMate credits/status request.");
          minted = { token };
        } else {
          const cached = key ? ctx.cache.get<Token>(key) : null;
          if (cached) minted = cached;
          else {
            const login = await failover((host) => request(host, "login/?continue=https%3A%2F%2Fzoommate.zoom.us%2F"));
            const token = text(login.nak);
            if (!token) return invalid("missing nak in login bootstrap response");
            minted = { token, email: text(object(login.user_profile)?.email)?.trim() || undefined };
            try {
              const exp = ctx.jwt.decode<{ exp?: number }>(token.replace(/^bearer /i, "")).exp;
              const ttl = typeof exp === "number" ? exp - ctx.date.now().getTime() / 1000 - 60 : 0;
              if (key && ttl > 0) ctx.cache.set(key, minted, ttl);
            } catch (error) {
              void error;
              /* An unreadable JWT is usable for this request but is never cached. */
            }
          }
          ctx.browser.acceptCookie(domain, session);
        }
        const status =
          object((await failover((host) => request(host, "credits/status", minted.token))).credit_status) ??
          invalid("missing credit_status object");
        for (const field of ["budget_cap", "used_credit", "remaining_credit", "overage_credit"]) numeric(status[field]);
        for (const field of ["allow_overage", "is_quota_available", "is_unlimited"]) {
          if (status[field] != null && typeof status[field] !== "boolean") return invalid(`invalid ${field}`);
        }
        for (const field of ["cycle_start_date", "cycle_end_date"]) {
          const value = numeric(status[field]);
          if (value !== undefined && !Number.isSafeInteger(value)) return invalid(`invalid ${field}`);
        }
        const cap = numeric(status.budget_cap) ?? 0,
          used = numeric(status.used_credit) ?? 0;
        const unlimited = status.is_unlimited === true || cap <= 0;
        const cycleEnd = numeric(status.cycle_end_date),
          cycleStart = numeric(status.cycle_start_date);
        const usedPercent = unlimited ? 0 : ctx.pct(used, cap);
        const now = ctx.date.now();
        const start = new Date(now);
        start.setDate(start.getDate() - 30);
        let history: ObjectValue[] | undefined;
        try {
          history = await failover(async (host) => {
            const records: ObjectValue[] = [];
            for (let page = 0; page < 20; page++) {
              const path = `credits/history?app_id=demo_app&limit=50&page=${page}&sort_by=time&sort_order=desc&start_time=${encodeURIComponent(start.toISOString())}&end_time=${encodeURIComponent(now.toISOString())}`;
              const data = await request(host, path, minted.token);
              if (data.records != null && !Array.isArray(data.records)) return invalid("invalid history records");
              const rows = ((data.records as unknown[] | undefined) ?? []).map(
                (row) => object(row) ?? invalid("invalid history record"),
              );
              for (const row of rows) {
                numeric(row.cost);
                for (const field of ["session_id", "title", "time"]) {
                  if (row[field] != null && typeof row[field] !== "string") return invalid(`invalid history ${field}`);
                }
                for (const field of ["is_running", "is_deleted"]) {
                  if (row[field] != null && typeof row[field] !== "boolean") return invalid(`invalid history ${field}`);
                }
              }
              records.push(...rows);
              const total = numeric(data.total) ?? records.length;
              if (
                !rows.length ||
                (page + 1) * 50 >= total ||
                rows.every((row) => {
                  const date = text(row.time);
                  return date !== undefined && new Date(date).getTime() < start.getTime();
                })
              )
                break;
            }
            return records;
          });
        } catch (error) {
          if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
          if ((error as { failureKind?: string }).failureKind === "authentication-expired") evict();
        }
        const details: CodexBarDetailSection[] = [];
        if (history) {
          const day = (date: Date): string =>
            `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
          const since = new Date(now);
          since.setDate(since.getDate() - 29);
          since.setHours(0, 0, 0, 0);
          const totals: Record<string, number> = {};
          for (const record of history) {
            const cost = numeric(record.cost),
              timestamp = text(record.time);
            if (record.is_deleted === true || cost === undefined || cost < 0 || !timestamp) continue;
            const date = new Date(timestamp);
            if (!Number.isFinite(date.getTime()) || date < since) continue;
            const key = day(date);
            totals[key] = (totals[key] ?? 0) + cost;
          }
          const points = Object.keys(totals)
            .sort()
            .map((label) => ({ label, value: totals[label] }));
          const format = (value: number) => ctx.format.number(value, { maximumFractionDigits: 2 });
          const rows: CodexBarDetailRow[] = [
            { label: "Today", value: format(totals[day(now)] ?? 0) },
            { label: "30d credits", value: format(points.reduce((sum, point) => sum + point.value, 0)) },
          ];
          if (!unlimited && cycleStart && cycleEnd && cycleEnd > cycleStart) {
            const duration = Math.trunc((cycleEnd - cycleStart) / 60000) * 60000;
            const remaining = cycleEnd - now.getTime();
            if (
              duration > 0 &&
              remaining > 0 &&
              remaining <= duration &&
              !(remaining === duration && usedPercent > 0)
            ) {
              const delta = usedPercent - (1 - remaining / duration) * 100;
              const amount = Math.round(Math.abs(delta));
              rows.push({
                label: "Pace",
                value:
                  Math.abs(delta) <= 2
                    ? "On track"
                    : delta > 0
                      ? `${amount}% ahead of budget`
                      : `${amount}% behind budget`,
              });
            }
          }
          details.push({
            title: "Credit history",
            rows,
            chart: points.length ? { kind: "bars", title: "Daily credits", unit: "credits", points } : undefined,
          });
        }
        return {
          primary: {
            usedPercent,
            resetsAt: !unlimited && cycleEnd && cycleEnd > 0 ? new Date(cycleEnd) : undefined,
            resetDescription: "Credits",
          },
          details,
          identity: { email: minted.email, loginMethod: minted.email ? "Cookie" : undefined },
        };
      } catch (error) {
        if ((error as { failureKind?: string }).failureKind !== "authentication-expired" || availability === "manual")
          throw error;
        evict();
        ctx.browser.rejectCookie(domain, session);
        lastError = error;
      }
    }
    throw (
      lastError ??
      ctx.fail.missingCredential("No ZoomMate session is cached and no session cookies were imported from Chrome.")
    );
  },
});
