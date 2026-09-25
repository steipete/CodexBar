function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
defineProvider({
  id: "raycast",
  name: "Raycast",
  endpoints: ["https://www.raycast.com"],
  settings: [{ key: "webTimeoutSeconds", title: "Web timeout", type: "plain" }],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["raycast.com", "www.raycast.com"],
  async fetchUsage(ctx) {
    const sessionCookie = (value) => {
      const match = /(?:^|;\s*)__raycast_session=([^;]*)/.exec(value);
      return !!match && match[1].trim().length > 0;
    };
    const missingSession = () => {
      throw ctx.fail.missingCredential(
        "No Raycast session cookies found. Sign in at www.raycast.com/settings or paste a Cookie header.",
      );
    };
    const domain = "www.raycast.com";
    const policy = ctx.browser.availability(domain);
    if (policy === "off") throw ctx.fail.missingCredential("Raycast cookies are disabled.");
    const timeoutRaw = Number(_nullishCoalesce(ctx.settings.get("webTimeoutSeconds"), () => "15"));
    const timeoutSeconds = Number.isFinite(timeoutRaw) ? Math.min(30, Math.max(1, Math.round(timeoutRaw))) : 15;
    let response;
    let rejected = false;
    for await (const session of ctx.browser.sessions(domain)) {
      const cookie = session.header
        .split(";")
        .map((part) => part.trim())
        .filter((part) => /^(?:__raycast_session|csrf_token)=/.test(part))
        .join("; ");
      if (!sessionCookie(cookie)) {
        ctx.browser.rejectCookie(domain, session);
        if (policy === "manual") break;
        continue;
      }
      const candidate = await ctx.http.get("https://www.raycast.com/frontend_api/current_user/ai_credits", {
        timeoutSeconds,
        headers: {
          Cookie: cookie,
          Accept: "application/json",
          Origin: "https://www.raycast.com",
          Referer: "https://www.raycast.com/settings",
          "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
        },
      });
      if (candidate.status === 401) {
        rejected = true;
        ctx.browser.rejectCookie(domain, session);
        if (policy === "manual") break;
        continue;
      }
      response = candidate;
      break;
    }
    if (!response) {
      if (rejected)
        throw ctx.fail.authenticationExpired(
          "Raycast website session expired. Sign in at www.raycast.com/settings or paste a fresh Cookie header.",
        );
      return missingSession();
    }
    if (response.status === 403) {
      throw ctx.fail.permissionDenied("Raycast denied access to AI credits for this account.");
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Raycast credits requests are rate limited.");
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable(`Raycast credits API returned HTTP ${response.status}.`);
    }
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(`Raycast credits API returned HTTP ${response.status}.`);
    }

    const fail = (field) => {
      throw ctx.fail.parseFailure(`Invalid Raycast credits response: ${field}`);
    };
    const object = (value, field) => {
      if (value === undefined || value === null) return {};
      if (typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value === "boolean") return fail(field);
      if (typeof value === "number") {
        return Number.isFinite(value) ? value : fail(field);
      }
      if (typeof value !== "string") return fail(field);
      const trimmed = value.trim();
      if (trimmed === "") return fail(field);
      if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(trimmed)) return fail(field);
      const parsed = Number(trimmed);
      return Number.isFinite(parsed) ? parsed : fail(field);
    };
    const text = (value) => (typeof value === "string" ? value.trim() || undefined : undefined);
    // No thousands grouping. The meter footnote is this text, and a grouped number would not match the source amount.
    const amount = (value) => {
      if (Number.isInteger(value)) return String(value);
      let text = value.toFixed(2);
      while (text.endsWith("0")) text = text.slice(0, -1);
      if (text.endsWith(".")) text = text.slice(0, -1);
      return text;
    };
    const planLabel = (tier) => {
      switch (tier) {
        case "pro":
          return "Pro";
        case "pro_plus":
          return "Pro+";
        case "max":
          return "Max";
        default:
          return tier;
      }
    };

    let decoded;
    try {
      decoded = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail("expected JSON");
    }
    const root = object(decoded, "expected an object");
    const remaining = number(root.remaining_balance_credits, "remaining_balance_credits");
    const total = number(root.total_balance_credits, "total_balance_credits");
    if (remaining === undefined && total === undefined) return fail("no credit amounts");
    if (remaining !== undefined && remaining < 0) return fail("remaining_balance_credits");
    if (total !== undefined && total < 0) return fail("total_balance_credits");

    let renewal;
    if (root.next_credits_at !== undefined && root.next_credits_at !== null) {
      if (typeof root.next_credits_at !== "string") return fail("next_credits_at");
      try {
        renewal = ctx.date.iso(root.next_credits_at);
      } catch (error) {
        void error;
        return fail("next_credits_at");
      }
    }
    const funding = object(root.funding_subscription, "funding_subscription");
    const plan = planLabel(text(funding.tier));
    const rows = [];
    if (remaining !== undefined) rows.push({ label: "Left", value: amount(remaining) });
    if (total !== undefined) rows.push({ label: "Total", value: amount(total) });
    // A positive total is one Credits meter. The balance lives in resetDescription, which the shared
    // card already prints under the bar. Left and Total rows stay only when that meter is absent,
    // so a zero allowance still has something to show.
    const meter = remaining !== undefined && total !== undefined && total > 0 ? { remaining, total } : undefined;

    return {
      primary: meter
        ? {
            usedPercent: ctx.pct(Math.max(0, meter.total - meter.remaining), meter.total),
            resetsAt: renewal,
            resetDescription: `${amount(meter.remaining)} / ${amount(meter.total)} credits left`,
          }
        : undefined,
      details: meter || !rows.length ? undefined : [{ title: "Credits", rows }],
      subscriptionRenewsAt: meter ? undefined : renewal,
      identity: plan ? { loginMethod: plan } : undefined,
      dataConfidence: "exact",
    };
  },
});
