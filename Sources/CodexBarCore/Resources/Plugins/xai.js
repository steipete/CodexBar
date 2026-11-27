defineProvider({
  id: "xai",
  name: "xAI",
  endpoints: ["https://management-api.x.ai"],
  auth: { type: "bearer", secret: "XAI_MANAGEMENT_API_KEY" },
  settings: [
    { key: "XAI_MANAGEMENT_API_KEY", title: "Management API key", type: "secure" },
    { key: "XAI_TEAM_ID", title: "Team ID", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const team = ctx.settings.get("XAI_TEAM_ID");
    if (!team || team.includes("/") || team === "." || team === "..") {
      throw ctx.fail.missingCredential("Missing or invalid xAI team ID");
    }
    const root = `https://management-api.x.ai/v1/billing/teams/${encodeURIComponent(team)}`;
    const balanceResponse = await ctx.http.getJSON(`${root}/prepaid/balance`);
    if (balanceResponse.status === 401 || balanceResponse.status === 403) {
      throw ctx.fail.authenticationExpired(
        "xAI rejected the Management API key. Create one in the xAI Console under Settings > Management Keys; inference API keys are not accepted.",
      );
    }
    if (balanceResponse.status === 404) {
      throw ctx.fail.apiFailure(
        "xAI returned 404 for this team. Check the team ID, and that the Management key belongs to the same team.",
      );
    }
    if (balanceResponse.status === 429) {
      throw ctx.fail.rateLimited("xAI Management API rate limit exceeded. Usage will refresh on the next cycle.");
    }
    if (balanceResponse.status < 200 || balanceResponse.status >= 300) {
      throw ctx.fail.apiFailure(`xAI Management API returned HTTP ${balanceResponse.status}.`);
    }
    const raw = balanceResponse.json && balanceResponse.json.total && balanceResponse.json.total.val;
    if (typeof raw !== "string" || !/^-?\d+(\.\d+)?$/.test(raw.trim())) {
      throw ctx.fail.parseFailure("Could not parse xAI billing data: balance total.val is not a cent amount");
    }
    const balance = -Number(raw) / 100;
    const parseSignedCents = (value) => {
      if (typeof value !== "string" || !/^-?\d+$/.test(value)) return undefined;
      const parsed = Number(value);
      return Number.isSafeInteger(parsed) ? parsed : undefined;
    };
    let liveRemaining;
    let currentCycleSpend;
    let billingCycleLabel;
    let spendingLimit;
    try {
      const preview = await ctx.http.getJSON(`${root}/postpaid/invoice/preview`, { timeoutSeconds: 5 });
      if (preview.status >= 200 && preview.status < 300) {
        const invoice = preview.json?.coreInvoice;
        const invoiceDueCents = parseSignedCents(invoice?.amountAfterVat);
        const rawPrepaidUsed = invoice?.prepaidCreditsUsed;
        const prepaidUsedVal =
          rawPrepaidUsed === undefined || rawPrepaidUsed === null ? 0 : parseSignedCents(rawPrepaidUsed?.val);
        if (
          invoiceDueCents !== undefined &&
          prepaidUsedVal !== undefined &&
          Number.isSafeInteger(invoiceDueCents - prepaidUsedVal)
        ) {
          liveRemaining = balance - (invoiceDueCents - prepaidUsedVal) / 100;
        }
        const currentCycleCents = parseSignedCents(invoice?.totalWithCorr?.val);
        if (currentCycleCents !== undefined) {
          currentCycleSpend = currentCycleCents / 100;
        }
        const cycle = preview.json?.billingCycle;
        if (
          cycle &&
          typeof cycle.year === "number" &&
          typeof cycle.month === "number" &&
          Number.isSafeInteger(cycle.year) &&
          Number.isSafeInteger(cycle.month) &&
          cycle.year >= 2000 &&
          cycle.year <= 9999 &&
          cycle.month >= 1 &&
          cycle.month <= 12
        ) {
          billingCycleLabel = `${cycle.year}-${String(cycle.month).padStart(2, "0")}`;
        }
        const spendingLimitCents = parseSignedCents(preview.json?.effectiveSpendingLimit);
        if (spendingLimitCents !== undefined && spendingLimitCents > 0) {
          spendingLimit = spendingLimitCents / 100;
        }
      }
    } catch (error) {
      if (error.transportClass === "cancelled") throw error;
    }
    const now = ctx.date.now();
    const start = new Date(now);
    start.setUTCDate(start.getUTCDate() - 29);
    start.setUTCHours(0, 0, 0, 0);
    const todayUTC = now.toISOString().slice(0, 10);
    const timestamp = (date) =>
      `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}-${String(date.getUTCDate()).padStart(2, "0")} ${String(date.getUTCHours()).padStart(2, "0")}:${String(date.getUTCMinutes()).padStart(2, "0")}:${String(date.getUTCSeconds()).padStart(2, "0")}`;
    const TOKEN_UNIT_TYPES = {
      "Prompt text tokens": "input",
      "Cached prompt text tokens": "cacheRead",
      "Completion text tokens": "completion",
      "Reasoning text tokens": "reasoning",
    };
    let entries = [];
    let totalSpend30d = 0;
    let partial = false;
    let historyAvailable = false;
    try {
      const usage = await ctx.http.postJSON(`${root}/usage`, {
        body: {
          analyticsRequest: {
            timeRange: { startTime: timestamp(start), endTime: timestamp(now), timezone: "Etc/GMT" },
            timeUnit: "TIME_UNIT_DAY",
            values: [
              { name: "usd", aggregation: "AGGREGATION_SUM" },
              { name: "units", aggregation: "AGGREGATION_SUM" },
              { name: "transactions", aggregation: "AGGREGATION_SUM" },
            ],
            groupBy: ["description", "unit_type"],
            filters: [],
          },
        },
      });
      if (usage.status === 401 || usage.status === 403) {
        throw ctx.fail.authenticationExpired(
          "xAI rejected the Management API key. Create one in the xAI Console under Settings > Management Keys; inference API keys are not accepted.",
        );
      }
      if (usage.status >= 200 && usage.status < 300) {
        if (!usage.json || !Array.isArray(usage.json.timeSeries)) {
          throw new Error("invalid xAI usage history");
        }
        const buckets = new Map();
        const observedDays = new Set();
        for (const series of usage.json.timeSeries) {
          if (
            !series ||
            !Array.isArray(series.group) ||
            series.group.length !== 2 ||
            typeof series.group[0] !== "string" ||
            typeof series.group[1] !== "string" ||
            !Array.isArray(series.dataPoints)
          ) {
            throw new Error("invalid xAI usage history");
          }
          const rawDescription = series.group[0].trim();
          const cleanedModel = rawDescription.startsWith("API ") ? rawDescription.slice(4).trim() : rawDescription;
          const model = cleanedModel.length > 0 ? cleanedModel : undefined;
          const unitType = series.group[1].trim();
          const tokenKind = TOKEN_UNIT_TYPES[unitType];
          for (const point of series.dataPoints) {
            const date = new Date(point.timestamp);
            const values = Array.isArray(point.values) ? point.values : undefined;
            const usd = values && values.length >= 3 ? values[0] : undefined;
            const units = values && values.length >= 3 ? values[1] : undefined;
            const transactions = values && values.length >= 3 ? values[2] : undefined;
            if (
              !Number.isFinite(date.getTime()) ||
              typeof usd !== "number" ||
              !Number.isFinite(usd) ||
              usd < 0 ||
              typeof units !== "number" ||
              !Number.isFinite(units) ||
              units < 0 ||
              (tokenKind && !Number.isSafeInteger(units)) ||
              typeof transactions !== "number" ||
              !Number.isFinite(transactions) ||
              transactions < 0 ||
              !Number.isSafeInteger(transactions)
            ) {
              throw new Error("invalid xAI usage history");
            }
            const day = date.toISOString().slice(0, 10);
            observedDays.add(day);
            if (usd === 0 && units === 0 && transactions === 0) {
              continue;
            }
            const key = `${day}\u001F${model || ""}`;
            let bucket = buckets.get(key);
            if (!bucket) {
              bucket = {
                day,
                model,
                cost: 0,
                inputTokens: 0,
                cacheReadTokens: 0,
                hasCacheReadTokens: false,
                completionTokens: 0,
                reasoningTokens: 0,
                hasReasoningTokens: false,
                promptTx: 0,
                maxTokenTx: 0,
                nonTokenTx: 0,
              };
              buckets.set(key, bucket);
            }
            bucket.cost += usd;
            if (!Number.isFinite(bucket.cost)) {
              throw new Error("invalid xAI usage history");
            }
            if (tokenKind === "input") {
              bucket.inputTokens += units;
              bucket.promptTx += transactions;
              if (transactions > bucket.maxTokenTx) bucket.maxTokenTx = transactions;
            } else if (tokenKind === "cacheRead") {
              bucket.cacheReadTokens += units;
              bucket.hasCacheReadTokens = true;
              if (transactions > bucket.maxTokenTx) bucket.maxTokenTx = transactions;
            } else if (tokenKind === "completion") {
              bucket.completionTokens += units;
              if (transactions > bucket.maxTokenTx) bucket.maxTokenTx = transactions;
            } else if (tokenKind === "reasoning") {
              bucket.reasoningTokens += units;
              bucket.hasReasoningTokens = true;
              if (transactions > bucket.maxTokenTx) bucket.maxTokenTx = transactions;
            } else {
              bucket.nonTokenTx += transactions;
            }
          }
        }
        const sortedKeys = Array.from(buckets.keys()).sort();
        const builtEntries = [];
        const emittedDays = new Set();
        for (const key of sortedKeys) {
          const bucket = buckets.get(key);
          const outputTokens = bucket.completionTokens + bucket.reasoningTokens;
          const tokenRequests = Math.max(bucket.promptTx, bucket.maxTokenTx);
          const requests = tokenRequests + bucket.nonTokenTx;
          if (
            !Number.isSafeInteger(bucket.inputTokens) ||
            !Number.isSafeInteger(bucket.cacheReadTokens) ||
            !Number.isSafeInteger(outputTokens) ||
            !Number.isSafeInteger(bucket.reasoningTokens) ||
            !Number.isSafeInteger(requests) ||
            !Number.isSafeInteger(bucket.inputTokens + bucket.cacheReadTokens + outputTokens)
          ) {
            throw new Error("invalid xAI usage history");
          }
          if (
            bucket.cost === 0 &&
            bucket.inputTokens === 0 &&
            bucket.cacheReadTokens === 0 &&
            outputTokens === 0 &&
            requests === 0
          ) {
            continue;
          }
          const entry = {
            date: bucket.day,
            inputTokens: bucket.inputTokens,
            outputTokens,
            requests,
            cost: bucket.cost,
          };
          if (bucket.hasCacheReadTokens) entry.cacheReadTokens = bucket.cacheReadTokens;
          if (bucket.hasReasoningTokens) entry.reasoningTokens = bucket.reasoningTokens;
          if (bucket.model) entry.model = bucket.model;
          builtEntries.push(entry);
          emittedDays.add(bucket.day);
          totalSpend30d += bucket.cost;
        }
        for (const day of Array.from(observedDays).sort()) {
          if (!emittedDays.has(day)) {
            builtEntries.push({
              date: day,
              inputTokens: 0,
              outputTokens: 0,
              requests: 0,
              cost: 0,
            });
          }
        }
        builtEntries.sort((a, b) => {
          if (a.date !== b.date) return a.date < b.date ? -1 : 1;
          const modelA = a.model || "";
          const modelB = b.model || "";
          return modelA < modelB ? -1 : modelA > modelB ? 1 : 0;
        });
        if (!Number.isFinite(totalSpend30d)) {
          throw new Error("invalid xAI usage history");
        }
        entries = builtEntries;
        partial = usage.json.limitReached === true;
        historyAvailable = true;
      }
    } catch (error) {
      if (/rejected the Management API key/.test(error.message)) throw error;
    }
    const rows = [
      { label: "Prepaid balance", value: `$${balance.toFixed(2)}` },
      ...(liveRemaining === undefined
        ? []
        : [{ label: "Live remaining (est.)", value: `$${liveRemaining.toFixed(2)}` }]),
      ...(currentCycleSpend === undefined
        ? []
        : [
            {
              label: "Current cycle",
              value: `$${currentCycleSpend.toFixed(2)}`,
              ...(billingCycleLabel ? { secondaryValue: billingCycleLabel } : {}),
            },
          ]),
      ...(spendingLimit === undefined ? [] : [{ label: "Spending limit", value: `$${spendingLimit.toFixed(2)}` }]),
      {
        label: partial ? "Last 30 days (partial)" : "Last 30 days",
        value: `$${totalSpend30d.toFixed(2)}`,
      },
    ];
    return {
      cost: { used: balance, currency: "USD", period: "Prepaid credits" },
      costUsage: historyAvailable
        ? {
            currency: "USD",
            historyDays: 30,
            historyLabel: partial ? "Last 30 days (partial)" : undefined,
            windowEnd: todayUTC,
            includesCurrentDay: true,
            partial,
            entries,
          }
        : undefined,
      identity: { loginMethod: "Management API" },
      dataConfidence: partial ? "estimated" : "exact",
      details: [
        {
          title: "Billing summary",
          rows,
        },
      ],
    };
  },
});
