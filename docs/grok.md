# Grok (xAI) Provider

CodexBar supports the official Grok Build CLI (`grok`) through seamless authentication sharing and real usage tracking.

## Requirements

- The official Grok CLI must be installed (`~/.grok/bin/grok` or in your PATH).
- You must be logged in via the Grok CLI (`grok login` or the normal browser flow).
- Your credentials are stored in `~/.grok/auth.json`.

## Authentication

CodexBar reads the same `~/.grok/auth.json` file used by the official Grok CLI and the VS Code xai-grok-plugin.

It extracts:
- Your email address
- Your plan tier (e.g., "Super Heavy" for tier 5)
- The access token for API calls

No separate login is required.

## Supported Features

- **Identity**: Shows your email and plan name ("Super Heavy", "Heavy", "Pro", etc.).
- **Usage Tracking**: Fetches real-time credits usage from the production Grok billing service using the gRPC endpoint `grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`.
- **Reset Date**: Displays when your credits reset (e.g., "Resets May 31" or relative time like "Resets in 15d").
- **CLI Version**: Detects and displays the version of your local `grok` binary.

## How to Enable

1. Install and log in to the official Grok CLI.
2. In CodexBar → Settings → Providers, enable **Grok**.
3. The provider will appear with your account details and usage meter.

## Debug

In **Settings → Debug**, you can:
- View "Fetch strategy attempts" for Grok.
- Use **Probe logs → Grok → Fetch log** to see the latest debug output, including the raw protobuf response from the billing endpoint.

## Limitations

- Grok is not yet supported in widgets.
- Pay-as-you-go status is not currently displayed (planned for future).
- The protobuf decoder is manually maintained based on reverse engineering of the official binary and web responses.

## Related Projects

The same `~/.grok/auth.json` is shared with:
- The official Grok CLI / TUI
- The xai-grok-plugin (VS Code extension)

This allows a single login to power usage monitoring across multiple tools.

## Credits

Special thanks to the reverse engineering work that identified the real billing endpoint and protobuf structures used by the Grok web UI and CLI.