defineProvider({
  id: "openai",
  name: "OpenAI",
  endpoints: ["https://api.openai.com"],
  auth: { type: "bearer", secret: "OPENAI_API_KEY" },
  settings: [
    { key: "OPENAI_API_KEY", title: "API key", type: "secure" },
    { key: "OPENAI_PROJECT_ID", title: "Project ID", type: "plain" },
    { key: "OPENAI_HISTORY_DAYS", title: "History days", type: "plain" },
    { key: "OPENAI_ALLOW_BALANCE_FALLBACK", title: "Balance fallback", type: "plain" },
  ],

  async fetchUsage(ctx) {
    const projectID = ctx.settings.get("OPENAI_PROJECT_ID");
    const rawHistoryDays = Number(ctx.settings.get("OPENAI_HISTORY_DAYS") || "30");
    const historyDays = Number.isInteger(rawHistoryDays) ? Math.max(1, Math.min(365, rawHistoryDays)) : 30;

    function finite(value, field, optional) {
      if (optional && (value === null || value === undefined || value === "")) return null;
      const number = typeof value === "number" ? value : typeof value === "string" ? Number(value.trim()) : NaN;
      if (!Number.isFinite(number)) throw new Error(`OpenAI ${field} must be numeric`);
      return number;
    }
    function integer(value, field, optional) {
      const number = finite(value, field, optional);
      if (number === null) return null;
      if (!Number.isInteger(number)) throw new Error(`OpenAI ${field} must be an integer`);
      return number;
    }
    function name(value, fallback) {
      return typeof value === "string" && value.trim() ? value.trim() : fallback;
    }
    function usd(value) {
      return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" }).format(Math.max(0, value));
    }
    function numberText(value) {
      return new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(value);
    }
    function queryURL(path, range, groupBy, page) {
      const query = [
        `start_time=${range.start}`,
        `end_time=${range.end}`,
        "bucket_width=1d",
        `limit=${range.limit}`,
        `group_by=${encodeURIComponent(groupBy)}`,
      ];
      if (projectID) query.push(`project_ids=${encodeURIComponent(projectID)}`);
      if (page) query.push(`page=${encodeURIComponent(page)}`);
      return `https://api.openai.com${path}?${query.join("&")}`;
    }
    function ranges() {
      const today = new Date();
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
          const response = await ctx.http.getJSON(queryURL(path, range, groupBy, page));
          if (response.status !== 200) throw new Error(`OpenAI ${path} error: HTTP ${response.status}`);
          const body = response.json;
          if (!body || typeof body !== "object" || Array.isArray(body) ||
              !Array.isArray(body.data) || typeof body.has_more !== "boolean") {
            throw new Error(`Failed to parse OpenAI ${path} page`);
          }
          buckets.push(...body.data);
          if (!body.has_more) break;
          if (typeof body.next_page !== "string" || !body.next_page.trim()) {
            throw new Error(`OpenAI ${path} pagination cursor missing`);
          }
          page = body.next_page.trim();
          if (seen.has(page)) throw new Error(`OpenAI ${path} pagination cursor repeated`);
          seen.add(page);
          if (count === 99) throw new Error(`OpenAI ${path} pagination exceeded 100 pages`);
        }
      }
      return buckets;
    }

    try {
      const costBuckets = await pages("/v1/organization/costs", "line_item");
      const completionBuckets = await pages("/v1/organization/usage/completions", "model");
      const daily = new Map();
      function bucket(raw) {
        if (!raw || typeof raw !== "object" || Array.isArray(raw) ||
            !Number.isInteger(raw.start_time) || !Number.isInteger(raw.end_time) || !Array.isArray(raw.results)) {
          throw new Error("Failed to parse OpenAI usage bucket");
        }
        let value = daily.get(raw.start_time);
        if (!value) {
          value = {
            start: raw.start_time, end: raw.end_time, cost: 0, requests: 0,
            input: 0, cached: 0, output: 0, tokens: 0, models: new Map(), lines: new Map(),
          };
          daily.set(raw.start_time, value);
        }
        return value;
      }
      for (const raw of costBuckets) {
        const day = bucket(raw);
        for (const item of raw.results) {
          if (!item || typeof item !== "object") throw new Error("Failed to parse OpenAI cost result");
          const amount = item.amount ? finite(item.amount.value, "cost amount", true) || 0 : 0;
          day.cost += amount;
          const line = name(item.line_item, "API");
          day.lines.set(line, (day.lines.get(line) || 0) + amount);
        }
      }
      for (const raw of completionBuckets) {
        const day = bucket(raw);
        for (const item of raw.results) {
          if (!item || typeof item !== "object") throw new Error("Failed to parse OpenAI completion result");
          const input = integer(item.input_tokens, "input_tokens", true) || 0;
          const cached = integer(item.input_cached_tokens, "input_cached_tokens", true) || 0;
          const audioInput = integer(item.input_audio_tokens, "input_audio_tokens", true) || 0;
          const output = integer(item.output_tokens, "output_tokens", true) || 0;
          const audioOutput = integer(item.output_audio_tokens, "output_audio_tokens", true) || 0;
          const requests = integer(item.num_model_requests, "num_model_requests", true) || 0;
          const tokens = input + audioInput + output + audioOutput;
          day.requests += requests;
          day.input += input + audioInput;
          day.cached += cached;
          day.output += output + audioOutput;
          day.tokens += tokens;
          const modelName = name(item.model, "Responses and Chat Completions");
          const model = day.models.get(modelName) || { requests: 0, tokens: 0 };
          model.requests += requests;
          model.tokens += tokens;
          day.models.set(modelName, model);
        }
      }
      const days = Array.from(daily.values()).sort((a, b) => a.start - b.start);
      const totals = days.reduce((sum, day) => {
        sum.cost += day.cost; sum.requests += day.requests; sum.input += day.input;
        sum.cached += day.cached; sum.output += day.output; sum.tokens += day.tokens;
        return sum;
      }, { cost: 0, requests: 0, input: 0, cached: 0, output: 0, tokens: 0 });
      const models = new Map();
      const lines = new Map();
      for (const day of days) {
        for (const [modelName, value] of day.models) {
          const model = models.get(modelName) || { requests: 0, tokens: 0 };
          model.requests += value.requests; model.tokens += value.tokens; models.set(modelName, model);
        }
        for (const [line, cost] of day.lines) lines.set(line, (lines.get(line) || 0) + cost);
      }
      const topModels = Array.from(models.entries()).sort((a, b) => b[1].tokens - a[1].tokens || a[0].localeCompare(b[0]));
      const topLines = Array.from(lines.entries()).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
      const chartDays = days.slice(-120);
      const summaryRows = [
        { label: "Spend", value: usd(totals.cost), secondaryValue: `Last ${historyDays} days` },
        { label: "Requests", value: numberText(totals.requests) },
        { label: "Tokens", value: numberText(totals.tokens), secondaryValue: `${numberText(totals.input)} input · ${numberText(totals.output)} output` },
        { label: "Cached input", value: numberText(totals.cached) },
      ];
      if (days.length > chartDays.length) {
        summaryRows.push({ label: "Chart range", value: `Last ${chartDays.length} days` });
      }
      const details = [{
        title: "Usage summary",
        rows: summaryRows,
        chart: {
          kind: "bars",
          title: "Daily spend",
          unit: "USD",
          points: chartDays.map(day => ({ label: new Date(day.start * 1000).toISOString().slice(0, 10), value: day.cost })),
        },
      }];
      if (topModels.length) {
        details.push({
          title: "Models",
          rows: topModels.slice(0, 24).map(item => ({
            label: item[0], value: `${numberText(item[1].tokens)} tokens`, secondaryValue: `${item[1].requests} requests`,
          })),
        });
      }
      if (topLines.length) {
        details.push({
          title: "Line items",
          rows: topLines.slice(0, 24).map(item => ({ label: item[0], value: usd(item[1]) })),
        });
      }
      const identity = { loginMethod: projectID ? `Admin API: ${projectID}` : "Admin API" };
      if (projectID) identity.organization = `Project: ${projectID}`;
      return {
        cost: { used: totals.cost, currency: "USD", period: historyDays === 1 ? "Today" : `Last ${historyDays} days` },
        identity,
        details,
      };
    } catch (usageError) {
      if (ctx.settings.get("OPENAI_ALLOW_BALANCE_FALLBACK") !== "1") throw usageError;
      const response = await ctx.http.getJSON("https://api.openai.com/v1/dashboard/billing/credit_grants");
      if (response.status !== 200) throw usageError;
      const body = response.json;
      if (!body || typeof body !== "object" || Array.isArray(body)) throw usageError;
      const granted = finite(body.total_granted, "total_granted", false);
      const used = finite(body.total_used, "total_used", false);
      const available = finite(body.total_available, "total_available", false);
      const futureExpiries = body.grants && Array.isArray(body.grants.data)
        ? body.grants.data.map(item => item && finite(item.expires_at, "expires_at", true))
          .filter(value => value !== null && value * 1000 > Date.now()).sort((a, b) => a - b)
        : [];
      const resetsAt = futureExpiries.length ? ctx.date.unixSeconds(futureExpiries[0]) : null;
      const primary = {
        usedPercent: granted > 0 ? ctx.pct(used, granted) : available > 0 ? 0 : 100,
        resetDescription: `${usd(available)} available`,
      };
      if (resetsAt) primary.resetsAt = resetsAt;
      const cost = { used: Math.max(0, used), limit: Math.max(0, granted), currency: "USD", period: "API credits" };
      if (resetsAt) cost.resetsAt = resetsAt;
      return {
        primary,
        cost,
        identity: { loginMethod: `API balance: ${usd(available)}` },
        details: [{
          title: "API credits",
          rows: [
            { label: "Available", value: usd(available) },
            { label: "Used", value: usd(used) },
            { label: "Granted", value: usd(granted) },
          ],
        }],
      };
    }
  },
});
