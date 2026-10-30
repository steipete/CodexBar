defineProvider({
  id: "workbuddy",
  name: "WorkBuddy",
  endpoints: ["https://www.workbuddy.cn"],
  settings: [
    { key: "webTimeoutSeconds", title: "Web timeout", type: "plain" },
    { key: "resetDeadlineMillis", title: "Reset lookup deadline", type: "plain" },
    { key: "chromeMajorVersion", title: "Chrome major version", type: "plain" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["workbuddy.cn", "www.workbuddy.cn"],
  cookiePolicy: {
    selection: "request-url",
    cache: "validated-single-entry",
    imports: "access-gated",
  },
  async fetchUsage(ctx) {
    const origin = "https://www.workbuddy.cn";
    const domain = "www.workbuddy.cn";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("WorkBuddy cookies are disabled.");
    const timeoutRaw = Number(ctx.settings.get("webTimeoutSeconds") ?? "15");
    const timeoutSeconds = Number.isFinite(timeoutRaw) ? Math.min(30, Math.max(1, Math.round(timeoutRaw))) : 15;
    // WorkBuddy binds the session to the browser User-Agent, and Chrome's reduced UA varies only by major version.
    // The previous major covers an installed update that Chrome has not relaunched into yet.
    const major = Number(ctx.settings.get("chromeMajorVersion") ?? "");
    const userAgent = (version: number): string =>
      `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${version}.0.0.0 Safari/537.36`;
    const userAgents: Array<string | undefined> =
      Number.isSafeInteger(major) && major > 1 ? [userAgent(major), userAgent(major - 1)] : [undefined];

    const fail = (field: string): never => {
      throw ctx.fail.parseFailure(`Invalid WorkBuddy billing response: ${field}`);
    };
    const object = (value: unknown, field: string): Record<string, unknown> =>
      value !== null && typeof value === "object" && !Array.isArray(value)
        ? (value as Record<string, unknown>)
        : fail(field);
    // Billing amounts arrive as decimal strings ("500"); numbers are accepted for robustness.
    const amount = (value: unknown, field: string): number => {
      if (typeof value === "number") return Number.isFinite(value) && value >= 0 ? value : fail(field);
      if (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value.trim())) return fail(field);
      const parsed = Number(value.trim());
      return Number.isFinite(parsed) ? parsed : fail(field);
    };
    const text = (value: unknown): string | undefined =>
      typeof value === "string" ? value.trim() || undefined : undefined;
    const format = (value: number): string => ctx.format.number(value, { maximumFractionDigits: 2 });
    const decode = (bodyText: string, field: string): Record<string, unknown> => {
      let value: unknown;
      try {
        value = JSON.parse(bodyText);
      } catch (error) {
        void error;
        return fail(field);
      }
      return object(value, field);
    };

    const sessionExpired = ctx.fail.authenticationExpired(
      "WorkBuddy session expired. Sign in at www.workbuddy.cn or paste a fresh Cookie header.",
    );
    const post = async (
      session: CodexBarCookieSession,
      agent: string | undefined,
      path: string,
      body: CodexBarJSONValue,
      requestTimeout = timeoutSeconds,
    ): Promise<Record<string, unknown>> => {
      const headers: Record<string, string> = {
        Accept: "application/json",
        Origin: origin,
        Referer: `${origin}/profile/plans-usage`,
      };
      if (agent) headers["User-Agent"] = agent;
      const response = await ctx.http.post(`${origin}${path}`, {
        body,
        timeoutSeconds: requestTimeout,
        cookieSession: session.id,
        headers,
      });
      if (response.status === 401) throw sessionExpired;
      if (response.status === 403) throw ctx.fail.permissionDenied("WorkBuddy denied access to billing data.");
      if (response.status === 429) throw ctx.fail.rateLimited("WorkBuddy billing requests are rate limited.");
      if (response.status >= 500) {
        throw ctx.fail.providerUnavailable(`WorkBuddy billing API returned HTTP ${response.status}.`);
      }
      if (response.status !== 200) throw ctx.fail.apiFailure(`WorkBuddy billing API returned HTTP ${response.status}.`);
      const root = decode(response.bodyText, "expected a JSON object");
      if (root.code !== 0) {
        throw ctx.fail.apiFailure(`WorkBuddy billing API returned code ${String(root.code)}.`);
      }
      return object(root.data, "data");
    };

    // Cycle timestamps carry no zone; WorkBuddy uses China Standard Time.
    const cycleEnd = (value: unknown): Date | undefined => {
      const raw = text(value);
      if (!raw) return undefined;
      const match = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})$/.exec(raw);
      if (!match) return undefined;
      const end = ctx.date.iso(`${match[1]}T${match[2]}+08:00`);
      // The dashboard refreshes one second after the inclusive end time.
      return new Date(end.getTime() + 1000);
    };
    // Spent grants stay in the listing until their cycle ends. The dashboard reports the lapse of the
    // grants that still carry credits, so a grant with nothing left must not bound the reward window.
    const creditsLeft = (value: unknown): number | undefined => {
      try {
        return amount(value, "CycleCapacityRemain");
      } catch (error) {
        void error;
        return undefined;
      }
    };
    // Package codes the WorkBuddy client sends for its paid and free listings (WorkBuddy 5.6.2).
    const paidPackageCodes = [
      "TCACA_code_002_AkiJS3ZHF5",
      "TCACA_code_005_maRGyrHhw1",
      "TCACA_code_003_FAnt7lcmRT",
      "TCACA_code_023_4xbGhMrE6q",
      "TCACA_code_026_BaESVICNoi",
      "TCACA_code_027_0FCGVA6vSa",
      "TCACA_code_009_0XmEQc2xOf",
      "TCACA_code_038_OhvqZtiPKr",
      "TCACA_code_036_lupO5WgNdG",
    ];
    const freePackageCodes = [
      "TCACA_code_001_PqouKr6QWV",
      "TCACA_code_008_cfWoLwvjU4",
      "TCACA_code_035_ArVxJcGDsm",
      "TCACA_code_006_DbXS0lrypC",
      "TCACA_code_039_KRcQj7wUat",
      "TCACA_code_040_mi9rCYg46x",
      "TCACA_code_007_nzdH5h4Nl0",
      "TCACA_code_028_NtpWi0jzXs",
      "TCACA_code_037_WxOD3MpI2o",
      "TCACA_code_029_6wCGEWquYy",
      "TCACA_code_030_BjSt89qTvr",
    ];
    // Platform reward grants are aggregated under one package code in the summary. Only the free listing
    // carries each grant's own cycle, so the reward expiry has to be read from there.
    const benefitPackageCode = "TCACA_code_007_nzdH5h4Nl0";
    // Reset and reward expiry are optional: a failed or unexpected package listing must not discard the balance.
    const listings = async (
      session: CodexBarCookieSession,
      agent: string | undefined,
      wantsRewards: boolean,
    ): Promise<{ reset?: Date; rewardExpiry?: Date }> => {
      const now = ctx.date.now().getTime();
      // Share five seconds across listings, retaining the host's margin for publishing the balance.
      const hostDeadline = Number(ctx.settings.get("resetDeadlineMillis"));
      const deadline = Math.min(Date.now() + 5000, hostDeadline > 0 ? hostDeadline : Infinity);
      let paidReset: Date | undefined;
      let freeReset: Date | undefined;
      let rewardExpiry: Date | undefined;
      for (const [path, codes, isFree] of [
        ["/billing/meter/get-user-resource-paid-packages", paidPackageCodes, false],
        ["/billing/meter/get-user-resource-free-packages", freePackageCodes, true],
      ] as Array<[string, string[], boolean]>) {
        const budget = (deadline - Date.now()) / 1000;
        if (budget < 1) break;
        try {
          // The listings reject requests without package codes (HTTP 400, code 10001). Status 0 is valid, 3 used up.
          const page = await post(
            session,
            agent,
            path,
            { PageNumber: 1, PageSize: 100, PackageCodes: codes, Status: [0, 3] },
            Math.min(timeoutSeconds, budget),
          );
          if (Array.isArray(page.Accounts)) {
            for (const raw of page.Accounts) {
              if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
              const account = raw as Record<string, unknown>;
              if (account.CapacityUnit !== "credits") continue;
              const end = cycleEnd(account.CycleEndTime);
              if (!end || end.getTime() <= now) continue;
              if (isFree) {
                // Reward grants expire piecewise; the earliest grant that still holds credits bounds the window.
                const left = creditsLeft(account.CycleCapacityRemain);
                if (
                  account.PackageCode === benefitPackageCode &&
                  left !== undefined &&
                  left > 0 &&
                  (!rewardExpiry || end.getTime() < rewardExpiry.getTime())
                ) {
                  rewardExpiry = end;
                }
                // Reward grants expire; they never supply the allowance's fallback reset.
                if (account.PackageCode !== benefitPackageCode && (!freeReset || end.getTime() < freeReset.getTime())) {
                  freeReset = end;
                }
              } else if (!paidReset || end.getTime() < paidReset.getTime()) {
                paidReset = end;
              }
            }
          }
        } catch (error) {
          if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
        }
        // Paid cycles refill the allowance; free grants may expire earlier. The free listing is only
        // worth a request when it answers the reset or bounds the reward window.
        if (!isFree && paidReset && !wantsRewards) break;
      }
      return { reset: paidReset ?? freeReset, rewardExpiry };
    };

    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      let summary: Record<string, unknown> | undefined;
      let agent: string | undefined;
      for (const candidate of userAgents) {
        try {
          summary = await post(session, candidate, "/billing/meter/get-user-resource-summary", {});
          agent = candidate;
          break;
        } catch (error) {
          if (error !== sessionExpired) throw error;
        }
      }
      if (!summary) {
        rejected = true;
        ctx.browser.rejectCookie(domain, session);
        if (policy === "manual") break;
        continue;
      }

      if (!Array.isArray(summary.Packages)) return fail("Packages");
      // The host caches an imported session only after the billing API accepts it.
      if (policy !== "manual") ctx.browser.acceptCookie(domain, session);
      let total = 0;
      let remaining = 0;
      let frozen = 0;
      for (const raw of summary.Packages) {
        const item = object(raw, "package");
        if (item.CapacityUnit !== "credits") continue;
        total += amount(item.CycleTotalCapacity, "CycleTotalCapacity");
        remaining += amount(item.CycleRemainCapacity, "CycleRemainCapacity");
        if (item.CycleFrozenCapacity !== undefined) frozen += amount(item.CycleFrozenCapacity, "CycleFrozenCapacity");
      }
      // Credit groups split the same allowance by origin. Rewards are optional, so an unexpected group
      // shape must not discard the balance the dashboard shows.
      let rewardTotal = 0;
      let rewardRemaining = 0;
      for (const raw of Array.isArray(summary.CreditGroups) ? summary.CreditGroups : []) {
        if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
        const group = raw as Record<string, unknown>;
        if (group.Kind !== "benefit" || group.CapacityUnit !== "credits") continue;
        try {
          const groupTotal = amount(group.CycleTotalCapacity, "CycleTotalCapacity");
          const groupRemaining = amount(group.CycleRemainCapacity, "CycleRemainCapacity");
          rewardTotal += groupTotal;
          rewardRemaining += groupRemaining;
        } catch (error) {
          void error;
        }
      }
      const plan = text(summary.SubscriptionPackageName);
      // Frozen credits are listed as reported; the meter uses the remaining amount the dashboard shows.
      const rows: CodexBarDetailRow[] = frozen > 0 ? [{ label: "Reserved", value: format(frozen) }] : [];
      if (total <= 0) {
        rows.unshift({ label: "Left", value: format(remaining) }, { label: "Total", value: format(total) });
      }
      const wantsRewards = rewardTotal > 0;
      const cycle = await listings(session, agent, wantsRewards);
      // The window carries the balance; it cannot carry a countdown, because reward credits lapse
      // grant by grant instead of resetting, so the expiry stays a detail row.
      if (wantsRewards && cycle.rewardExpiry) {
        rows.push({ label: "Reward expiry", value: ctx.format.monthDay(cycle.rewardExpiry.getTime()) });
      }
      const extraWindows: CodexBarNamedRateWindow[] = wantsRewards
        ? [
            {
              id: "rewards",
              title: "Rewards",
              window: {
                usedPercent: ctx.pct(Math.max(0, rewardTotal - rewardRemaining), rewardTotal),
                resetDescription: `${format(rewardRemaining)} / ${format(rewardTotal)} credits left`,
              },
            },
          ]
        : [];
      return {
        primary:
          total > 0
            ? {
                usedPercent: ctx.pct(Math.max(0, total - remaining), total),
                resetsAt: cycle.reset,
                resetDescription: `${format(remaining)} / ${format(total)} credits left`,
              }
            : undefined,
        extraWindows: extraWindows.length ? extraWindows : undefined,
        details: rows.length ? [{ title: "Credits", rows }] : undefined,
        identity: plan ? { loginMethod: plan } : undefined,
        dataConfidence: "exact",
      };
    }
    if (rejected) throw sessionExpired;
    throw ctx.fail.missingCredential(
      `No WorkBuddy session cookies found. Sign in at www.workbuddy.cn (${ctx.browser.supportedBrowsers}) or paste a Cookie header.`,
    );
  },
});
