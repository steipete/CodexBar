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
    const base = (ctx.settings.get("DEEPGRAM_API_URL") || "https://api.deepgram.com/v1").replace(/\/$/, "");
    const configuredProject = ctx.settings.get("DEEPGRAM_PROJECT_ID");
    let projects;
    if (configuredProject) {
      projects = [{ project_id: configuredProject }];
    } else {
      const response = await ctx.http.getJSON(`${base}/projects`);
      if (response.status !== 200 || !response.json || !Array.isArray(response.json.projects)) {
        throw new Error(`Deepgram projects API error: HTTP ${response.status}`);
      }
      projects = response.json.projects;
    }
    if (!projects.length) throw new Error("Deepgram returned no projects");

    const totals = { hours: 0, totalHours: 0, agentHours: 0, tokensIn: 0, tokensOut: 0, tts: 0, requests: 0 };
    let start = null;
    let end = null;
    for (const project of projects) {
      const response = await ctx.http.getJSON(
        `${base}/projects/${encodeURIComponent(project.project_id)}/usage/breakdown`);
      if (response.status !== 200 || !response.json || !Array.isArray(response.json.results)) {
        throw new Error(`Deepgram usage API error: HTTP ${response.status}`);
      }
      start = !start || (response.json.start && response.json.start < start) ? response.json.start : start;
      end = !end || (response.json.end && response.json.end > end) ? response.json.end : end;
      for (const row of response.json.results) {
        totals.hours += Number(row.hours || 0);
        totals.totalHours += Number(row.total_hours || 0);
        totals.agentHours += Number(row.agent_hours || 0);
        totals.tokensIn += Number(row.tokens_in || 0);
        totals.tokensOut += Number(row.tokens_out || 0);
        totals.tts += Number(row.tts_characters || 0);
        totals.requests += Number(row.requests || 0);
      }
    }
    const number = value => new Intl.NumberFormat("en-US", { maximumFractionDigits: 1 }).format(value);
    const rows = [{ label: "Requests", value: new Intl.NumberFormat("en-US").format(totals.requests) }];
    if (totals.hours || totals.totalHours) rows.push({
      label: "Audio",
      value: `${number(totals.hours)} hours`,
      secondaryValue: `${number(totals.totalHours)} billable hours`,
    });
    if (totals.agentHours) rows.push({ label: "Agent hours", value: number(totals.agentHours) });
    if (totals.tokensIn || totals.tokensOut) rows.push({
      label: "Tokens",
      value: new Intl.NumberFormat("en-US").format(totals.tokensIn + totals.tokensOut),
    });
    if (totals.tts) rows.push({ label: "TTS characters", value: new Intl.NumberFormat("en-US").format(totals.tts) });
    if (start && end) rows.push({ label: "Period", value: `${start} to ${end}` });
    const loginMethod = projects.length > 1
      ? `${projects.length} projects`
      : `Project: ${projects[0].name || projects[0].project_id}`;
    return { identity: { loginMethod }, details: [{ title: "Usage summary", rows }] };
  },
});
