defineProvider({
  id: "gladia",
  name: "Gladia",
  endpoints: ["https://api.gladia.io"],
  auth: { type: "header", header: "x-gladia-key", secret: "GLADIA_API_KEY" },
  settings: [{ key: "GLADIA_API_KEY", title: "API key", type: "secure" }],
  async fetchUsage(ctx) {
    // Gladia has no usage or balance API; sum billed seconds of this month's listed jobs instead.
    // List items carry only result.metadata, not transcripts. Pages are capped to bound each refresh.
    const pageSize = 200;
    const maxPages = 5;

    const invalid = (field) => {
      throw ctx.fail.parseFailure(
        `Gladia returned invalid transcription data: ${field}. Refresh to try again. If this persists, update CodexBar or report the issue.`,
      );
    };
    const isObject = (value) => !!value && typeof value === "object" && !Array.isArray(value);

    const getPage = async (url) => {
      const response = await ctx.http.get(url);
      if (response.status === 401) {
        throw ctx.fail.authenticationExpired(
          "Gladia rejected the API key. Check that it is valid and has not been revoked.",
        );
      }
      if (response.status === 403) {
        throw ctx.fail.permissionDenied("Gladia denied access to the transcription list for this API key.");
      }
      if (response.status === 429) {
        throw ctx.fail.rateLimited("Gladia rate limit reached (HTTP 429). Wait a moment, then refresh.");
      }
      if (response.status >= 500) {
        throw ctx.fail.providerUnavailable(
          `Gladia is temporarily unavailable (HTTP ${response.status}). Try again later or check https://status.gladia.io.`,
        );
      }
      if (response.status !== 200) {
        throw ctx.fail.apiFailure(
          `Gladia request failed (HTTP ${response.status}). Refresh to try again. If this persists, update CodexBar or report the issue.`,
        );
      }
      let data;
      try {
        data = JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return invalid("invalid JSON");
      }
      if (!isObject(data)) return invalid("expected an object");
      return data;
    };

    const now = ctx.date.now();
    const monthStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const after = encodeURIComponent(monthStart.toISOString());

    const total = async (kind) => {
      const sum = { seconds: 0, jobs: 0, truncated: false };
      let offset = 0;
      for (let page = 0; page < maxPages; page += 1) {
        const data = await getPage(
          `https://api.gladia.io/v2/${kind}?after_date=${after}&offset=${offset}&limit=${pageSize}`,
        );
        if (!Array.isArray(data.items)) return invalid(`${kind} items`);
        if (data.next !== undefined && data.next !== null && typeof data.next !== "string") {
          return invalid(`${kind} next`);
        }
        for (const item of data.items) {
          if (!isObject(item) || typeof item.status !== "string") return invalid(`${kind} item status`);
          if (item.status !== "done") continue;
          const result = item.result;
          const metadata = isObject(result) ? result.metadata : undefined;
          const billed = isObject(metadata) ? metadata.billing_time : undefined;
          if (typeof billed !== "number" || !Number.isFinite(billed) || billed < 0) {
            return invalid(`${kind} billing_time`);
          }
          sum.seconds += billed;
          sum.jobs += 1;
        }
        offset += data.items.length;
        // `next` is authoritative; servers may return short pages. Without it, a short page ends the list.
        const hasNext = typeof data.next === "string" ? true : data.next === undefined && data.items.length >= pageSize;
        if (!hasNext || data.items.length === 0) return sum;
      }
      sum.truncated = true;
      return sum;
    };

    const preRecorded = await total("pre-recorded");
    const live = await total("live");
    const truncated = preRecorded.truncated || live.truncated;
    const prefix = truncated ? "≥ " : "";
    const duration = (seconds) => {
      if (seconds < 3600) return `${ctx.format.number(seconds / 60, { maximumFractionDigits: 0 })} min`;
      return `${ctx.format.number(seconds / 3600, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} h`;
    };

    return {
      details: [
        {
          title: "This month",
          rows: [
            { label: "Billed audio", value: prefix + duration(preRecorded.seconds + live.seconds) },
            { label: "Pre-recorded", value: (preRecorded.truncated ? "≥ " : "") + duration(preRecorded.seconds) },
            { label: "Live", value: (live.truncated ? "≥ " : "") + duration(live.seconds) },
            {
              label: "Transcriptions",
              value: prefix + ctx.format.number(preRecorded.jobs + live.jobs, { maximumFractionDigits: 0 }),
            },
          ],
        },
      ],
    };
  },
});
