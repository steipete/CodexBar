// Claude Platform on AWS: spend and token usage from the Usage and Cost Analytics API (beta).
// Each regional endpoint reports only its own workspaces, so every configured region is read and summed.
// The plugin host has no SigV4 support, so requests are signed here with a long-lived IAM access key.
// A manifest declares at most 16 origins, which bounds the supported regions.
const REGIONS = [
  "us-east-1",
  "us-east-2",
  "us-west-1",
  "us-west-2",
  "ca-central-1",
  "sa-east-1",
  "eu-west-1",
  "eu-west-2",
  "eu-west-3",
  "eu-central-1",
  "eu-north-1",
  "ap-south-1",
  "ap-northeast-1",
  "ap-northeast-2",
  "ap-southeast-1",
  "ap-southeast-2",
];
const SERVICE = "aws-external-anthropic";

// SigV4 needs SHA-256 and HMAC, and the plugin runtime has no crypto API.
const SHA256_K = [];
for (let candidate = 2; SHA256_K.length < 64; candidate += 1) {
  let prime = true;
  for (let factor = 2; factor * factor <= candidate; factor += 1) {
    if (candidate % factor === 0) {
      prime = false;
      break;
    }
  }
  if (prime) SHA256_K.push(Math.floor((Math.cbrt(candidate) % 1) * 4294967296));
}
const utf8 = (text) => {
  const bytes = [];
  for (const character of text) {
    const code = character.codePointAt(0);
    if (code < 0x80) bytes.push(code);
    else if (code < 0x800) bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    else if (code < 0x10000) bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    else {
      bytes.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return bytes;
};
const sha256 = (input) => {
  const bytes = input.slice();
  const bitLength = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (let shift = 56; shift >= 0; shift -= 8) bytes.push(Math.floor(bitLength / 2 ** shift) & 0xff);
  const state = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const rotate = (value, bits) => (value >>> bits) | (value << (32 - bits));
  const words = [];
  for (let offset = 0; offset < bytes.length; offset += 64) {
    for (let index = 0; index < 16; index += 1) {
      const at = offset + index * 4;
      words[index] = ((bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
    }
    for (let index = 16; index < 64; index += 1) {
      const low = words[index - 15];
      const high = words[index - 2];
      const sigma0 = rotate(low, 7) ^ rotate(low, 18) ^ (low >>> 3);
      const sigma1 = rotate(high, 17) ^ rotate(high, 19) ^ (high >>> 10);
      words[index] = (words[index - 16] + sigma0 + words[index - 7] + sigma1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = state;
    for (let index = 0; index < 64; index += 1) {
      const sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25);
      const choice = (e & f) ^ (~e & g);
      const first = (h + sum1 + choice + SHA256_K[index] + words[index]) >>> 0;
      const sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      h = g;
      g = f;
      f = e;
      e = (d + first) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (first + sum0 + majority) >>> 0;
    }
    [a, b, c, d, e, f, g, h].forEach((value, index) => {
      state[index] = (state[index] + value) >>> 0;
    });
  }
  const digest = [];
  for (const word of state) digest.push(word >>> 24, (word >>> 16) & 0xff, (word >>> 8) & 0xff, word & 0xff);
  return digest;
};
const hmac = (key, message) => {
  const block = key.length > 64 ? sha256(key) : key.slice();
  while (block.length < 64) block.push(0);
  const inner = sha256(block.map((byte) => byte ^ 0x36).concat(message));
  return sha256(block.map((byte) => byte ^ 0x5c).concat(inner));
};
const hex = (bytes) => bytes.map((byte) => (byte < 16 ? "0" : "") + byte.toString(16)).join("");
const encode = (text) =>
  encodeURIComponent(text).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
// The sorted, fully encoded form is both what is sent and what SigV4 signs.
const queryString = (parameters) =>
  parameters
    .map(([name, value]) => `${encode(name)}=${encode(value)}`)
    .sort()
    .join("&");
const sigV4Headers = (credentials, region, path, query, millis) => {
  const amzDate = new Date(millis).toISOString().replace(/[-:]|\.\d+/g, "");
  const date = amzDate.slice(0, 8);
  const host = `${SERVICE}.${region}.api.aws`;
  const scope = `${date}/${region}/${SERVICE}/aws4_request`;
  const canonical = [
    "GET",
    path,
    query,
    `host:${host}`,
    `x-amz-date:${amzDate}`,
    "",
    "host;x-amz-date",
    hex(sha256([])),
  ];
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(sha256(utf8(canonical.join("\n"))))].join("\n");
  let key = utf8(`AWS4${credentials.secret}`);
  for (const part of [date, region, SERVICE, "aws4_request"]) key = hmac(key, utf8(part));
  return {
    "x-amz-date": amzDate,
    Authorization:
      `AWS4-HMAC-SHA256 Credential=${credentials.id}/${scope}, SignedHeaders=host;x-amz-date, ` +
      `Signature=${hex(hmac(key, utf8(toSign)))}`,
  };
};

defineProvider({
  id: "claudeplatformaws",
  name: "Claude Platform on AWS",
  endpoints: REGIONS.map((region) => `https://${SERVICE}.${region}.api.aws`),
  // No host-owned auth: SigV4 signs each request separately, so the script builds the Authorization header.
  settings: [
    { key: "ANTHROPIC_AWS_ACCESS_KEY_ID", title: "AWS access key ID", type: "secure" },
    { key: "ANTHROPIC_AWS_SECRET_ACCESS_KEY", title: "AWS secret access key", type: "secure" },
    { key: "ANTHROPIC_AWS_REGIONS", title: "Regions", type: "plain" },
    { key: "ANTHROPIC_AWS_MONTHLY_BUDGET", title: "Monthly budget", type: "plain" },
    { key: "ANTHROPIC_AWS_DAILY_BUDGET", title: "Daily budget", type: "plain" },
    { key: "ANTHROPIC_AWS_TIME_ZONE", title: "Time zone", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const regions = [];
    for (const entry of (ctx.settings.get("ANTHROPIC_AWS_REGIONS") || "").toLowerCase().split(/[\s,]+/)) {
      if (!entry || regions.includes(entry)) continue;
      if (!REGIONS.includes(entry)) {
        throw ctx.fail.missingCredential(
          `Region ${entry.slice(0, 40)} is not supported for Claude Platform on AWS. Supported: ${REGIONS.join(", ")}.`,
        );
      }
      regions.push(entry);
    }
    if (!regions.length) {
      throw ctx.fail.missingCredential("Set the AWS regions that hold your workspaces, for example us-west-2.");
    }
    const credentials = {
      id: (ctx.settings.getSecret("ANTHROPIC_AWS_ACCESS_KEY_ID") || "").trim(),
      secret: (ctx.settings.getSecret("ANTHROPIC_AWS_SECRET_ACCESS_KEY") || "").trim(),
    };
    if (!credentials.id || !credentials.secret) {
      throw ctx.fail.missingCredential("Claude Platform on AWS requires an AWS access key ID and secret access key.");
    }
    // Budgets are display-only comparisons; they never cap AWS billing.
    const budgetSetting = (key, name) => {
      const text = (ctx.settings.get(key) || "").trim().replace(/^\$/, "").replace(/,/g, "");
      if (!text) return undefined;
      const amount = Number(text);
      if (!Number.isFinite(amount) || amount <= 0) {
        throw ctx.fail.apiFailure(`The Claude Platform on AWS ${name} must be a positive USD amount.`);
      }
      return amount;
    };
    const monthlyBudget = budgetSetting("ANTHROPIC_AWS_MONTHLY_BUDGET", "monthly budget");
    const dailyBudget = budgetSetting("ANTHROPIC_AWS_DAILY_BUDGET", "daily budget");
    // Days and months begin at midnight in this Mac's time zone, or in UTC when the setting says so.
    const zone = (ctx.settings.get("ANTHROPIC_AWS_TIME_ZONE") || "").trim().toLowerCase() || "local";
    if (zone !== "local" && zone !== "utc") {
      throw ctx.fail.apiFailure("The Claude Platform on AWS time zone must be local or utc.");
    }
    const local = zone === "local";

    const analyticsHeaders = {
      "anthropic-version": "2026-10-21",
      "anthropic-beta": "analytics-usage-cost-2026-08-24",
    };
    const get = (region, path, parameters, headers) => {
      const query = queryString(parameters);
      return ctx.http.get(`https://${SERVICE}.${region}.api.aws${path}${query ? `?${query}` : ""}`, {
        headers: { ...headers, ...sigV4Headers(credentials, region, path, query, Date.now()) },
        retryPolicy: "transientIdempotent",
      });
    };
    const rethrowCancellation = (error) => {
      if (error && error.transportClass === "cancelled") throw error;
    };

    // Calendar math runs on the engine's own local-time Date methods, or their UTC twins.
    const calendar = (millis) => {
      const date = new Date(millis);
      return local
        ? [date.getFullYear(), date.getMonth(), date.getDate(), date.getHours(), date.getMinutes()]
        : [date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes()];
    };
    const midnight = (year, month, day) => (local ? new Date(year, month, day).getTime() : Date.UTC(year, month, day));
    const pad = (value) => (value < 10 ? `0${value}` : String(value));
    const dayLabel = (millis) => {
      const [year, month, day] = calendar(millis);
      return `${year}-${pad(month + 1)}-${pad(day)}`;
    };
    const stamp = (millis) => new Date(millis).toISOString().replace(/\.\d+Z$/, "Z");
    const clock = (millis) => {
      const parts = calendar(millis);
      return `${dayLabel(millis)} ${pad(parts[3])}:${pad(parts[4])}${local ? "" : " UTC"}`;
    };

    // The host refresh clock drives the calendar and the cache; signing above uses the wall clock.
    const now = ctx.date.nowMillis();
    const [year, month, dayOfMonth] = calendar(now);
    const monthStart = midnight(year, month, 1);
    const nextMonthStart = midnight(year, month + 1, 1);
    // Day boundaries come from the calendar, not from 24-hour steps, so they survive daylight saving changes.
    const daysAgo = (count) => midnight(year, month, dayOfMonth - count);
    const dayStart = daysAgo(0);
    const dayMillis = 86400000;
    // One series serves the 30-day history, the forecast, and the period breakdowns; the API has no data
    // before 2026.
    const historyDays = 30;
    const windowStart = daysAgo(historyDays - 1);
    const seriesStart = Math.max(windowStart, Date.UTC(2026, 0, 1));
    const todayLabel = dayLabel(dayStart);
    const identity = { loginMethod: "AWS access key" };
    const dailyWindow = (spentToday) =>
      dailyBudget && spentToday != null
        ? {
            usedPercent: ctx.pct(spentToday, dailyBudget),
            windowMinutes: 1440,
            resetsAt: stamp(daysAgo(-1)),
          }
        : null;
    const monthlyWindow = (spent) =>
      monthlyBudget ? { usedPercent: ctx.pct(spent, monthlyBudget), resetsAt: stamp(nextMonthStart) } : null;

    // The API rounds both ends down to the hour, so the first hour of a month has no queryable range yet.
    if (now - monthStart < 3600000) {
      return {
        primary: dailyWindow(0),
        secondary: monthlyWindow(0),
        cost: { used: 0, currency: "USD", period: "This month" },
        identity,
      };
    }

    // Amounts are decimal strings in cents: "41280.000000" is $412.80.
    const dollars = (value) => {
      const number =
        typeof value === "number"
          ? value
          : typeof value === "string" && /^-?\d+(\.\d+)?$/.test(value)
            ? Number(value)
            : NaN;
      return Number.isFinite(number) ? number / 100 : null;
    };
    const page = (bodyText) => {
      let root;
      try {
        root = JSON.parse(bodyText);
      } catch (error) {
        void error;
        return null;
      }
      return root && typeof root === "object" && Array.isArray(root.data) ? root : null;
    };
    const dimension = (row, name) => (row.group && typeof row.group[name] === "string" ? row.group[name] : null);
    const parseCost = (bodyText) => {
      const root = page(bodyText);
      if (!root) return null;
      const rows = [];
      for (const row of root.data) {
        const amount = row && row.cost ? dollars(row.cost.amount) : null;
        const start = row && typeof row.starting_at === "string" ? Date.parse(row.starting_at) : NaN;
        if (amount == null || !Number.isFinite(start)) return null;
        rows.push({
          day: dayLabel(start),
          workspace: dimension(row, "workspace_id"),
          model: dimension(row, "model"),
          amount,
          list: dollars(row.cost.list_amount),
          requests: typeof row.cost.requests === "number" ? row.cost.requests : null,
        });
      }
      return {
        rows,
        hasMore: root.has_more === true,
        nextPage: typeof root.next_page === "string" && root.next_page ? root.next_page : null,
        refreshedAt: typeof root.data_refreshed_at === "string" ? root.data_refreshed_at : null,
      };
    };
    const parseUsage = (bodyText) => {
      const root = page(bodyText);
      if (!root) return null;
      const count = (value) =>
        typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
      const rows = [];
      for (const row of root.data) {
        const usage = row && row.usage;
        const start = row && typeof row.starting_at === "string" ? Date.parse(row.starting_at) : NaN;
        if (!usage || typeof usage !== "object" || !Number.isFinite(start)) return null;
        const creation = usage.cache_creation || {};
        rows.push({
          day: dayLabel(start),
          model: dimension(row, "model"),
          // Input counts every prompt token, whether uncached, read from cache, or written to it.
          input:
            count(usage.uncached_input_tokens) +
            count(usage.cache_read_input_tokens) +
            count(creation.ephemeral_5m_input_tokens) +
            count(creation.ephemeral_1h_input_tokens),
          output: count(usage.output_tokens),
        });
      }
      return {
        rows,
        hasMore: root.has_more === true,
        nextPage: typeof root.next_page === "string" && root.next_page ? root.next_page : null,
      };
    };
    const sum = (rows, field) => rows.reduce((total, row) => total + (row[field] || 0), 0);

    const cost = "/v1/organizations/analytics/cost";
    const usage = "/v1/organizations/analytics/usage";
    // A failed region fails the refresh: a partial sum would silently understate the month.
    const fetchTotal = async (region) => {
      // Grouped by workspace and model so one read gives both breakdowns and, summed, the month total.
      const response = await get(
        region,
        cost,
        [
          ["starting_at", stamp(monthStart)],
          ["ending_at", stamp(now)],
          ["group_by[]", "workspace_id"],
          ["group_by[]", "model"],
          ["limit", "1000"],
        ],
        analyticsHeaders,
      );
      if (response.status !== 200) {
        // The API's own message names the denied IAM action; response bodies are otherwise not echoed.
        let reason = "";
        try {
          const error = JSON.parse(response.bodyText).error;
          if (error && error.type === "permission_error" && typeof error.message === "string") {
            reason = ` ${error.message.replace(/\s+/g, " ").slice(0, 200)}`;
          }
        } catch (error) {
          void error;
        }
        const message = `Claude Platform on AWS (${region}) returned HTTP ${response.status}.${reason}`;
        if (response.status === 401) throw ctx.fail.authenticationExpired(message);
        if (response.status === 403) throw ctx.fail.permissionDenied(message);
        if (response.status === 429) throw ctx.fail.rateLimited(message);
        if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
        throw ctx.fail.apiFailure(message);
      }
      const total = parseCost(response.bodyText);
      if (!total) {
        throw ctx.fail.parseFailure(`Claude Platform on AWS (${region}) returned an unrecognized cost response.`);
      }
      if (total.hasMore) {
        throw ctx.fail.apiFailure(
          `More than 1,000 workspace and model combinations have spend in ${region}; the total would be incomplete.`,
        );
      }
      return total;
    };

    const fetchSeries = async (region, total) => {
      // The series below are best effort: without them the month total still stands, minus today's figure,
      // the forecast, the 30-day history, and every breakdown period except the month to date.
      // A series is read whole by following its cursor; one that fails or runs past the page cap is dropped.
      const series = async (path, parameters, parse) => {
        const rows = [];
        let cursor = null;
        for (let pages = 0; pages < 20; pages += 1) {
          let parsed = null;
          try {
            const response = await get(
              region,
              path,
              cursor ? parameters.concat([["page", cursor]]) : parameters,
              analyticsHeaders,
            );
            if (response.status === 200) parsed = parse(response.bodyText);
          } catch (error) {
            rethrowCancellation(error);
          }
          if (!parsed) return null;
          for (const row of parsed.rows) rows.push(row);
          if (!parsed.hasMore) return rows;
          if (!parsed.nextPage) return null;
          cursor = parsed.nextPage;
        }
        return null;
      };
      const bucketed = (end, width) => [
        ["starting_at", stamp(seriesStart)],
        ["ending_at", stamp(end)],
        ["time_bucket_width", width],
        ["order_by", "time"],
        ["order", "asc"],
        ["limit", "1000"],
      ];
      // The API buckets days in UTC. UTC days are read as daily buckets, which end at today's midnight (a later
      // end would be rounded down to it anyway), plus today as one unbucketed range, rounded down to the hour.
      // Local days are cut from hourly buckets instead, which takes more rows and so more pages.
      const ranges = local ? [{ parameters: bucketed(now, "1h") }] : [{ parameters: bucketed(dayStart, "1d") }];
      if (!local && now - dayStart >= 3600000) {
        ranges.push({
          parameters: [
            ["starting_at", stamp(dayStart)],
            ["ending_at", stamp(now)],
            ["limit", "1000"],
          ],
          today: true,
        });
      }
      const read = async (path, dimensions, parse) => {
        let rows = [];
        for (const range of ranges) {
          const grouped = range.parameters.concat(dimensions.map((name) => ["group_by[]", name]));
          const part = await series(path, grouped, parse);
          if (!part) return null;
          rows = rows.concat(range.today ? part.map((row) => ({ ...row, day: todayLabel })) : part);
        }
        return rows;
      };

      // Cost per workspace and model gives every breakdown period; token counts only exist per model.
      const daily = await read(cost, ["workspace_id", "model"], parseCost);
      const tokens = daily ? await read(usage, ["model"], parseUsage) : null;

      // Names are best effort and cached: listing is an extra permission and a CloudTrail management event.
      const hasWorkspaces = total.rows.some((row) => row.amount > 0 && row.workspace);
      const cacheKey = `workspaces-${region}`;
      let names = ctx.cache.get(cacheKey);
      if (hasWorkspaces && !names) {
        names = {};
        let ttl = 3600;
        try {
          const list = await get(
            region,
            "/v1/organizations/workspaces",
            [
              ["limit", "1000"],
              ["include_default", "true"],
              ["include_archived", "true"],
            ],
            { "anthropic-version": "2026-10-21" },
          );
          if (list.status === 200) {
            for (const workspace of JSON.parse(list.bodyText).data) {
              if (!workspace || typeof workspace.id !== "string" || typeof workspace.name !== "string") continue;
              const name = workspace.name.trim().slice(0, 80);
              if (name && ctx.isDetailLabel(name)) names[workspace.id] = name;
            }
            ttl = 86400;
          }
        } catch (error) {
          rethrowCancellation(error);
          names = {};
        }
        ctx.cache.set(cacheKey, names, ttl);
      }
      return { region, total, daily, tokens, names: names || {}, used: sum(total.rows, "amount") };
    };

    // Analytics data only moves when its watermark does, typically every four hours. Until an update is due
    // the last complete result is reused; after that a single month-total read looks for a newer watermark,
    // and only a newer one triggers the series reads. Four hours is a hint for when to look, not a schedule,
    // so a quiet region is still checked hourly.
    const quietMillis = 4 * 3600000;
    const quietCheckMillis = 3600000;
    const dueCheckMillis = 600000;
    const fetchRegion = async (region) => {
      // Keyed by day so today and the month never outlive midnight, by key so accounts never mix, and by time
      // zone because it decides how days are cut.
      const cacheKey = `spend|${region}|${hex(sha256(utf8(credentials.id))).slice(0, 12)}|${zone}|${todayLabel}`;
      const cached = ctx.cache.get(cacheKey);
      if (cached) {
        const due = !(now - Date.parse(cached.watermark) < quietMillis);
        const sinceCheck = now - cached.checkedAt;
        if (sinceCheck >= 0 && sinceCheck < (due ? dueCheckMillis : quietCheckMillis)) return cached.result;
      }
      const total = await fetchTotal(region);
      const unchanged = cached && total.refreshedAt === cached.watermark;
      const result = unchanged ? cached.result : await fetchSeries(region, total);
      // An incomplete result is retried on the next refresh instead of being held for hours.
      if (result.daily && result.tokens) {
        ctx.cache.set(cacheKey, { result, watermark: total.refreshedAt, checkedAt: now }, 21600);
      }
      return result;
    };

    const results = [];
    for (const region of regions) results.push(await fetchRegion(region));

    const totalRows = results.flatMap((result) => result.total.rows);
    const used = sum(totalRows, "amount");
    const list = sum(totalRows, "list");
    const requests = totalRows.some((row) => row.requests != null) ? sum(totalRows, "requests") : null;
    const dailyRows = results.every((result) => result.daily) ? results.flatMap((result) => result.daily) : null;
    const tokenRows = results.every((result) => result.tokens) ? results.flatMap((result) => result.tokens) : null;
    // The oldest watermark bounds how current the combined figure is.
    const refreshed = results
      .map((result) => result.total.refreshedAt)
      .filter(Boolean)
      .sort();

    const rows = [
      {
        label: "This month",
        value: monthlyBudget ? `${ctx.format.usd(used)} of ${ctx.format.usd(monthlyBudget)}` : ctx.format.usd(used),
        progress: monthlyBudget ? Math.min(1, Math.max(0, used / monthlyBudget)) : undefined,
        // Even spending through the month would have consumed this fraction of the budget by now.
        pace: monthlyBudget ? Math.min(1, Math.max(0, (now - monthStart) / (nextMonthStart - monthStart))) : undefined,
        usageValue: used,
      },
    ];
    let spentToday = null;
    let costUsage;
    if (dailyRows) {
      const byDay = {};
      for (const row of dailyRows) byDay[row.day] = (byDay[row.day] || 0) + Math.max(0, row.amount);
      spentToday = Math.round((byDay[todayLabel] || 0) * 1e6) / 1e6;
      rows.push({
        label: "Today",
        value: dailyBudget
          ? `${ctx.format.usd(spentToday)} of ${ctx.format.usd(dailyBudget)}`
          : ctx.format.usd(spentToday),
        secondaryValue: local ? "So far" : "UTC, so far",
        progress: dailyBudget ? Math.min(1, Math.max(0, spentToday / dailyBudget)) : undefined,
      });

      // Forecast: the month so far plus the average of the last seven completed days for the time left after
      // the watermark. Shown only when at least three of those days had spend.
      const recent = [];
      for (let offset = 1; offset <= 7; offset += 1) recent.push(byDay[dayLabel(daysAgo(offset))] || 0);
      if (recent.filter((amount) => amount > 0).length >= 3) {
        const dailyAverage = recent.reduce((total, amount) => total + amount, 0) / recent.length;
        const watermark = refreshed.length ? Date.parse(refreshed[0]) : now;
        const from = Math.min(now, Math.max(monthStart, Number.isFinite(watermark) ? watermark : now));
        rows.push({
          label: "Projected this month",
          value: ctx.format.usd(used + (dailyAverage * (nextMonthStart - from)) / dayMillis),
          secondaryValue: `${ctx.format.usd(dailyAverage)}/day (7-day avg)`,
        });
        if (monthlyBudget && used < monthlyBudget) {
          const runsOut = from + ((monthlyBudget - used) / dailyAverage) * dayMillis;
          rows.push({
            label: "Monthly budget lasts",
            value: runsOut < nextMonthStart ? `Until about ${dayLabel(runsOut)}` : "Through the month",
            severity: runsOut < nextMonthStart ? "warning" : undefined,
          });
        }
      }

      if (tokenRows) {
        // One entry per day and model; rows without a model (such as code execution) stay unattributed.
        const entries = {};
        const entry = (row) => {
          const key = `${row.day}|${row.model || ""}`;
          if (!entries[key]) {
            entries[key] = { date: row.day, inputTokens: 0, outputTokens: 0, requests: 0, cost: 0 };
            if (row.model) entries[key].model = row.model.slice(0, 120);
          }
          return entries[key];
        };
        const firstDay = dayLabel(windowStart);
        const inWindow = (row) => row.day >= firstDay && row.day <= todayLabel;
        for (const row of dailyRows.filter(inWindow)) {
          entry(row).cost += Math.max(0, row.amount);
          entry(row).requests += Math.max(0, Math.round(row.requests || 0));
        }
        for (const row of tokenRows.filter(inWindow)) {
          entry(row).inputTokens += row.input;
          entry(row).outputTokens += row.output;
        }
        costUsage = {
          currency: "USD",
          historyDays,
          // The host reads the day convention from this label.
          historyLabel: local ? "Last 30 days" : "Last 30 days (UTC)",
          windowEnd: todayLabel,
          entries: Object.keys(entries)
            .sort()
            .map((key) => entries[key]),
        };
      }
    }
    if (Math.abs(list - used) >= 0.005) rows.push({ label: "At list prices", value: ctx.format.usd(list) });
    if (requests != null) rows.push({ label: "Requests", value: ctx.format.number(requests) });
    const dataAsOf = refreshed.length ? Date.parse(refreshed[0]) : NaN;
    rows.push({ label: "Data as of", value: Number.isFinite(dataAsOf) ? clock(dataAsOf) : "No data yet" });
    const nextData = dataAsOf + quietMillis;
    if (Number.isFinite(nextData)) {
      rows.push({
        label: "Next data expected",
        value: nextData > now ? `About ${clock(nextData)}` : "Due now",
      });
    }

    const details = [{ title: "Spend", rows }];
    const share = (amount, total) => (total > 0 ? `${Math.round((amount / total) * 100)}%` : undefined);
    if (regions.length > 1) {
      details.push({
        title: "By region",
        rows: results.map((result) => ({
          label: result.region,
          value: ctx.format.usd(result.used),
          secondaryValue: share(result.used, used),
          usageValue: result.used,
        })),
      });
    }

    // Spend by model and by workspace, each over five periods. The sections are variants of one another, so
    // the card shows one at a time behind two pickers; shares are of the period's own total.
    const labelled = (rowsOf) =>
      results.flatMap((result) =>
        rowsOf(result).map((row) => ({
          day: row.day,
          amount: row.amount,
          model: row.model && ctx.isDetailLabel(row.model) ? row.model : "Other usage",
          workspace: row.workspace ? result.names[row.workspace] || row.workspace : `No workspace in ${result.region}`,
        })),
      );
    // The month to date comes from the month-total read, so it always matches the cost meter; the other
    // periods need the series.
    const periods = [{ pick: "MTD", title: "Month to date", rows: labelled((result) => result.total.rows) }];
    if (dailyRows) {
      const series = labelled((result) => result.daily);
      // Whole days, from the first through the last.
      const days = (start, end) => {
        const first = dayLabel(start);
        const last = dayLabel(end);
        return series.filter((row) => row.day >= first && row.day <= last);
      };
      periods.unshift({ pick: "30d", title: "Last 30 days", rows: days(windowStart, dayStart) });
      periods.push({ pick: "7d", title: "Last 7 days", rows: days(daysAgo(6), dayStart) });
      periods.push({ pick: "Yesterday", title: "Yesterday", rows: days(daysAgo(1), daysAgo(1)) });
      periods.push({ pick: "Today", title: "Today", rows: days(dayStart, dayStart) });
    }
    // Sums spend per label and lists the largest, folding the remainder into one row.
    const breakdown = (period, field, limit) => {
      // Labels come from the account, so no inherited key such as "constructor" may stand in for a total.
      const totals = Object.create(null);
      for (const row of period.rows) totals[row[field]] = (totals[row[field]] || 0) + row.amount;
      const ranked = Object.keys(totals)
        .map((label) => ({ label, amount: totals[label] }))
        .filter((row) => row.amount > 0)
        .sort((left, right) => right.amount - left.amount || (left.label < right.label ? -1 : 1));
      const total = sum(ranked, "amount");
      const shown = ranked.slice(0, limit);
      const sectionRows = shown.map((row) => ({
        label: row.label,
        value: ctx.format.usd(row.amount),
        secondaryValue: share(row.amount, total),
        usageValue: row.amount,
      }));
      if (ranked.length > shown.length) {
        const rest = sum(ranked.slice(shown.length), "amount");
        sectionRows.push({
          label: `${ranked.length - shown.length} more`,
          value: ctx.format.usd(rest),
          secondaryValue: share(rest, total),
        });
      }
      // An empty period still gets its section, so every picker combination has something to show.
      return sectionRows.length ? sectionRows : [{ label: "No spend", value: ctx.format.usd(0) }];
    };
    for (const dimension of [
      { pick: "Model", title: "By model", field: "model", limit: 8 },
      { pick: "Workspace", title: "By workspace", field: "workspace", limit: 10 },
    ]) {
      for (const period of periods) {
        details.push({
          title: `${dimension.title} · ${period.title}`,
          variant: [dimension.pick, period.pick],
          rows: breakdown(period, dimension.field, dimension.limit),
        });
      }
    }

    const snapshot = {
      primary: dailyWindow(spentToday),
      secondary: monthlyWindow(used),
      // The monthly budget is drawn by the window above; a limit here would add a second, identical bar.
      cost: { used, currency: "USD", period: "This month" },
      identity,
      dataConfidence: "exact",
      details,
    };
    if (costUsage) snapshot.costUsage = costUsage;
    return snapshot;
  },
});
