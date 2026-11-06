// Copyright (c) 2026 caseclose. SPDX-License-Identifier: MIT
// Install this file in CodexBar Settings → Plugins.
defineProvider({
  id: "local-quota",
  name: "Local Quota",
  icon: { monogram: "Q", tint: "#497A78" },
  endpoints: [{ setting: "BASE_URL", policy: "https-or-loopback-http" }],
  settings: [
    { key: "BASE_URL", type: "plain", title: "Local origin", subtitle: "http://127.0.0.1:8765 or another local port" },
    {
      key: "MAX_AGE",
      type: "plain",
      title: "Maximum age (minutes)",
      subtitle: "Default: 15. Set to your export interval plus a margin.",
    },
  ],
  snapshotPolicy: { percent: "preserve-overage" },
  async fetchUsage(ctx) {
    const origin = (ctx.settings.get("BASE_URL") || "").trim().replace(/\/$/, "");
    const match = /^http:\/\/127\.0\.0\.1:([1-9][0-9]{0,4})$/.exec(origin);
    if (!match || Number(match[1]) > 65535) throw new Error("Set a local origin such as http://127.0.0.1:8765.");
    const minutes = (ctx.settings.get("MAX_AGE") || "").trim() || "15";
    if (!/^[1-9][0-9]{0,4}$/.test(minutes) || Number(minutes) > 10080)
      throw new Error("Maximum age must be 1–10080 minutes.");
    const data = (await ctx.http.getJSON(origin + "/v1/quota")).json;
    const allowed = ["version", "used", "limit", "observedAt", "resetsAt", "currency"];
    const nonnegative = (n) => Number.isFinite(n) && n >= 0;
    if (
      !data ||
      typeof data !== "object" ||
      Array.isArray(data) ||
      data.version !== 1 ||
      Object.keys(data).some((k) => !allowed.includes(k)) ||
      !nonnegative(data.used) ||
      !nonnegative(data.limit) ||
      (data.currency != null && (typeof data.currency !== "string" || !/^[A-Z]{3}$/.test(data.currency)))
    ) {
      throw new Error("Invalid quota response. Check the version, fields and amounts.");
    }
    function timestamp(value) {
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value))
        throw new Error("Expected a UTC timestamp.");
      const time = Date.parse(value);
      if (!Number.isFinite(time) || new Date(time).toISOString().slice(0, 19) !== value.slice(0, 19))
        throw new Error("Invalid UTC timestamp.");
      return time;
    }
    const observed = timestamp(data.observedAt);
    const now = Date.now();
    if (observed > now + 60000 || now - observed > Number(minutes) * 60000)
      throw new Error("Quota observation is stale or its clock is ahead.");
    const reset = data.resetsAt == null ? null : timestamp(data.resetsAt);
    if (reset !== null && reset <= now) throw new Error("Quota reset has passed. Refresh the exporter.");
    const amount = (n) => (data.currency ? n.toFixed(2) + " " + data.currency : String(n));
    const result = {
      details: [
        {
          title: "Quota",
          rows: [
            { label: "Remaining", value: amount(data.limit - data.used) },
            { label: "Used", value: amount(data.used) },
            { label: "Limit", value: amount(data.limit) },
            { label: "Observed at (UTC)", value: new Date(observed).toISOString() },
          ],
        },
      ],
    };
    if (data.limit > 0) {
      const usedPercent = (data.used / data.limit) * 100;
      if (!Number.isFinite(usedPercent)) throw new Error("Quota ratio is out of range.");
      result.primary = { title: "Quota", usedPercent };
      if (reset !== null) result.primary.resetsAt = new Date(reset).toISOString();
    }
    if (ctx.env.supportsObservedAt === true) result.observedAt = data.observedAt;
    return result;
  },
});
