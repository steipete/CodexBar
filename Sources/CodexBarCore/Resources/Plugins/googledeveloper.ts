defineProvider({
  id: "googledeveloper",
  name: "Google Developer Program",
  settings: [{ key: "MESSAGES", title: "Google Developer Program", type: "plain" }],
  endpoints: ["https://me.developers.google.com"],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["me.developers.google.com", "google.com"],
  cookiePolicy: { selection: "request-url", cache: "nonpersistent", imports: "access-gated" },
  async fetchUsage(ctx) {
    const domain = "me.developers.google.com";
    const origin = `https://${domain}`;
    const messages: Record<string, string> = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key: string, ...values: string[]): string => {
      let text = messages[key] || key;
      for (const value of values) text = text.replace("%@", () => value);
      return text;
    };
    const signIn = message(
      "No Google Developer Program session cookies found. Sign in at me.developers.google.com/benefits or paste a Cookie header.",
    );
    if (ctx.browser.availability(domain) === "off")
      throw ctx.fail.missingCredential(message("%@ cookies are disabled.", "Google Developer Program"));
    const invalid = (): never => {
      throw ctx.fail.parseFailure(
        message("Google Developer Program returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const json = (text: string): unknown => {
      try {
        return JSON.parse(text);
      } catch (error) {
        void error;
        return invalid();
      }
    };
    const array = (value: unknown): unknown[] => (Array.isArray(value) ? value : invalid());
    // Google Money arrays omit zero units and nanos.
    const integer = (value: unknown): number =>
      value === null || value === undefined
        ? 0
        : typeof value === "number" && Number.isSafeInteger(value)
          ? value
          : invalid();
    const money = (value: unknown) => {
      const [currency, units, nanos] = array(value);
      if (typeof currency !== "string" || !/^[A-Z]{3}$/.test(currency)) return invalid();
      return { currency, amount: integer(units) + integer(nanos) / 1e9 };
    };
    // A malformed timestamp means an unknown date, never a failed refresh.
    const date = (value: unknown): Date | undefined => {
      const seconds = Array.isArray(value) ? value[0] : undefined;
      return typeof seconds === "number" && Number.isSafeInteger(seconds) && seconds > 0
        ? ctx.date.unixSeconds(seconds)
        : undefined;
    };
    const day = (value: Date): string =>
      `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
    // WIZ_global_data values are JSON string literals.
    const pageValue = (html: string, key: string): string | undefined => {
      const literal = ctx.html.matchFirst(html, `"${key}":("(?:[^"\\\\]|\\\\.)*")`);
      return literal ? (json(literal) as string) : undefined;
    };
    // Signed-out requests redirect to accounts.google.com, which the host refuses, or answer 401 or 403.
    const denied = (response: CodexBarHTTPTextResponse): boolean => {
      if ((response.status >= 300 && response.status < 400) || response.status === 401 || response.status === 403)
        return true;
      if (response.status === 429) {
        throw ctx.fail.rateLimited(message("Google Developer Program is rate limiting requests. Try again later."));
      }
      if (response.status >= 500) {
        throw ctx.fail.providerUnavailable(message("Google Developer Program request failed. Try refreshing later."));
      }
      if (response.status !== 200) {
        throw ctx.fail.apiFailure(message("Google Developer Program request failed. Try refreshing later."));
      }
      return false;
    };
    let unapplied: string | undefined;
    let signedIn = false;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const emails: string[] = [];
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
          .flatMap((line) => array(json(line)))
          .find((entry) => Array.isArray(entry) && entry[0] === "wrb.fr" && entry[1] === "Ro0AYc") as
          | unknown[]
          | undefined;
        if (!result) return invalid();
        // A per-account RPC error has no string payload, so try the next account.
        if (typeof result[2] !== "string") continue;
        const list = array(json(result[2]))[0];
        // Benefit type 19 is the monthly Gen AI & Cloud credit of Google AI Pro and Ultra.
        const credit = array(list ?? [])
          .map((benefit) => array(benefit))
          .find((benefit) => benefit[0] === 19);
        if (!credit) continue;
        const offer = array(credit[9] ?? []);
        // A credit that is not applied to a billing account yet has no money fields.
        if (offer[6] === null || offer[6] === undefined) {
          unapplied ??= email;
          continue;
        }
        const billing = array(offer[6]);
        const granted = money(billing[0]);
        const remaining = money(billing[1]);
        if (granted.amount <= 0) return invalid();
        if (remaining.currency !== granted.currency) return invalid();
        const currency = granted.currency;
        const left = Math.max(0, remaining.amount);
        const expiresAt = date(offer[1]);
        const grantedAt = date(offer[16]);
        const amounts = message(
          "%@ of %@ left",
          ctx.format.currency(left, currency),
          ctx.format.currency(granted.amount, currency),
        );
        // The billing account is display-only, so an unexpected format never fails the refresh.
        const rows: CodexBarDetailRow[] =
          typeof billing[2] === "string"
            ? [{ label: "Billing account", value: billing[2].replace(/^billingAccounts\//, "") }]
            : [];
        if (grantedAt) rows.push({ label: "Granted", value: day(grantedAt) });
        return {
          primary: {
            usedPercent: ctx.pct(granted.amount - left, granted.amount),
            resetDescription: expiresAt ? `${amounts} · ${message("Expires %@", day(expiresAt))}` : amounts,
          },
          cost: { used: left, currency, period: "Monthly credits", balance: left },
          details: [{ title: "Billing", rows }],
          identity: { email, loginMethod: message("Browser session") },
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
                value: message("Not applied"),
                secondaryValue: "me.developers.google.com/benefits",
              },
            ],
          },
        ],
        identity: { email: unapplied, loginMethod: message("Browser session") },
        dataConfidence: "exact",
      };
    }
    if (signedIn)
      throw ctx.fail.permissionDenied(message("No Cloud credit found. Check your Google Developer Program benefits."));
    if (rejected) throw ctx.fail.authenticationExpired(`${message("Google session expired or invalid.")} ${signIn}`);
    throw ctx.fail.missingCredential(
      `${signIn} ${message("Supported browsers: %@. Use Manual for other browsers.", ctx.browser.supportedBrowsers)}`,
    );
  },
});
