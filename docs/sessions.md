# Agent Sessions

CodexBar can list live Codex, Claude Code, and OhMyPi sessions on this Mac and other Macs or Linux hosts reachable over SSH.

Enable **Settings → Menu → Agent sessions**. Local sessions refresh every 30 seconds. Remote sessions refresh every 60 seconds and whenever the menu opens. Tailscale discovery includes online macOS and Linux peers; add extra SSH destinations as a comma-separated list, such as `user@host`.

The setting is off by default. While it is off, CodexBar clears the published local and remote session rows and does not fetch remote sessions. Adaptive agent-aware refresh may still collect a local activity timestamp after explicit consent, but it does not retain or publish session identities or paths. Enabling Agent Sessions allows the normal local process scan and remote discovery; the label-style and manual-host controls are in the same settings section.

Local discovery is process-backed. OhMyPi is recognized from a running `omp` process or a Bun launcher whose command line includes an `omp` executable argument; helper commands are excluded. For each live process, CodexBar performs a bounded, best-effort lookup of only the six root/profile environment keys (`HOME`, `PI_CONFIG_DIR`, `PI_CODING_AGENT_DIR`, `XDG_DATA_HOME`, `OMP_PROFILE`, and `PI_PROFILE`) and resolves that process's exact active profile independently. Relative custom-agent paths use that process's cwd. If a process environment is unavailable, its entry is missing or empty, or `HOME` is unusable, ambient named profiles and ambient custom/config/XDG roots are discarded and no transcript metadata is matched; with a valid `HOME` but missing other keys, only a safe default-profile root derived from that process `HOME` is considered. A process-only `pid:<pid>` row remains when no safe root can be proven. Roots are never reused between processes, and stale records are never presented as OhMyPi sessions. Each OhMyPi traversal uses an independent bounded directory-metadata budget, so it cannot consume the budget reserved for Codex and Claude discovery. The normalized provider value in JSON is `oh-my-pi`. The OhMyPi schema, profile layout, and launcher heuristics are implementation details and version-sensitive. Remote hosts run the same scanner, so the same Codex, Claude Code, and OhMyPi discovery rules apply there.

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
codexbar sessions --json-v2
codexbar sessions focus <session-id>
```

`codexbar sessions --json` emits the legacy v1 normalized session JSON: a top-level
JSON array with the existing fields and only the `codex` and `claude` provider values. This
closed provider set keeps the payload decodable by older CodexBar clients after a host-first
upgrade.
`codexbar sessions --json-v2` emits the complete current normalized JSON, including
`oh-my-pi` rows and ISO-8601 dates. It preserves the same top-level array shape without an
envelope. The human-readable table is unchanged and continues to show every provider.

Remote fetches negotiate mixed-version compatibility over non-interactive SSH. For each host,
the fetcher tries `codexbar sessions --json-v2`, then `codexbar sessions --json`; only if both
PATH attempts fail does it try the bundled app CLI with `sessions --json-v2`, then `sessions --json`.
Current hosts return the complete provider array through v2. Older hosts reject v2 and return the
legacy Codex/Claude-only v1 projection through `--json`, which the current client can decode. The
legacy spelling remains intentionally limited so an older client can query a newly upgraded host
without rejecting an unknown `oh-my-pi` provider value.

Remote hosts need key-based, non-interactive SSH and either `codexbar` on `PATH` or CodexBar installed in `/Applications`.
