# Agent Sessions

CodexBar can list live Codex, Claude Code, and OhMyPi sessions on this Mac and other Macs or Linux hosts reachable over SSH.

Enable **Settings → Menu → Agent sessions**. Local sessions refresh every 30 seconds. Remote sessions refresh every 60 seconds and whenever the menu opens. Tailscale discovery includes online macOS and Linux peers; add extra SSH destinations as a comma-separated list, such as `user@host`.

The setting is off by default. While it is off, CodexBar clears the published local and remote session rows and does not fetch remote sessions. Adaptive agent-aware refresh may still collect a local activity timestamp after explicit consent, but it does not retain or publish session identities or paths. Enabling Agent Sessions allows the normal local process scan and remote discovery; the label-style and manual-host controls are in the same settings section.

Local discovery is process-backed. OhMyPi is recognized from a running `omp` process or a Bun launcher whose command line includes an `omp` executable argument; helper commands are excluded. Its session root is resolved for the effective active profile only, and session files supply only bounded header/title metadata for a matched process. An unmatched live process can still appear with a `pid:<pid>` fallback, but an OhMyPi file or terminal breadcrumb by itself does not create a live menu row. The normalized provider value in JSON is `oh-my-pi`. The OhMyPi schema, profile layout, and launcher heuristics are implementation details and version-sensitive. Remote hosts run the same scanner, so the same Codex, Claude Code, and OhMyPi discovery rules apply there.

Choose the row label format in the same settings section:

- **Project** keeps the working-directory name used by earlier releases.
- **Descriptive** uses the Codex thread title, OhMyPi session title when available, or named subagent task, with the project as a fallback.
- **Descriptive + project** shows both when they differ.

Thread and session titles can contain sensitive text. **Project** remains the default; choose a descriptive mode only if you are comfortable showing those titles in the menu. CodexBar reads only bounded title metadata without modifying provider state and does not persist it separately. Claude Code sessions currently fall back to the project name when equivalent session-title metadata is unavailable.

The menu groups local sessions first, followed by each remote host. A filled dot is active; an empty dot is idle. Select a local row to activate its terminal, editor, or desktop app. The first focus attempt can request macOS Accessibility permission so CodexBar can raise the matching window. Remote rows run the same focus command over SSH.

The CLI exposes the same scanner:

```console
codexbar sessions
codexbar sessions --json
codexbar sessions focus <session-id>
```

The JSON array uses the stable `AgentSession` fields and ISO-8601 dates. Its normalized provider values include `codex`, `claude`, and `oh-my-pi` for OhMyPi. The CLI commands and existing focus mapping are unchanged.

Remote hosts need key-based, non-interactive SSH and either `codexbar` on `PATH` or CodexBar installed in `/Applications`.
