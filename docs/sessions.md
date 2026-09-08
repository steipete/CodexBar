# Agent Sessions

CodexBar can list live Codex, Claude Code, pi, and OMP sessions on this Mac and on macOS or Linux hosts reachable over SSH.

Enable **Settings → Menu → Agent sessions**. Local sessions refresh every 30 seconds. Remote sessions refresh every 60 seconds and whenever the menu opens. Tailscale discovery includes online macOS and Linux peers; add extra SSH destinations as a comma-separated list, such as `user@host`.

The setting is off by default. While it is off, CodexBar clears published local and remote session rows and does not fetch remote sessions. Adaptive agent-aware refresh may still collect a local activity timestamp after explicit consent, but it does not retain or publish session identities or paths.

Pi-family discovery is process-backed. Plain pi is recognized by its `pi` process title (upstream also sets `PI_CODING_AGENT=true`); OMP is recognized from an `omp` process or a Bun launcher whose command line contains an `omp` executable. Both feed one scanner and use normalized provider `pi`, with a `dialect` value of `pi` or `omp` on each row.

The scanner understands both storage dialects:

- pi: `~/.pi/agent/sessions/--<escaped-cwd>--/*.jsonl`, beginning with a version-3 `session` header. A later `session_info` entry supplies the optional display name. pi does not materialize a new JSONL until the first assistant message, so a new live process initially appears as `pid:<pid>`.
- OMP: default, named-profile, and XDG session roots, including hashed `home|tmp|abs-<basename>-<sha256>` project buckets and legacy bucket names. OMP files use the title-slot/session-header formats supported by the upstream v1/v2 transition.

Explicit `--session-dir` paths, custom-directory values already present in CodexBar's own environment, and plain-pi `settings.json` `sessionDir` values are used when they can be resolved. Environment-only roots that exist only inside the agent process are deliberately not read from it. If a custom root or profile cannot be resolved safely, CodexBar keeps the PID-only row instead of inspecting the process's full environment. A session file is never shown without a matching live process.

Choose the row label format in the same settings section:

- **Project** keeps the working-directory name used by earlier releases.
- **Descriptive** uses the Codex thread title, pi/OMP session name when available, or named subagent task, with the project as a fallback.
- **Descriptive + project** shows both when they differ.

Thread and session titles can contain sensitive text. **Project** remains the default. CodexBar reads only bounded metadata, limits labels to 64 Unicode scalars, does not modify provider state, and does not persist titles separately.

The menu groups local sessions first, followed by each remote host. A filled dot is active; an empty dot is idle. Select a local row to activate its terminal, editor, or desktop app. The first focus attempt can request macOS Accessibility permission so CodexBar can raise the matching window. Remote rows run the same focus command over SSH.

The CLI exposes the same scanner:

```console
codexbar sessions
codexbar sessions --json
codexbar sessions --json-v2
codexbar sessions focus <session-id>
```

`codexbar sessions --json` emits the legacy v1 top-level array with only `codex` and `claude` provider values. `codexbar sessions --json-v2` emits the complete array, including provider `pi` and its `pi`/`omp` dialect tag. Dates use ISO 8601.

Remote fetching tries `sessions --json-v2` before the legacy `sessions --json`, first through `codexbar` on `PATH` and then through the bundled app CLI. This lets current hosts return Pi-family rows while both host-first and client-first mixed-version upgrades remain decodable.

Remote hosts need key-based, non-interactive SSH and either `codexbar` on `PATH` or CodexBar installed in `/Applications`.

Tailscale discovery forces the [documented CLI mode](https://tailscale.com/docs/reference/tailscale-cli?tab=macos) with `TAILSCALE_BE_CLI=1` for every local probe, including launchers or symlinks to the macOS app binary. This keeps discovery headless even when inherited terminal variables do not prevent the app binary from launching its GUI or crashing.
