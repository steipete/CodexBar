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

    // Days and months are UTC, the granularity the analytics API buckets by.
    const now = Date.now();
    const today = new Date(now);
    const monthStart = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1);
    const dayStart = Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate());
    const dayMillis = 86400000;
    const stamp = (millis) => new Date(millis).toISOString().replace(/\.\d+Z$/, "Z");
    const dayLabel = (millis) => new Date(millis).toISOString().slice(0, 10);
    // One daily series serves both the 30-day history and the month split; the API has no data before 2026.
    const historyDays = 30;
    const windowStart = dayStart - (historyDays - 1) * dayMillis;
    const seriesStart = Math.max(Math.min(monthStart, windowStart), Date.UTC(2026, 0, 1));
    const monthLabel = dayLabel(monthStart);
    const todayLabel = dayLabel(dayStart);
    const identity = { loginMethod: "AWS access key" };

    // The API rounds both ends down to the hour, so the first hour of a month has no queryable range yet.
    if (now - monthStart < 3600000) {
      return { cost: { used: 0, currency: "USD", period: "This month" }, identity };
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
    const parseCost = (bodyText) => {
      const root = page(bodyText);
      if (!root) return null;
      const rows = [];
      for (const row of root.data) {
        const amount = row && row.cost ? dollars(row.cost.amount) : null;
        if (amount == null || typeof row.starting_at !== "string") return null;
        rows.push({
          day: row.starting_at.slice(0, 10),
          workspace: row.group && typeof row.group.workspace_id === "string" ? row.group.workspace_id : null,
          amount,
          list: dollars(row.cost.list_amount),
          requests: typeof row.cost.requests === "number" ? row.cost.requests : null,
        });
      }
      return {
        rows,
        hasMore: root.has_more === true,
        refreshedAt: typeof root.data_refreshed_at === "string" ? root.data_refreshed_at : null,
      };
    };
    const parseUsage = (bodyText) => {
      const root = page(bodyText);
      if (!root || root.has_more === true) return null;
      const count = (value) =>
        typeof value === "number" && Number.isFinite(value) && value > 0 ? Math.round(value) : 0;
      const rows = [];
      for (const row of root.data) {
        const usage = row && row.usage;
        if (!usage || typeof usage !== "object" || typeof row.starting_at !== "string") return null;
        const creation = usage.cache_creation || {};
        rows.push({
          day: row.starting_at.slice(0, 10),
          // Input counts every prompt token, whether uncached, read from cache, or written to it.
          input:
            count(usage.uncached_input_tokens) +
            count(usage.cache_read_input_tokens) +
            count(creation.ephemeral_5m_input_tokens) +
            count(creation.ephemeral_1h_input_tokens),
          output: count(usage.output_tokens),
        });
      }
      return rows;
    };
    const sum = (rows, field) => rows.reduce((total, row) => total + (row[field] || 0), 0);

    // A failed region fails the refresh: a partial sum would silently understate the month.
    const fetchRegion = async (region) => {
      const cost = "/v1/organizations/analytics/cost";
      // Grouped by workspace so one read gives both the breakdown and, summed, the month total.
      const response = await get(
        region,
        cost,
        [
          ["starting_at", stamp(monthStart)],
          ["ending_at", stamp(now)],
          ["group_by[]", "workspace_id"],
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
        throw ctx.fail.apiFailure(`More than 1,000 workspaces have spend in ${region}; the total would be incomplete.`);
      }

      // The series below are best effort: without them the month total still stands, minus today's split
      // and the 30-day history.
      const optional = async (path, parameters) => {
        try {
          const series = await get(region, path, parameters, analyticsHeaders);
          return series.status === 200 ? series.bodyText : null;
        } catch (error) {
          rethrowCancellation(error);
          return null;
        }
      };
      // Daily buckets end at today's UTC midnight: a later end would be rounded down to it anyway.
      const completedDays = [
        ["starting_at", stamp(seriesStart)],
        ["ending_at", stamp(dayStart)],
        ["time_bucket_width", "1d"],
        ["order_by", "time"],
        ["order", "asc"],
        ["limit", "31"],
      ];
      const seriesBody = await optional(cost, completedDays);
      const series = seriesBody ? parseCost(seriesBody) : null;
      const daily = series && !series.hasMore ? series : null;

      // Token counts come from the usage endpoint: completed days, then today so far as one unbucketed row.
      let tokens = null;
      const usage = "/v1/organizations/analytics/usage";
      const usageBody = daily ? await optional(usage, completedDays) : null;
      const usageRows = usageBody ? parseUsage(usageBody) : null;
      if (usageRows) {
        let todayRows = [];
        if (now - dayStart >= 3600000) {
          const todayBody = await optional(usage, [
            ["starting_at", stamp(dayStart)],
            ["ending_at", stamp(now)],
          ]);
          todayRows = todayBody ? parseUsage(todayBody) : null;
        }
        if (todayRows) tokens = usageRows.concat(todayRows.map((row) => ({ ...row, day: todayLabel })));
      }

      // Names are best effort and cached: listing is an extra permission and a CloudTrail management event.
      const spenders = total.rows.filter((row) => row.amount > 0 && row.workspace).map((row) => row.workspace);
      const cacheKey = `workspaces-${region}`;
      let names = ctx.cache.get(cacheKey);
      if (spenders.length && !names) {
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

    const results = [];
    for (const region of regions) results.push(await fetchRegion(region));

    const totalRows = results.flatMap((result) => result.total.rows);
    const used = sum(totalRows, "amount");
    const list = sum(totalRows, "list");
    const requests = totalRows.some((row) => row.requests != null) ? sum(totalRows, "requests") : null;
    const dailyRows = results.every((result) => result.daily) ? results.flatMap((result) => result.daily.rows) : null;
    const tokenRows = results.every((result) => result.tokens) ? results.flatMap((result) => result.tokens) : null;
    // The oldest watermark bounds how current the combined figure is.
    const refreshed = results
      .map((result) => result.total.refreshedAt)
      .filter(Boolean)
      .sort();

    const rows = [{ label: "This month", value: ctx.format.usd(used), usageValue: used }];
    let costUsage;
    if (dailyRows) {
      // Today is the month total less this month's completed days; revisions between the two reads can only
      // shrink it to zero.
      const monthRows = dailyRows.filter((row) => row.day >= monthLabel);
      const todaySpend = Math.max(0, Math.round((used - sum(monthRows, "amount")) * 1e6) / 1e6);
      rows.push({ label: "Today", value: ctx.format.usd(todaySpend), secondaryValue: "UTC, so far" });
      if (tokenRows) {
        const days = {};
        const entry = (day) =>
          days[day] || (days[day] = { date: day, inputTokens: 0, outputTokens: 0, requests: 0, cost: 0 });
        const firstDay = dayLabel(windowStart);
        for (const row of dailyRows) {
          if (row.day < firstDay || row.day >= todayLabel) continue;
          entry(row.day).cost += Math.max(0, row.amount);
          entry(row.day).requests += Math.max(0, Math.round(row.requests || 0));
        }
        entry(todayLabel).cost += todaySpend;
        if (requests != null) {
          entry(todayLabel).requests += Math.max(0, Math.round(requests - sum(monthRows, "requests")));
        }
        for (const row of tokenRows) {
          if (row.day < firstDay || row.day > todayLabel) continue;
          entry(row.day).inputTokens += row.input;
          entry(row.day).outputTokens += row.output;
        }
        costUsage = {
          currency: "USD",
          historyDays,
          historyLabel: "Last 30 days (UTC)",
          windowEnd: todayLabel,
          entries: Object.keys(days)
            .sort()
            .map((day) => days[day]),
        };
      }
    }
    if (Math.abs(list - used) >= 0.005) rows.push({ label: "At list prices", value: ctx.format.usd(list) });
    if (requests != null) rows.push({ label: "Requests", value: ctx.format.number(requests) });
    rows.push({
      label: "Data as of",
      value: refreshed.length ? `${refreshed[0].slice(0, 16).replace("T", " ")} UTC` : "No data yet",
    });

    const details = [{ title: "Spend", rows }];
    const share = (amount) => (used > 0 ? `${Math.round((amount / used) * 100)}%` : undefined);
    if (regions.length > 1) {
      details.push({
        title: "By region",
        rows: results.map((result) => ({
          label: result.region,
          value: ctx.format.usd(result.used),
          secondaryValue: share(result.used),
          usageValue: result.used,
        })),
      });
    }
    const spenders = results
      .flatMap((result) =>
        result.total.rows.map((row) => ({
          label: row.workspace ? result.names[row.workspace] || row.workspace : `No workspace in ${result.region}`,
          amount: row.amount,
        })),
      )
      .filter((row) => row.amount > 0)
      .sort((left, right) => right.amount - left.amount);
    if (spenders.length) {
      const shown = spenders.slice(0, 10);
      const workspaceRows = shown.map((row) => ({
        label: row.label,
        value: ctx.format.usd(row.amount),
        secondaryValue: share(row.amount),
        usageValue: row.amount,
      }));
      if (spenders.length > shown.length) {
        const rest = sum(spenders.slice(shown.length), "amount");
        workspaceRows.push({
          label: `${spenders.length - shown.length} more`,
          value: ctx.format.usd(rest),
          secondaryValue: share(rest),
        });
      }
      details.push({ title: "By workspace", rows: workspaceRows });
    }

    const snapshot = {
      cost: { used, currency: "USD", period: "This month" },
      identity,
      dataConfidence: "exact",
      details,
    };
    if (costUsage) snapshot.costUsage = costUsage;
    return snapshot;
  },
});
