# Higgsfield local plugin

This experimental user plugin is intended to read the available credit balance from Higgsfield's consumer MCP
endpoint. It does not use the separate prepaid wallet exposed by Higgsfield's generation API.

## Availability and authentication

Higgsfield documents its MCP service as an OAuth integration that can check a credit balance. The endpoint used here is
`https://mcp.higgsfield.ai/mcp`. CodexBar local plugins can store a bearer token in a secure setting, but cannot run
Higgsfield's OAuth flow. Enter only a token issued for this MCP server. Compatibility of `higgsfield auth token` with
this endpoint has not been verified; the CLI documents its token as short-lived, so do not assume the token is accepted.

At refresh time the plugin initializes an MCP Streamable HTTP session, reads the advertised tools, and invokes only a
read-only candidate named `balance` or `higgsfield_balance`. It fails closed if neither tool is advertised, if the tool
requires input, or if its metadata marks it non-read-only. The `higgsfield_balance` name is also used by a connected
Codex tool and may be a wrapper name; runtime discovery checks what the endpoint itself advertises.
It inspects only the first `tools/list` page; if Higgsfield paginates the balance tool onto a later page, the plugin
reports the tool as unsupported rather than following an unverified pagination contract.

CodexBar's installed-plugin host permits the canonical `Accept: application/json, text/event-stream` header on POST
requests so this MCP endpoint can negotiate JSON or server-sent events. The host normalizes only that canonical value;
its declared-origin and GET/POST restrictions, auth-header protection, `Accept-Encoding: identity` requirement, and
response checks remain in effect.

The balance shape was observed through a successfully queried connected authenticated Higgsfield tool, which may be a
wrapper and is not proof that the local plugin works against the raw endpoint. The raw endpoint's authenticated
`tools/list` and `tools/call` response have not been verified in this environment. Automated tests use simulated MCP
responses and a fixture token; they do not establish that a manually supplied token is accepted by the raw endpoint or
provide live authenticated local-plugin proof.

## Data shown

- Available credits and plan when returned by the balance tool.
- Credit limit and subscription renewal are shown as “Not reported by the balance tool.” The observed balance does not
  contain either field; the plugin does not infer them from a plan, trial, or free-generation count.

## Install

Copy `Examples/Plugins/higgsfield.js` into `~/.config/codexbar/providers/`, or add it through **Settings → Plugins**.
Set the MCP access token in the plugin's secure setting. Do not put a token in the plugin file or a support transcript.

## References

- [Higgsfield MCP integration](https://higgsfield.ai/creator-hub/help-center/integrations/what-is-higgsfield-mcp)
- [Higgsfield CLI](https://higgsfield.ai/blog/higgsfield-cli)
- [Higgsfield credit usage and renewal](https://higgsfield.ai/creator-hub/help-center/credits/what-uses-my-credits)
- [Higgsfield plan cycles](https://higgsfield.ai/creator-hub/help-center/plans/how-do-higgsfield-plans-work)
- [Higgsfield API terms](https://open.higgsfield.ai/terms-of-service)
- [CodexBar plugin documentation](https://github.com/steipete/CodexBar/blob/main/docs/plugins.md)
- [MCP Streamable HTTP transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
