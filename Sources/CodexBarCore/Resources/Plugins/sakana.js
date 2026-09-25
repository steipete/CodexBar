defineProvider({
  id: "sakana",
  name: "Sakana AI",
  endpoints: ["https://console.sakana.ai"],
  auth: { type: "header", header: "Cookie", secret: "SAKANA_COOKIE" },
  capabilities: ["http-status"],
  settings: [
    { key: "SAKANA_COOKIE", title: "Cookie header", type: "secure" },
    { key: "OPTIONAL_USAGE", title: "Optional usage", type: "plain" },
    { key: "TIMEOUT", title: "Request timeout", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const url = "https://console.sakana.ai/billing";
    const options = {
      headers: { Accept: "text/html,application/xhtml+xml", "Accept-Language": "en-US,en;q=0.9" },
      timeoutSeconds: Number(ctx.settings.get("TIMEOUT") || 15),
    };
    const response =
      ctx.settings.get("OPTIONAL_USAGE") === "false"
        ? await ctx.http.get(url, options)
        : await ctx.http.getWithOptional(url, url + "?tab=payAsYouGo", options);
    const sameOrigin = (response) => /^https:\/\/console\.sakana\.ai(?::443)?\//i.test(response.url);
    if (
      [401, 403].includes(response.status) ||
      (response.status >= 300 && response.status < 400) ||
      !sameOrigin(response)
    ) {
      throw ctx.fail.authenticationExpired("Sakana login is required.");
    }
    if (response.status !== 200) throw ctx.fail.apiFailure(`Sakana billing fetch failed (HTTP ${response.status}).`);
    const fail = (message) => {
      throw ctx.fail.parseFailure(`Failed to parse Sakana billing page: ${message}`);
    };
    const html = response.bodyText;
    if (!html) fail("Billing page response was empty.");
    const capture = (pattern, text) => new RegExp(pattern, "i").exec(text)?.[1]?.trim() || undefined;
    const resetDate = (text) => {
      const match = /^(\w+) (\d{1,2}), (\d{4}) at (\d{1,2}):(\d{2}) (AM|PM)$/i.exec(text || "");
      if (!match) return undefined;
      const month = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
      ].indexOf(match[1].toLowerCase());
      const hour = Number(match[4]);
      const minute = Number(match[5]);
      if (month < 0 || hour < 1 || hour > 12 || minute > 59) return undefined;
      const date = new Date(
        Date.UTC(
          Number(match[3]),
          month,
          Number(match[2]),
          (hour % 12) + (match[6].toUpperCase() === "PM" ? 12 : 0),
          minute,
        ),
      );
      return date.getUTCMonth() === month && date.getUTCDate() === Number(match[2]) ? date : undefined;
    };
    const window = (label, windowMinutes) => {
      const match = new RegExp(`<p[^>]*>\\s*${label}\\s*</p>`, "i").exec(html);
      if (!match) return undefined;
      const rest = html.slice(match.index + match[0].length);
      const boundary =
        /<p[^>]*>\s*(?:5-hour|Weekly)\s*<\/p>|<div[^>]*data-slot=(?:"card"|'card'|"card-title"|'card-title')[^>]*>/i.exec(
          rest,
        );
      const body = rest.slice(0, boundary ? boundary.index : rest.length).trim();
      if (!body) return undefined;
      const percent = capture("<p[^>]*>\\s*([0-9]+(?:\\.[0-9]+)?)% used\\s*</p>", body);
      const usedPercent = Number(percent);
      if (percent === undefined || !Number.isFinite(usedPercent) || usedPercent < 0 || usedPercent > 100)
        fail(`Invalid ${label} usage percentage.`);
      return {
        usedPercent,
        windowMinutes,
        resetsAt: resetDate(capture("<p[^>]*>\\s*Resets on ([^<]+?)\\s*</p>", body)),
      };
    };
    const primary = window("5-hour", 300);
    const secondary = window("Weekly", 10080);
    if (!primary && !secondary) fail("Usage limit windows were not found.");
    const plan = capture('<div[^>]*data-slot="card-title"[^>]*>[\\s\\S]*?<span>\\s*([^<]+?)\\s*</span>', html);
    const price = capture(
      '<div[^>]*data-slot="card-title"[^>]*>[\\s\\S]*?<span>[^<]+</span>\\s*<span[^>]*>\\s*([^<]+?)\\s*</span>',
      html,
    );
    const details = [];
    const optional = response.optional;
    if (optional?.status === 200 && sameOrigin(optional)) {
      const payg = optional.bodyText;
      const amount = (value) => (value === undefined ? undefined : Number(value.replace(/,/g, "")));
      const balance = amount(
        capture(
          '<h2[^>]*>\\s*Credit balance\\s*</h2>[\\s\\S]{0,900}?<p[^>]*tabular-nums[^"]*"[^>]*>\\$?([0-9][0-9,]*(?:\\.[0-9]+)?)</p>',
          payg,
        ),
      );
      if (Number.isFinite(balance)) {
        const usage = amount(
          capture(
            "<h2[^>]*>\\s*Usage\\s*</h2>\\s*<span[^>]*>\\s*Total(?:<!--\\s*-->)?:\\s*(?:<!--\\s*-->)?\\$?([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*</span>",
            payg,
          ),
        );
        const period = capture('aria-label="Usage date range"[^>]*>([\\s\\S]*?)</button>', payg)
          ?.replace(/<!--.*?-->/g, "")
          .replace(/\s+/g, " ")
          .trim();
        const money = (amount) => ctx.format.currency(amount, "USD").slice(0, 120);
        const rows = [{ label: "Balance", value: money(balance) }];
        if (Number.isFinite(usage))
          rows.push({
            label: "Usage",
            value: money(usage),
            secondaryValue: period ? Array.from(period).slice(0, 120).join("") : undefined,
          });
        details.push({ title: "Extra usage", rows });
      }
    }
    return {
      primary,
      secondary,
      details,
      identity: { loginMethod: [plan, price].filter(Boolean).join(" ") || undefined },
    };
  },
});
