defineProvider({
  id: "museai",
  name: "Muse (muse.ai)",
  endpoints: ["https://muse.ai"],
  settings: [],
  capabilities: ["browser-cookies", "http-status", "persistent-storage"],
  cookieDomains: ["muse.ai"],
  async fetchUsage(ctx) {
    const origin = "https://muse.ai";
    const userAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36";
    const policy = ctx.browser.availability("muse.ai");
    if (policy === "off") throw ctx.fail.missingCredential("muse.ai cookies are disabled.");
    const signedOut = (r) =>
      r.status === 401 || r.status === 403 || (r.headers["location"] ?? "").startsWith("https://auth.muse.ai/");
    const actionNeedsRediscovery = (r) =>
      !signedOut(r) && r.status >= 400 && r.status < 500 && r.status !== 429;
    const discoveryFailure = () =>
      ctx.fail.parseFailure(
        "Could not find a working muse.ai subscription action. muse.ai may have changed. Refresh to retry.",
      );
    const post = (cookie, actionID) =>
      ctx.http.post(`${origin}/`, {
        body: [{ includeAgreement: true }],
        headers: {
          Cookie: cookie,
          Accept: "text/x-component",
          "Next-Action": actionID,
          Origin: origin,
          // muse.ai answers 403 to server actions that do not look like same-origin browser fetches.
          "Sec-Fetch-Site": "same-origin",
          "Sec-Fetch-Mode": "cors",
          "Sec-Fetch-Dest": "empty",
          "Content-Type": "text/plain;charset=UTF-8",
          "User-Agent": userAgent,
        },
      });
    const chunkPaths = (text) => [
      ...new Set((text.match(/static\/chunks\/[\w~.-]+\.js/g) ?? []).map((p) => `/_next/${p}`)),
    ];
    const fetchChunks = (paths) =>
      Promise.all(
        paths.map((path) =>
          ctx.http
            .get(`${origin}${path}`, { headers: { Accept: "*/*", "User-Agent": userAgent } })
            .then((r) => (r.status === 200 ? r.bodyText : ""))
            .catch(() => ""),
        ),
      );
    // The action ID changes on every deploy. The app chunk preloads settings through
    // `e.A(<module>).then(({preloadHatchSettingsData…` and the loader chunk lists that module's files, one of which
    // holds `createServerReference("<id>", …, "fetchSubscriptionAction")`.
    // Returns undefined when muse.ai treats the session as signed out.
    const discover = async (cookie) => {
      const page = await ctx.http.get(`${origin}/`, {
        headers: { Cookie: cookie, Accept: "text/html", "User-Agent": userAgent },
      });
      if (signedOut(page)) return undefined;
      // Fetch page chunks a few at a time and stop once the settings loader entry turns up.
      if (page.status !== 200) throw ctx.fail.apiFailure(`muse.ai returned HTTP ${page.status}.`);
      const paths = chunkPaths(page.bodyText).slice(0, 96);
      let text = "";
      for (let i = 0; i < paths.length; i += 8) {
        text += "\n" + (await fetchChunks(paths.slice(i, i + 8))).join("\n");
        if (text.length > 8 * 1024 * 1024) throw discoveryFailure();
        const module = /\.A\((\d+)\)\.then\(\(\{[^}]*Settings/.exec(text)?.[1];
        const loader =
          module && new RegExp(`[,{\\[]${module},\\w+=>\\{\\w+\\.v\\(\\w+=>Promise\\.all\\(\\[([^\\]]*)`).exec(text);
        if (!loader) continue;
        const settingsPaths = chunkPaths(loader[1]).slice(0, 32);
        for (let j = 0; j < settingsPaths.length; j += 8) {
          for (const body of await fetchChunks(settingsPaths.slice(j, j + 8))) {
            const id = /"([0-9a-f]{40,})",[^"]{0,200}"fetchSubscriptionAction"/.exec(body)?.[1];
            if (id) return id;
          }
        }
        break;
      }
      throw discoveryFailure();
    };

    let actionID = ctx.storage.get("actionID");
    const subscription = async (cookie) => {
      const response = actionID ? await post(cookie, actionID) : undefined;
      if (response && !actionNeedsRediscovery(response)) {
        return signedOut(response) ? undefined : response;
      }
      ctx.storage.remove("actionID");
      actionID = await discover(cookie);
      if (!actionID) return undefined;
      const fresh = await post(cookie, actionID);
      if (staleAction(fresh)) throw discoveryFailure();
      return signedOut(fresh) ? undefined : fresh;
    };

    // Try each browser session, rejecting expired ones so a signed-in browser later in the order still works.
    let response;
    let rejected = false;
    for await (const session of ctx.browser.sessions("muse.ai")) {
      response = await subscription(session.header);
      if (response) break;
      rejected = true;
      ctx.browser.rejectCookie("muse.ai", session);
      if (policy === "manual") break;
    }
    if (!response) {
      throw rejected
        ? ctx.fail.authenticationExpired("muse.ai session expired. Sign in at muse.ai and refresh.")
        : ctx.fail.missingCredential(
            `No muse.ai session found. Sign in at muse.ai. Supported browsers: ${ctx.browser.supportedBrowsers}. Or set a manual Cookie header.`,
          );
    }
    if (response.status !== 200) throw ctx.fail.apiFailure(`muse.ai returned HTTP ${response.status}.`);

    // React flight rows look like `1:{...}`; the subscription is the row carrying `success`.
    let sub;
    for (const line of response.bodyText.split("\n")) {
      try {
        const row = JSON.parse(/^[0-9a-f]+:(\{.*\})\s*$/.exec(line)?.[1] ?? "null");
        if (row?.success === true) sub = row.subscription;
      } catch {}
    }
    if (typeof sub?.usage?.percentUsed !== "number") throw ctx.fail.parseFailure("Unexpected muse.ai response.");

    ctx.storage.set("actionID", actionID);
    const seconds = (value) => (typeof value === "number" ? ctx.date.unixSeconds(value) : undefined);
    const tokensLeft = (label) => /\(([^()]+ tokens left)\)/.exec(label ?? "")?.[1];
    // Top-ups (purchased or from referrals) never expire and sit outside the weekly allowance. muse.ai reports
    // the balance in micro-dollars, so the fallback without its label is a dollar amount.
    const { topupBalance: balance, topupTotal: total } = sub;
    const topup =
      typeof balance === "number" && typeof total === "number" && total > 0
        ? {
            label: sub.topupRowLabel ?? "Additional tokens",
            value:
              tokensLeft(sub.topupRowValueLabel) ?? sub.topupRowValueLabel ?? `${ctx.format.usd(balance / 1e6)} left`,
            progress: Math.min(1, Math.max(0, (total - balance) / total)),
          }
        : undefined;
    return {
      primary: {
        usedPercent: Math.min(100, Math.max(0, sub.usage.percentUsed)),
        windowMinutes: 7 * 24 * 60,
        resetsAt: seconds(sub.usage.resetsAt),
        // "3% used (2.8B tokens left)" is the only absolute amount muse.ai reports. Free plans omit it.
        resetDescription: tokensLeft(sub.usageRowValueLabel),
      },
      details: topup ? [{ rows: [topup] }] : undefined,
      subscriptionRenewsAt: seconds(sub.agreement?.currentPeriodEndTime),
      identity: { loginMethod: sub.tier?.name ?? sub.usageRowLabel },
      dataConfidence: "percentOnly",
    };
  },
});
