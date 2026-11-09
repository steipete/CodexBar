function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
defineProvider({
  id: "googledeveloper",
  name: "Google Developer Program",
  settings: [],
  endpoints: ["https://me.developers.google.com"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["me.developers.google.com", "google.com"],
  cookiePolicy: { selection: "request-url", cache: "nonpersistent", imports: "access-gated" },
  async fetchUsage(ctx) {
    const domain = "me.developers.google.com";
    const origin = `https://${domain}`;
    if (ctx.browser.availability(domain) === "off")
      throw ctx.fail.missingCredential("Google Developer Program cookies are disabled.");
    const invalid = (field) => {
      throw ctx.fail.parseFailure(
        `Could not parse the Google Developer Program ${field}. The benefits page may have changed. Update CodexBar or report this.`,
      );
    };
    const json = (text, field) => {
      try {
        return JSON.parse(text);
      } catch (error) {
        void error;
        return invalid(field);
      }
    };
    const array = (value, field) => (Array.isArray(value) ? value : invalid(field));
    // Google Money arrays omit zero units and nanos.
    const integer = (value, field) =>
      value === null || value === undefined
        ? 0
        : typeof value === "number" && Number.isSafeInteger(value)
          ? value
          : invalid(field);
    const money = (value, field) => {
      const [currency, units, nanos] = array(value, field);
      if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) return invalid(`${field} currency`);
      return { currency, amount: integer(units, field) + integer(nanos, field) / 1e9 };
    };
    // A malformed timestamp means an unknown date, never a failed refresh.
    const date = (value) => {
      const seconds = Array.isArray(value) ? value[0] : undefined;
      return typeof seconds === "number" && Number.isSafeInteger(seconds) && seconds > 0
        ? ctx.date.unixSeconds(seconds)
        : undefined;
    };
    const day = (value) => `${ctx.format.monthDay(value)}, ${value.getFullYear()}`;
    // WIZ_global_data values are JSON string literals.
    const pageValue = (html, key) => {
      const literal = ctx.html.matchFirst(html, `"${key}":("(?:[^"\\\\]|\\\\.)*")`);
      return literal ? json(literal, "benefits page") : undefined;
    };
    // Signed-out requests redirect to accounts.google.com, which the host refuses, or answer 401 or 403.
    const denied = (response) => {
      if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403)
        return true;
      if (response.status === 429) {
        throw ctx.fail.rateLimited("Google Developer Program requests are rate limited. Try again in a few minutes.");
      }
      if (response.status >= 500) {
        throw ctx.fail.providerUnavailable("Google Developer Program is unavailable. Try again later.");
      }
      if (response.status !== 200) {
        throw ctx.fail.apiFailure(
          `Google Developer Program returned HTTP ${response.status}. Try again later or report this.`,
        );
      }
      return false;
    };
    let unapplied;
    let signedIn = false;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const emails = [];
      // Each authuser index is one signed-in Google account, and only one of them may hold the credit.
      for (let account = 0; account < 8; account += 1) {
        const page = await ctx.http.get(`${origin}/benefits?authuser=${account}`, {
          cookieSession: session.id,
          headers: { Accept: "text/html" },
          retryPolicy: "transientIdempotent",
        });
        if (denied(page)) break;
        // Signed-out pages also omit the page tokens.
        const token = pageValue(page.bodyText, "SNlM0e");
        const email = pageValue(page.bodyText, "oPEP7c");
        if (!token || !email || emails.includes(email)) break;

        const response = await ctx.http.post(
          `${origin}/_/GoogleDeveloperProfile/data/batchexecute` +
            `?rpcids=Ro0AYc&source-path=%2Fbenefits&hl=en&authuser=${account}&rt=c`,
          {
            cookieSession: session.id,
            form: { "f.req": JSON.stringify([[["Ro0AYc", "[]", null, "generic"]]]), at: token },
            headers: { Origin: origin, Referer: `${origin}/benefits` },
          },
        );
        if (denied(response)) break;
        emails.push(email);
        signedIn = true;
        // The chunked envelope alternates length lines with JSON chunks. Only the Ro0AYc result matters.
        const result = response.bodyText
          .split("\n")
          .filter((line) => line.startsWith("["))
          .flatMap((line) => array(json(line, "benefits response"), "benefits response"))
          .find((entry) => Array.isArray(entry) && entry[0] === "wrb.fr" && entry[1] === "Ro0AYc");
        if (!result) return invalid("benefits response");
        // A per-account RPC error has no string payload, so try the next account.
        if (typeof result[2] !== "string") continue;
        const list = array(json(result[2], "benefits"), "benefits")[0];
        // Benefit type 19 is the monthly Gen AI & Cloud credit of Google AI Pro and Ultra.
        const credit = array(
          _nullishCoalesce(list, () => []),
          "benefits",
        )
          .map((benefit) => array(benefit, "benefit"))
          .find((benefit) => benefit[0] === 19);
        if (!credit) continue;
        const offer = array(
          _nullishCoalesce(credit[9], () => []),
          "credit offer",
        );
        // A credit that is not applied to a billing account yet has no money fields.
        if (offer[6] === null || offer[6] === undefined) {
          unapplied ??= email;
          continue;
        }
        const billing = array(offer[6], "credit balance");
        const granted = money(billing[0], "granted credit");
        const remaining = money(billing[1], "remaining credit");
        if (granted.amount <= 0) return invalid("credit amounts");
        const currency = granted.currency;
        const left = Math.max(0, remaining.amount);
        const expiresAt = date(offer[1]);
        const grantedAt = date(offer[16]);
        const amounts = `${ctx.format.currency(left, currency)} of ${ctx.format.currency(granted.amount, currency)} left`;
        // The billing account is display-only, so an unexpected format never fails the refresh.
        const rows =
          typeof billing[2] === "string"
            ? [{ label: "Billing account", value: billing[2].replace(/^billingAccounts\//, "") }]
            : [];
        if (grantedAt) rows.push({ label: "Granted", value: day(grantedAt) });
        return {
          primary: {
            usedPercent: ctx.pct(granted.amount - left, granted.amount),
            resetDescription: expiresAt ? `${amounts} · Expires ${day(expiresAt)}` : amounts,
          },
          cost: { used: left, currency, period: "Monthly credit", balance: left },
          details: [{ title: "Billing", rows }],
          identity: { email, loginMethod: "Browser session" },
          dataConfidence: "exact",
        };
      }
      if (signedIn) break;
      // A session whose first account fails the page or the RPC is signed out.
      ctx.browser.rejectCookie(domain, session);
      rejected = true;
    }
    if (unapplied) {
      return {
        details: [
          {
            title: "Cloud credits",
            rows: [
              {
                label: "Status",
                value: "Not applied",
                secondaryValue: "Apply it at me.developers.google.com/benefits",
              },
            ],
          },
        ],
        identity: { email: unapplied, loginMethod: "Browser session" },
        dataConfidence: "exact",
      };
    }
    if (signedIn)
      throw ctx.fail.permissionDenied(
        "No signed-in Google account has a Google Developer Program Cloud credit. It requires Google AI Pro or Ultra.",
      );
    if (rejected)
      throw ctx.fail.authenticationExpired(
        "Google session expired. Sign in at me.developers.google.com or paste a fresh Cookie header.",
      );
    throw ctx.fail.missingCredential(
      `Sign in at me.developers.google.com. Supported browsers: ${ctx.browser.supportedBrowsers}. Or paste its Cookie header.`,
    );
  },
});
