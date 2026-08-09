defineProvider({
  id: "poe",
  name: "Poe",
  endpoints: ["https://api.poe.com"],
  auth: { type: "bearer", secret: "POE_API_KEY" },
  settings: [
    {
      key: "POE_API_KEY",
      title: "API key",
      subtitle: "Poe API key used for point balance and history.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    const balanceResponse = await ctx.http.getJSON("https://api.poe.com/usage/current_balance");
    if (balanceResponse.status === 401 || balanceResponse.status === 403) {
      throw new Error("Invalid or expired Poe API token");
    }
    if (balanceResponse.status < 200 || balanceResponse.status >= 300) {
      throw new Error(`Poe API error: HTTP ${balanceResponse.status}`);
    }
    const payload = balanceResponse.json;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw new Error("Failed to parse Poe balance response");
    }

    function optionalNumber(value, field) {
      if (value === null || value === undefined) return null;
      const number = typeof value === "number" ? value : typeof value === "string" ? Number(value.trim()) : NaN;
      if (!Number.isFinite(number)) throw new Error(`Poe ${field} must be numeric`);
      return number;
    }
    function compact(value) {
      return ctx.format.number(value, {
        maximumFractionDigits: value >= 1000 ? 0 : 1,
      });
    }
    function entryDate(value) {
      if (typeof value === "number" && Number.isFinite(value)) {
        if (value > 100000000000000) return new Date(value / 1000);
        if (value > 1000000000000) return new Date(value);
        return new Date(value * 1000);
      }
      if (typeof value === "string" && value.trim()) {
        const numeric = Number(value);
        if (Number.isFinite(numeric)) return entryDate(numeric);
        const date = new Date(value);
        if (Number.isFinite(date.getTime())) return date;
      }
      return null;
    }
    function timeString(date) {
      const pad = (value) => String(value).padStart(2, "0");
      return `${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())} ${pad(date.getUTCHours())}:${pad(date.getUTCMinutes())}`;
    }
    function summaryRow(label, summary) {
      const secondary = [`${summary.requests} requests`];
      if (summary.hasCost) secondary.push(`$${summary.cost.toFixed(2)}`);
      return {
        label,
        value: `${compact(summary.points)} points`,
        secondaryValue: secondary.join(" · "),
      };
    }

    const balance = optionalNumber(payload.current_point_balance, "current_point_balance");
    const entries = [];
    try {
      let cursor = null;
      const cutoff = Date.now() - 30 * 86400000;
      for (let page = 0; page < 5; page += 1) {
        const query = cursor ? `?limit=100&starting_after=${encodeURIComponent(cursor)}` : "?limit=100";
        const response = await ctx.http.getJSON(`https://api.poe.com/usage/points_history${query}`);
        if (response.status < 200 || response.status >= 300) throw new Error(`HTTP ${response.status}`);
        const root = response.json;
        if (!root || typeof root !== "object" || Array.isArray(root)) throw new Error("invalid history JSON");
        const rows = Array.isArray(root.data)
          ? root.data
          : Array.isArray(root.items)
            ? root.items
            : Array.isArray(root.results)
              ? root.results
              : [];
        for (const row of rows) {
          if (!row || typeof row !== "object" || Array.isArray(row)) continue;
          const date = entryDate(row.creation_time ?? row.timestamp ?? row.created_at);
          if (!date || date.getTime() < cutoff) continue;
          const points = Math.max(0, optionalNumber(row.cost_points ?? row.points ?? row.point_cost, "points") ?? 0);
          const cost = optionalNumber(row.cost_usd ?? row.usd, "cost_usd");
          const model = typeof row.bot_name === "string" && row.bot_name.trim() ? row.bot_name.trim() : "unknown";
          const usageType =
            typeof row.usage_type === "string" && row.usage_type.trim() ? row.usage_type.trim() : "unknown";
          entries.push({ date, points, cost, model, usageType });
        }
        const next = typeof root.next_cursor === "string" && root.next_cursor.trim() ? root.next_cursor.trim() : null;
        cursor =
          next ||
          (root.has_more === true && rows.length && typeof rows[rows.length - 1].query_id === "string"
            ? rows[rows.length - 1].query_id.trim()
            : null);
        if (!cursor) break;
        const lastDate = rows.length
          ? entryDate(
              rows[rows.length - 1].creation_time ??
                rows[rows.length - 1].timestamp ??
                rows[rows.length - 1].created_at,
            )
          : null;
        if (lastDate && lastDate.getTime() < cutoff) break;
      }
    } catch {}

    const daily = new Map();
    const models = new Map();
    const types = new Map();
    for (const entry of entries) {
      const day = entry.date.toISOString().slice(0, 10);
      const bucket = daily.get(day) || { points: 0, requests: 0, cost: 0, hasCost: false };
      bucket.points += entry.points;
      bucket.requests += 1;
      if (entry.cost !== null) {
        bucket.cost += Math.max(0, entry.cost);
        bucket.hasCost = true;
      }
      daily.set(day, bucket);
      models.set(entry.model, (models.get(entry.model) || 0) + entry.points);
      types.set(entry.usageType, (types.get(entry.usageType) || 0) + entry.points);
    }
    const days = Array.from(daily.entries()).sort((a, b) => a[0].localeCompare(b[0]));
    const summarize = (count) =>
      days.slice(-count).reduce(
        (sum, item) => {
          sum.points += item[1].points;
          sum.requests += item[1].requests;
          if (item[1].hasCost) {
            sum.cost += item[1].cost;
            sum.hasCost = true;
          }
          return sum;
        },
        { points: 0, requests: 0, cost: 0, hasCost: false },
      );
    const seven = summarize(7);
    const thirty = summarize(30);
    const now = new Date(Date.now());
    const todayUTC = now.toISOString().slice(0, 10);
    const todayEntries = entries.filter((entry) => entry.date.toISOString().slice(0, 10) === todayUTC);
    const today = todayEntries.reduce(
      (sum, entry) => {
        sum.points += entry.points;
        sum.requests += 1;
        if (entry.cost !== null) {
          sum.cost += Math.max(0, entry.cost);
          sum.hasCost = true;
        }
        return sum;
      },
      { points: 0, requests: 0, cost: 0, hasCost: false },
    );
    const topModel = Array.from(models.entries()).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))[0];
    const topTypes = Array.from(types.entries()).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    const rows = [];
    if (balance !== null) rows.push({ label: "Current balance", value: `${compact(balance)} points` });
    if (entries.length) {
      rows.push(summaryRow("Today", today));
      rows.push(summaryRow("Last 7 days", seven));
      rows.push(summaryRow("Last 30 days", thirty));
      if (topModel)
        rows.push({ label: "Top model", value: topModel[0], secondaryValue: `${compact(topModel[1])} points` });
      if (topTypes.length) {
        rows.push({
          label: "Usage mix",
          value: topTypes
            .slice(0, 2)
            .map((item) => `${item[0]}: ${compact(item[1])} points`)
            .join(" · "),
        });
      }
      entries
        .slice()
        .sort((a, b) => b.date - a.date)
        .slice(0, 3)
        .forEach((entry, index) => {
          rows.push({
            label: index === 0 ? "Recent activity" : timeString(entry.date),
            value: index === 0 ? `${timeString(entry.date)} · ${entry.model}` : entry.model,
            secondaryValue: `${compact(entry.points)} points`,
          });
        });
    }
    const section = { title: "Points", rows };
    if (days.length) {
      section.chart = {
        kind: "bars",
        title: "Daily points",
        unit: "points",
        points: days.map((item) => ({ label: item[0], value: item[1].points })),
      };
    }
    const result = { details: [section], identity: {} };
    if (balance !== null) result.identity.loginMethod = `Balance: ${compact(balance)} points`;
    return result;
  },
});
