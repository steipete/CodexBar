defineProvider({
  id: "higgsfield-credits",
  name: "Higgsfield Credits",
  icon: { monogram: "HF", tint: "#8B5CF6" },
  endpoints: ["https://mcp.higgsfield.ai"],
  auth: { type: "bearer", secret: "MCP_ACCESS_TOKEN" },
  capabilities: ["http-status"],
  settings: [
    {
      key: "MCP_ACCESS_TOKEN",
      title: "Higgsfield MCP access token",
      subtitle: "Use a bearer token for mcp.higgsfield.ai. CodexBar does not complete Higgsfield OAuth.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    const endpoint = "https://mcp.higgsfield.ai/mcp";
    const protocolVersion = "2025-11-25";
    const supportRecovery = "If it persists, contact Higgsfield or CodexBar support. Do not send secrets.";
    const unsupportedRecovery = `Update the Higgsfield plugin, then refresh. ${supportRecovery}`;
    const temporaryRecovery = `Wait a few minutes, then refresh. ${supportRecovery}`;
    const invalidResponse = () => ctx.fail.parseFailure(
      `Higgsfield MCP returned an unsupported balance response. ${unsupportedRecovery}`);

    const failForStatus = (status) => {
      if (status === 401) {
        throw ctx.fail.authenticationExpired("Higgsfield MCP rejected the access token. Reconnect with an authorized token.");
      }
      if (status === 403) throw ctx.fail.permissionDenied("Higgsfield MCP denied access to the balance tool.");
      if (status === 429) {
        throw ctx.fail.rateLimited(`Higgsfield MCP rate limited the balance request. ${temporaryRecovery}`);
      }
      if (status >= 500) {
        throw ctx.fail.providerUnavailable(
          `Higgsfield MCP is temporarily unavailable (HTTP ${status}). ${temporaryRecovery}`);
      }
      if (status < 200 || status >= 300) throw ctx.fail.apiFailure(`Higgsfield MCP returned HTTP ${status}.`);
    };

    const header = (headers, name) => {
      if (!headers || typeof headers !== "object") return null;
      const key = Object.keys(headers).find((item) => item.toLowerCase() === name.toLowerCase());
      return key ? headers[key] : null;
    };

    const parseMessages = (response) => {
      const body = response.bodyText.trim();
      if (!body) return [];
      const contentType = header(response.headers, "content-type") || "";
      if (!/text\/event-stream/i.test(contentType) && !/^(event|data):/m.test(body)) {
        try {
          return [JSON.parse(body)];
        } catch (error) {
          void error;
          throw invalidResponse();
        }
      }

      const messages = [];
      for (const frame of body.split(/\r?\n\r?\n/)) {
        const data = frame
          .split(/\r?\n/)
          .filter((line) => line.startsWith("data:"))
          .map((line) => line.slice(5).replace(/^ /, ""))
          .join("\n");
        if (!data || data === "[DONE]") continue;
        try {
          messages.push(JSON.parse(data));
        } catch (error) {
          void error;
          throw invalidResponse();
        }
      }
      return messages;
    };

    let sessionID = null;
    let negotiatedProtocolVersion = null;
    const post = async (message, expectedID) => {
      const headers = { Accept: "application/json, text/event-stream" };
      if (sessionID) headers["MCP-Session-Id"] = sessionID;
      if (negotiatedProtocolVersion) headers["MCP-Protocol-Version"] = negotiatedProtocolVersion;
      const response = await ctx.http.post(endpoint, { body: message, headers });
      failForStatus(response.status);
      const responseSessionID = header(response.headers, "mcp-session-id");
      if (responseSessionID) sessionID = responseSessionID;
      if (response.status === 202 && expectedID == null) return null;
      const messages = parseMessages(response);
      const envelope = messages.find((item) => item && item.id === expectedID);
      if (!envelope || envelope.jsonrpc !== "2.0") throw invalidResponse();
      if (envelope.error) {
        throw ctx.fail.apiFailure(`Higgsfield MCP could not complete the balance request. ${temporaryRecovery}`);
      }
      if (!envelope.result || typeof envelope.result !== "object" || Array.isArray(envelope.result)) {
        throw invalidResponse();
      }
      return envelope.result;
    };

    const initialized = await post(
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion,
          capabilities: {},
          clientInfo: { name: "codexbar-higgsfield-plugin", version: "1.0.0" },
        },
      },
      1,
    );
    if (![protocolVersion, "2025-06-18"].includes(initialized.protocolVersion)) {
      throw ctx.fail.providerUnavailable(
        `Higgsfield MCP negotiated an unsupported protocol version. ${unsupportedRecovery}`);
    }
    negotiatedProtocolVersion = initialized.protocolVersion;

    const notification = await ctx.http.post(
      endpoint,
      {
        body: { jsonrpc: "2.0", method: "notifications/initialized" },
        headers: {
          Accept: "application/json, text/event-stream",
          ...(sessionID ? { "MCP-Session-Id": sessionID } : {}),
          "MCP-Protocol-Version": negotiatedProtocolVersion,
        },
      },
    );
    failForStatus(notification.status);

    // shortcut: inspect the first tools/list page only, add cursor paging if balance appears later.
    const listed = await post({ jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }, 2);
    if (!Array.isArray(listed.tools)) throw invalidResponse();
    const balanceTool = listed.tools.find((tool) => tool && tool.name === "balance") ||
      listed.tools.find((tool) => tool && tool.name === "higgsfield_balance");
    if (!balanceTool) {
      throw ctx.fail.permissionDenied(`Higgsfield MCP did not advertise a supported balance tool. ${unsupportedRecovery}`);
    }
    if (balanceTool.annotations && balanceTool.annotations.readOnlyHint === false) {
      throw ctx.fail.permissionDenied("Higgsfield MCP marked its balance tool as non-read-only.");
    }
    if (balanceTool.inputSchema && Array.isArray(balanceTool.inputSchema.required) &&
        balanceTool.inputSchema.required.length > 0) {
      throw ctx.fail.permissionDenied(`Higgsfield MCP balance tool requires unsupported input fields. ${unsupportedRecovery}`);
    }

    const call = await post(
      {
        jsonrpc: "2.0",
        id: 3,
        method: "tools/call",
        params: { name: balanceTool.name, arguments: {} },
      },
      3,
    );
    if (call.isError === true) {
      throw ctx.fail.apiFailure(`Higgsfield MCP reported a balance tool error. ${temporaryRecovery}`);
    }

    let data = call.structuredContent;
    const hasCredits = (value) => value && typeof value === "object" && !Array.isArray(value) &&
      typeof value.credits === "number" && Number.isFinite(value.credits) && value.credits >= 0;
    if (!hasCredits(data) && Array.isArray(call.content)) {
      for (const part of call.content) {
        if (!part || part.type !== "text" || typeof part.text !== "string") continue;
        try {
          const candidate = JSON.parse(part.text);
          if (hasCredits(candidate)) {
            data = candidate;
            break;
          }
        } catch (error) {
          void error;
        }
      }
    }
    if (data && typeof data === "object" && !Array.isArray(data) &&
        (typeof data.error === "string" ? data.error.trim().length > 0 : data.error != null)) {
      throw ctx.fail.apiFailure(`Higgsfield MCP could not retrieve billing details. ${temporaryRecovery}`);
    }
    if (!hasCredits(data)) throw invalidResponse();

    const rows = [
      { label: "Available credits", value: String(data.credits) },
      { label: "Credit limit", value: "Not reported by the balance tool" },
      { label: "Subscription renewal", value: "Not reported by the balance tool" },
    ];
    if (typeof data.subscription_plan_type === "string" && data.subscription_plan_type.length > 0 &&
        data.subscription_plan_type.length <= 120) {
      rows.push({ label: "Plan", value: data.subscription_plan_type });
    }

    return { details: [{ title: "Higgsfield", rows }] };
  },
});
