defineProvider({
  id: "deepgram",
  name: "Deepgram",
  endpoints: ["https://api.deepgram.com", { setting: "DEEPGRAM_API_URL", policy: "https" }],
  auth: { type: "authorization-scheme", scheme: "Token", secret: "DEEPGRAM_API_KEY" },
  settings: [
    { key: "DEEPGRAM_API_KEY", title: "API key", type: "secure" },
    { key: "DEEPGRAM_PROJECT_ID", title: "Project ID", type: "plain" },
    { key: "DEEPGRAM_API_URL", title: "API URL", type: "plain" },
  ],
  async fetchUsage(ctx) {
    const base = (ctx.settings.get("DEEPGRAM_API_URL") || "https://api.deepgram.com/v1").replace(/\/+$/, "");

    function classifyStatus(status) {
      if (status === 401) return ctx.fail.authenticationExpired("Deepgram API key is invalid or expired.");
      if (status === 403) {
        return ctx.fail.permissionDenied(
          "Deepgram rejected access: The API key may not have access to the project or the Management API. HTTP 403");
      }
      if (status === 429) return ctx.fail.rateLimited("Deepgram API error: HTTP 429");
      if (status >= 500) return ctx.fail.providerUnavailable(`Deepgram API error: HTTP ${status}`);
      return ctx.fail.apiFailure(`Deepgram API error: HTTP ${status}`);
    }

    async function getJSON(url) {
      let response;
      try {
        response = await ctx.http.get(url);
      } catch (error) {
        throw ctx.fail.networkFailure(`Deepgram network error: ${error && error.message || error}`);
      }
      if (response.status !== 200) throw classifyStatus(response.status);
      try {
        return JSON.parse(response.bodyText);
      } catch (_) {
        throw ctx.fail.parseFailure("Deepgram parse error: response was not valid JSON");
      }
    }

    function optionalNumber(value, field, integer) {
      if (value === null || value === undefined) return 0;
      if (typeof value !== "number" || !Number.isFinite(value) || (integer && !Number.isInteger(value))) {
        throw ctx.fail.parseFailure(`Deepgram parse error: ${field} has an invalid number`);
      }
      return value;
    }

    function optionalString(value, field) {
      if (value === null || value === undefined) return null;
      if (typeof value !== "string") {
        throw ctx.fail.parseFailure(`Deepgram parse error: ${field} must be a string`);
      }
      return value;
    }

    function usagePayload(payload) {
      if (!payload || typeof payload !== "object" || Array.isArray(payload) || !Array.isArray(payload.results)) {
        throw ctx.fail.parseFailure("Deepgram parse error: usage results must be an array");
      }
      const result = {
        start: optionalString(payload.start, "start"),
        end: optionalString(payload.end, "end"),
        hours: 0,
        totalHours: 0,
        agentHours: 0,
        tokensIn: 0,
        tokensOut: 0,
        tts: 0,
        requests: 0,
      };
      if (payload.resolution !== null && payload.resolution !== undefined) {
        if (!payload.resolution || typeof payload.resolution !== "object" || Array.isArray(payload.resolution)) {
          throw ctx.fail.parseFailure("Deepgram parse error: resolution must be an object");
        }
        optionalString(payload.resolution.units, "resolution.units");
        optionalNumber(payload.resolution.amount, "resolution.amount", true);
      }
      for (const row of payload.results) {
        if (!row || typeof row !== "object" || Array.isArray(row)) {
          throw ctx.fail.parseFailure("Deepgram parse error: usage result must be an object");
        }
        result.hours += optionalNumber(row.hours, "hours", false);
        result.totalHours += optionalNumber(row.total_hours, "total_hours", false);
        result.agentHours += optionalNumber(row.agent_hours, "agent_hours", false);
        result.tokensIn += optionalNumber(row.tokens_in, "tokens_in", true);
        result.tokensOut += optionalNumber(row.tokens_out, "tokens_out", true);
        result.tts += optionalNumber(row.tts_characters, "tts_characters", true);
        result.requests += optionalNumber(row.requests, "requests", true);
      }
      return result;
    }

    const configuredProject = ctx.settings.get("DEEPGRAM_PROJECT_ID");
    let projects;
    if (configuredProject) {
      projects = [{ project_id: configuredProject, name: null }];
    } else {
      const payload = await getJSON(`${base}/projects`);
      if (!payload || typeof payload !== "object" || !Array.isArray(payload.projects)) {
        throw ctx.fail.parseFailure("Deepgram parse error: projects must be an array");
      }
      projects = payload.projects.map((project, index) => {
        if (!project || typeof project !== "object" || typeof project.project_id !== "string") {
          throw ctx.fail.parseFailure(`Deepgram parse error: projects[${index}].project_id must be a string`);
        }
        const name = optionalString(project.name, `projects[${index}].name`);
        return { project_id: project.project_id, name };
      });
    }
    if (!projects.length) {
      throw ctx.fail.apiFailure("Deepgram project ID is invalid or no projects were returned for this API key.");
    }

    const totals = { hours: 0, totalHours: 0, agentHours: 0, tokensIn: 0, tokensOut: 0, tts: 0, requests: 0 };
    let start = null;
    let end = null;
    for (const project of projects) {
      const payload = usagePayload(await getJSON(
        `${base}/projects/${encodeURIComponent(project.project_id)}/usage/breakdown`));
      if (payload.start && (!start || payload.start < start)) start = payload.start;
      if (payload.end && (!end || payload.end > end)) end = payload.end;
      for (const field of Object.keys(totals)) totals[field] += payload[field];
    }

    const decimal = value => ctx.format.number(value, {
      minimumFractionDigits: value === Math.floor(value) ? 0 : 1,
      maximumFractionDigits: 1,
    });
    const integer = value => ctx.format.number(value, { maximumFractionDigits: 0 });
    const rows = [{ label: "Requests", value: integer(totals.requests) }];
    if (totals.hours || totals.totalHours) rows.push({
      label: "Audio",
      value: `${decimal(totals.hours)} hours`,
      secondaryValue: `${decimal(totals.totalHours)} billable hours`,
    });
    if (totals.agentHours) rows.push({ label: "Agent hours", value: decimal(totals.agentHours) });
    if (totals.tokensIn || totals.tokensOut) rows.push({
      label: "Tokens",
      value: integer(totals.tokensIn + totals.tokensOut),
    });
    if (totals.tts) rows.push({ label: "TTS characters", value: integer(totals.tts) });
    if (start && end) rows.push({ label: "Period", value: `${start} to ${end}` });
    const loginMethod = projects.length > 1
      ? `${projects.length} projects`
      : `Project: ${projects[0].name || projects[0].project_id}`;
    return { identity: { loginMethod }, details: [{ title: "Usage summary", rows }] };
  },
});
