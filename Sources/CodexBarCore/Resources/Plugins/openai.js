defineProvider({
  id: "openai",
  name: "OpenAI",
  endpoints: ["https://api.openai.com"],
  auth: { type: "bearer", secret: "OPENAI_API_KEY" },
  settings: [
    { key: "OPENAI_API_KEY", title: "API key", type: "secure" },
    { key: "OPENAI_PROJECT_ID", title: "Project ID", type: "plain" },
    { key: "OPENAI_LIVE_MINUTES", title: "Tokens per minute", type: "plain" },
    { key: "OPENAI_HISTORY_DAYS", title: "History days", type: "plain" },
  ],

  async fetchUsage(ctx) {
    function parseJSON(text) {
      try {
        return JSON.parse(text);
      } catch {
        throw ctx.fail.parseFailure("Failed to parse OpenAI API JSON");
      }
    }
    const projectID = ctx.settings.get("OPENAI_PROJECT_ID");
    const rawHistoryDays = Number(ctx.settings.get("OPENAI_HISTORY_DAYS") || "30");
    const historyDays = Number.isInteger(rawHistoryDays) ? Math.max(1, Math.min(365, rawHistoryDays)) : 30;

    function finite(value) {
      if (value === null || value === undefined || value === "") return null;
      const number = typeof value === "number" ? value : typeof value === "string" ? Number(value.trim()) : NaN;
      if (!Number.isFinite(number)) throw ctx.fail.parseFailure("OpenAI cost amount must be numeric");
      return number;
    }
    function integer(value, field) {
      if (value === null || value === undefined) return null;
      const number = typeof value === "number" ? value : NaN;
      if (!Number.isSafeInteger(number) || number < 0)
        throw ctx.fail.parseFailure(`OpenAI ${field} must be an integer`);
      return number;
    }
    function name(value, fallback) {
      if (value != null && typeof value !== "string") throw ctx.fail.parseFailure("Invalid OpenAI name");
      return typeof value === "string" && value.trim() ? value.trim() : fallback;
    }
    function queryURL(path, range, groupBy, page) {
      const query = [
        `start_time=${range.start}`,
        `end_time=${range.end}`,
        `bucket_width=${range.width || "1d"}`,
        `limit=${range.limit}`,
        ...(Array.isArray(groupBy) ? groupBy : [groupBy]).map((value) => `group_by=${encodeURIComponent(value)}`),
      ];
      if (projectID) query.push(`project_ids=${encodeURIComponent(projectID)}`);
      if (page) query.push(`page=${encodeURIComponent(page)}`);
      return `https://api.openai.com${path}?${query.join("&")}`;
    }
    function ranges() {
      const today = ctx.date.now();
      today.setUTCHours(0, 0, 0, 0);
      let cursor = Math.floor(today.getTime() / 1000) - (historyDays - 1) * 86400;
      let remaining = historyDays;
      const result = [];
      while (remaining > 0) {
        const limit = Math.min(31, remaining);
        result.push({ start: cursor, end: cursor + limit * 86400, limit });
        cursor += limit * 86400;
        remaining -= limit;
      }
      return result;
    }
    async function pages(path, groupBy) {
      const buckets = [];
      for (const range of ranges()) {
        let page = null;
        const seen = new Set();
        for (let count = 0; count < 100; count += 1) {
          const response = await ctx.http.get(queryURL(path, range, groupBy, page), {
            timeoutSeconds: 20,
            retryPolicy: "transientIdempotent",
          });
          if (response.status !== 200) {
            const kind =
              response.status === 401 || response.status === 403
                ? "authenticationExpired"
                : response.status === 429
                  ? "rateLimited"
                  : "apiFailure";
            throw ctx.fail[kind](`OpenAI API usage ${path} error: HTTP ${response.status}`);
          }
          const body = parseJSON(response.bodyText);
          if (
            !body ||
            typeof body !== "object" ||
            Array.isArray(body) ||
            !Array.isArray(body.data) ||
            typeof body.has_more !== "boolean" ||
            (body.next_page != null && typeof body.next_page !== "string")
          ) {
            throw ctx.fail.parseFailure(`Failed to parse OpenAI ${path} page`);
          }
          buckets.push(...body.data);
          if (!body.has_more) break;
          if (typeof body.next_page !== "string" || !body.next_page.trim()) {
            throw ctx.fail.parseFailure(`OpenAI ${path} pagination cursor missing`);
          }
          page = body.next_page.trim();
          if (seen.has(page)) throw ctx.fail.parseFailure(`OpenAI ${path} pagination cursor repeated`);
          seen.add(page);
          if (count === 99) throw ctx.fail.parseFailure(`OpenAI ${path} pagination exceeded 100 pages`);
        }
      }
      return buckets;
    }

    async function liveUsage() {
      if (ctx.settings.get("OPENAI_LIVE_MINUTES") === "0") return null;
      try {
        const fetchedAt = Math.floor(ctx.date.now().getTime() / 1000);
        const startTime = Math.floor(fetchedAt / 60) * 60 - 59 * 60;
        const response = await ctx.http.get(
          queryURL(
            "/v1/organization/usage/completions",
            { start: startTime, end: fetchedAt, limit: 60, width: "1m" },
            ["model", "batch"],
            null,
          ),
          { timeoutSeconds: 20 },
        );
        if (response.status !== 200) return null;
        const body = parseJSON(response.bodyText);
        if (
          !body ||
          !Array.isArray(body.data) ||
          body.data.length > 60 ||
          typeof body.has_more !== "boolean" ||
          (body.next_page != null && typeof body.next_page !== "string")
        )
          return null;
        let entries = 0;
        let totalTokens = 0;
        let totalRequests = 0;
        const buckets = body.data.map((raw) => {
          if (
            !raw ||
            typeof raw !== "object" ||
            Array.isArray(raw) ||
            !Number.isSafeInteger(raw.start_time) ||
            raw.start_time < startTime ||
            raw.start_time > fetchedAt ||
            raw.start_time % 60 !== 0 ||
            !Number.isSafeInteger(raw.end_time) ||
            raw.end_time <= raw.start_time ||
            !Array.isArray(raw.results) ||
            raw.results.length > 400
          )
            throw new Error("Invalid live bucket");
          const merged = new Map();
          for (const item of raw.results) {
            if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error("Invalid live model");
            if (item.batch != null && typeof item.batch !== "boolean") throw new Error("Invalid live batch");
            // input_tokens/output_tokens already aggregate text, audio, and image; audio fields are breakdowns.
            const inputTokens = integer(item.input_tokens, "input_tokens") || 0;
            const cachedInputTokens = integer(item.input_cached_tokens, "input_cached_tokens") || 0;
            const outputTokens = integer(item.output_tokens, "output_tokens") || 0;
            const requests = integer(item.num_model_requests, "num_model_requests") || 0;
            integer(item.input_audio_tokens, "input_audio_tokens");
            integer(item.output_audio_tokens, "output_audio_tokens");
            if (cachedInputTokens > inputTokens) throw new Error("Invalid cached tokens");
            totalTokens += inputTokens + outputTokens;
            totalRequests += requests;
            if (!Number.isSafeInteger(totalTokens) || !Number.isSafeInteger(totalRequests))
              throw new Error("Unsafe live totals");
            const modelName = name(item.model, "unknown");
            const row = {
              name: modelName,
              inputTokens,
              cachedInputTokens,
              outputTokens,
              requests,
              batchTokens: item.batch === true ? inputTokens + outputTokens : 0,
              batchRequests: item.batch === true ? requests : 0,
            };
            const prior = merged.get(modelName);
            if (prior) {
              for (const key of [
                "inputTokens",
                "cachedInputTokens",
                "outputTokens",
                "requests",
                "batchTokens",
                "batchRequests",
              ]) {
                row[key] += prior[key];
                if (!Number.isSafeInteger(row[key])) throw new Error("Unsafe live model totals");
              }
            }
            merged.set(modelName, row);
          }
          if (merged.size > 200) throw new Error("Too many live models in bucket");
          entries += merged.size;
          if (entries > 10000) throw new Error("Too many live models");
          return { startTime: raw.start_time, models: Array.from(merged.values()) };
        });
        return { windowMinutes: 60, startTime, fetchedAt, buckets };
      } catch (error) {
        if (error.transportClass === "cancelled") throw error;
        return null;
      }
    }

    const costBuckets = await pages("/v1/organization/costs", "line_item");
    const completionBuckets = await pages("/v1/organization/usage/completions", "model");
    const daily = new Map();
    function bucket(raw) {
      if (
        !raw ||
        typeof raw !== "object" ||
        Array.isArray(raw) ||
        !Number.isSafeInteger(raw.start_time) ||
        !Number.isSafeInteger(raw.end_time) ||
        !Array.isArray(raw.results)
      ) {
        throw ctx.fail.parseFailure("Failed to parse OpenAI usage bucket");
      }
      let value = daily.get(raw.start_time);
      if (!value) {
        value = {
          start: raw.start_time,
          end: raw.end_time,
          cost: 0,
          requests: 0,
          input: 0,
          cached: 0,
          output: 0,
          tokens: 0,
          models: new Map(),
          lines: new Map(),
        };
        daily.set(raw.start_time, value);
      }
      return value;
    }
    for (const raw of costBuckets) {
      const day = bucket(raw);
      for (const item of raw.results) {
        if (!item || typeof item !== "object" || Array.isArray(item))
          throw ctx.fail.parseFailure("Failed to parse OpenAI cost result");
        if (
          item.amount != null &&
          (typeof item.amount !== "object" ||
            Array.isArray(item.amount) ||
            (item.amount.currency != null && typeof item.amount.currency !== "string"))
        ) {
          throw ctx.fail.parseFailure("Invalid OpenAI cost amount");
        }
        const amount = item.amount ? finite(item.amount.value) || 0 : 0;
        day.cost += amount;
        const line = name(item.line_item, "API");
        day.lines.set(line, (day.lines.get(line) || 0) + amount);
      }
    }
    for (const raw of completionBuckets) {
      const day = bucket(raw);
      for (const item of raw.results) {
        if (!item || typeof item !== "object" || Array.isArray(item))
          throw ctx.fail.parseFailure("Failed to parse OpenAI completion result");
        const input = integer(item.input_tokens, "input_tokens") || 0;
        const cached = integer(item.input_cached_tokens, "input_cached_tokens") || 0;
        // input_tokens/output_tokens already aggregate text, audio, and image; audio fields are breakdowns.
        integer(item.input_audio_tokens, "input_audio_tokens");
        const output = integer(item.output_tokens, "output_tokens") || 0;
        integer(item.output_audio_tokens, "output_audio_tokens");
        const requests = integer(item.num_model_requests, "num_model_requests") || 0;
        const tokens = input + output;
        day.requests += requests;
        day.input += input;
        day.cached += cached;
        day.output += output;
        day.tokens += tokens;
        const modelName = name(item.model, "Responses and Chat Completions");
        const model = day.models.get(modelName) || { requests: 0, tokens: 0, input: 0, cached: 0, output: 0 };
        model.requests += requests;
        model.tokens += tokens;
        model.input += input;
        model.cached += cached;
        model.output += output;
        day.models.set(modelName, model);
      }
    }
    const days = Array.from(daily.values())
      .filter((day) => day.start * 1000 <= ctx.date.now().getTime())
      .sort((a, b) => a.start - b.start);
    const costDays =
      historyDays === 1
        ? days.filter(
            (day) => day.start * 1000 <= ctx.date.now().getTime() && ctx.date.now().getTime() < day.end * 1000,
          )
        : days.slice(-historyDays);
    const cost = costDays.reduce((sum, day) => sum + day.cost, 0);
    const live = await liveUsage();
    const identity = { loginMethod: projectID ? `Admin API: ${projectID}` : "Admin API" };
    if (projectID) identity.organization = `Project: ${projectID}`;
    return {
      usage: {
        cost: { used: cost, currency: "USD", period: historyDays === 1 ? "Today" : `Last ${historyDays} days` },
        identity,
      },
      sourceLabel: projectID ? "admin-api:project" : "admin-api",
      card: {
        openAIAPIUsage: {
          ...(live ? { live } : {}),
          historyDays,
          projectID: projectID || null,
          daily: days.map((day) => ({
            startTime: day.start,
            endTime: day.end,
            costUSD: day.cost,
            requests: day.requests,
            inputTokens: day.input,
            cachedInputTokens: day.cached,
            outputTokens: day.output,
            totalTokens: day.tokens,
            lineItems: Array.from(day.lines, ([name, costUSD]) => ({ name, costUSD })).sort(
              (a, b) => b.costUSD - a.costUSD || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
            ),
            models: Array.from(day.models, ([name, model]) => ({
              name,
              requests: model.requests,
              inputTokens: model.input,
              cachedInputTokens: model.cached,
              outputTokens: model.output,
              totalTokens: model.tokens,
            })).sort((a, b) => b.totalTokens - a.totalTokens || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)),
          })),
        },
      },
    };
  },
});
