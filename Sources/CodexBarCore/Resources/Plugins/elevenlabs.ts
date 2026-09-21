defineProvider({
  id: "elevenlabs",
  name: "ElevenLabs",
  endpoints: [{ setting: "BASE_URL", policy: "https" }],
  auth: { type: "header", header: "xi-api-key", secret: "ELEVENLABS_API_KEY" },
  settings: [
    { key: "ELEVENLABS_API_KEY", title: "API key", type: "secure" },
    { key: "BASE_URL", title: "API URL", type: "plain" },
  ],

  async fetchUsage(ctx) {
    const response = await ctx.http.get(
      ctx.settings.get("BASE_URL") || "https://api.elevenlabs.io/v1/user/subscription",
    );
    if (response.status === 401 || response.status === 403) {
      let detail;
      try {
        const root = JSON.parse(response.bodyText);
        detail = root && root.detail;
      } catch (error) {
        void error;
      }
      // JSONDecoder rejected either mistyped optional field before consulting the other.
      if (detail && [detail.code, detail.status].every((value) => value == null || typeof value === "string")) {
        for (const value of [detail.code, detail.status]) {
          const code = value && value.trim().toLowerCase();
          if (code === "invalid_api_key") {
            throw ctx.fail.authenticationExpired(
              "ElevenLabs rejected the selected API key. Check that it is valid and has not been revoked.",
            );
          }
          if (code === "missing_permissions" || code === "insufficient_permissions") {
            throw ctx.fail.permissionDenied(
              "ElevenLabs API key is missing the user_read permission required to fetch subscription usage.",
            );
          }
        }
      }
      if (response.status === 401) {
        throw ctx.fail.authenticationExpired(
          "ElevenLabs could not authenticate the selected API key. Check the key and its permissions.",
        );
      }
      throw ctx.fail.permissionDenied(
        "ElevenLabs denied access for the selected API key. Check its endpoint permissions and IP allowlist.",
      );
    }
    if (response.status !== 200) {
      const message = `ElevenLabs API error: HTTP ${response.status}`;
      if (response.status === 429) throw ctx.fail.rateLimited(message);
      if (response.status >= 500) throw ctx.fail.providerUnavailable(message);
      throw ctx.fail.apiFailure(message);
    }
    let data;
    const invalid = () => ctx.fail.parseFailure("Failed to parse ElevenLabs response: invalid subscription response");
    try {
      data = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      throw invalid();
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) throw invalid();
    const integer = (value: number) => Number.isInteger(value) && value >= -(2 ** 63) && value < 2 ** 63;
    for (const key of ["character_count", "character_limit"]) {
      if (!integer(data[key])) throw invalid();
    }
    for (const key of [
      "voice_slots_used",
      "voice_limit",
      "professional_voice_slots_used",
      "professional_voice_limit",
      "next_character_count_reset_unix",
    ]) {
      if (data[key] != null && !integer(data[key])) throw invalid();
    }
    for (const value of [data.tier, data.status]) {
      if (value != null && typeof value !== "string") throw invalid();
    }
    if (data.current_overage != null) {
      const overage = data.current_overage;
      if (
        typeof overage !== "object" ||
        Array.isArray(overage) ||
        [overage.amount, overage.currency].some((value) => value != null && typeof value !== "string")
      )
        throw invalid();
    }
    const extraWindows: CodexBarNamedRateWindow[] = [];
    for (const [id, title, used, limit] of [
      ["voice-slots", "Voice slots", data.voice_slots_used, data.voice_limit],
      ["professional-voices", "Professional voices", data.professional_voice_slots_used, data.professional_voice_limit],
    ] as [string, string, number | null, number | null][]) {
      if (used != null && limit != null && limit > 0) {
        extraWindows.push({
          id,
          title,
          window: { usedPercent: ctx.pct(used, limit), resetDescription: `${used} / ${limit}` },
        });
      }
    }
    const tier = data.tier && data.tier.trim();
    const suffix = data.status && data.status.toLowerCase() !== "active" ? ` · ${data.status}` : "";
    const loginMethod = tier
      ? tier
          .replace(/_/g, " ")
          .toLowerCase()
          .replace(/\b\w/g, (letter: string) => letter.toUpperCase()) + suffix
      : data.status;
    return {
      primary: {
        usedPercent: data.character_limit > 0 ? ctx.pct(data.character_count, data.character_limit) : 0,
        resetsAt:
          data.next_character_count_reset_unix == null
            ? null
            : ctx.date.unixSeconds(data.next_character_count_reset_unix),
        resetDescription: `${ctx.format.number(data.character_count, { maximumFractionDigits: 0 })} / ${ctx.format.number(data.character_limit, { maximumFractionDigits: 0 })} credits`,
      },
      extraWindows: extraWindows.length ? extraWindows : null,
      identity: { loginMethod },
    };
  },
});
