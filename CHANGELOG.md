# Changelog

## 0.33.1 — Unreleased

### Added
- Devin: add daily and weekly quota tracking from the signed-in Chrome session or a manual Bearer token (#1264, fixes #800). Thanks @coygeek!

### Fixed
- Menu bar: anchor merged provider dropdowns to the status item's trailing edge without marking preserved in-flight refresh content fresh, preventing horizontal drift while keeping deferred updates visible (#1288). Thanks @Yuxin-Qiao!
- Cost usage: replace repeated Foundation metadata/root checks with one portable file-stat pass so expired Codex history refreshes stay responsive on very large session archives (#1392). Thanks @TheAngryPit and @ProspectOre!
- Cursor: show the Safari Full Disk Access recovery hint before the long browser login list so permission guidance remains visible when menu errors truncate (#1419, fixes #1417). Thanks @hhh2210!
- Cursor: present legacy request-based plans as one Requests quota with the raw used/limit count instead of unrelated token-based Auto/API bars (#1420, fixes #1418). Thanks @hhh2210!
- Cost usage: memoize Codex priority-turn trace metadata incrementally so warm refreshes scan only appended rows instead of rescanning large trace databases (#1404). Thanks @ProspectOre!
- Security: reject insecure or malformed MiniMax and Alibaba endpoint overrides while preserving valid custom HTTPS deployments (#1269). Thanks @Hinotoi-agent!
- Security: reject insecure or malformed OpenRouter, Codebuff, Groq, and ElevenLabs endpoint overrides before sending provider credentials (#1256). Thanks @Hinotoi-agent!

## 0.33.0 — 2026-06-11

### Added
- Settings: choose Terminal.app or iTerm for Open Terminal actions, including Vertex AI login commands (#1225, fixes #1147). Thanks @Yuxin-Qiao!
- Localization: add Japanese as a selectable app language (#1385). Thanks @naoterumaker!

### Fixed
- Menu bar: keep large dynamic Cost totals inside the fixed-width hosted row so switching providers no longer widens the menu or misaligns submenu arrows.
- Cost history: keep all per-day model breakdown rows available in a bounded scrolling detail area instead of hiding models after the first four (#1370). Thanks @MoollaMore!
- Cost usage: run local session-corpus scans and cache decoding on a dedicated serial queue instead of the Swift cooperative thread pool, so multi-minute scans of large archives no longer starve the app's async work or freeze menus (#1387, #1392). Thanks @ProspectOre!
- Copilot: keep explicitly unlimited chat quotas visible instead of dropping their zero-entitlement payload as unavailable (#1320). Thanks @soumikbhatta!
- Security: block credentialed provider redirects that leave the original HTTPS origin while preserving same-origin redirects (#1237). Thanks @Hinotoi-agent!
- Codex: keep local token and cost history visible when remote quota data is unavailable (#1390). Thanks @vaibhavarora14!
- Doubao: confirm zero-remaining HTTP 200 request limits before falling back, preserving genuine exhaustion and avoiding false 100% usage (#1383). Thanks @LeoLin990405 and @foobra!
- Menu bar: defer pasteboard writes and copy feedback outside the `NSMenu` tracking callback so in-menu copy buttons no longer beachball on macOS 26 (#1388). Thanks @LeoLin990405!
- Menu bar: defer merged status-icon redraws until the tracked menu closes while preserving animation lifecycle and quota-warning timing, reducing WindowServer churn during long menu sessions (#1409, fixes #1399). Thanks @kiranmagic7!
- Provider status: decode status feeds on the concurrent executor and reuse ISO8601 formatters, removing a measured main-thread stall during refreshes (#1406). Thanks @ProspectOre!
- Menu bar: keep one stable width across merged provider tabs and resize every hosted card row to AppKit's final menu width so provider switching no longer leaves a widened menu with inset submenu arrows (#1410).
- Menu bar: keep Codex `auth.json` reads, JWT parsing, and fingerprint hashing off the menu-build path by rendering a cached account snapshot and revalidating it asynchronously (#1401). Thanks @ProspectOre!
- Menu bar: defer Overview-row provider transitions out of AppKit's click callback so opening provider detail no longer performs a full synchronous menu rebuild (#1325).
- Menu bar: open cached menus immediately after data-only invalidations, then refresh missing or stale provider data asynchronously without queuing redundant work on close (#1398). Thanks @joshuavial!
- Menu bar: recycle SwiftUI card hosting views across data refreshes and provider switches, and reconcile matching menu rows in place instead of removing and reinserting every row, cutting open-click, switch, and idle rebuild cost (#1394). Thanks @bcssewl!
- Menu bar: gate the provider-switcher shortcut monitor's event-queue peek behind session event counters so hover-driven menu tracking no longer calls `NSApp.nextEvent` on every run-loop pass (#1397). Thanks @bcssewl!
- Development: disable Keychain access for unbundled executables to avoid repeated password prompts while preserving packaged app behavior (#1271). Thanks @Yuxin-Qiao!
- Antigravity: exclude model quotas without a remaining fraction from family summaries so they no longer mask tracked usage in the automatic menu-bar metric (#1369). Thanks @Martin-Hausleitner!
- Claude: add bundled Fable 5 pricing, account for native 1-hour cache-write usage, and refresh Sonnet 4.6 full-context rates (#1368). Thanks @MoollaMore!
- Claude: show a direct claude.ai re-login action when a configured web session expires or becomes invalid (#1377). Thanks @LeoLin990405!
- Menu: reuse unchanged hosted chart submenus and precompute utilization history models to reduce expand and hover stalls (#1379). Thanks @hhh2210!
- Menu bar: defer data-refresh rebuilds until the tracked menu closes, avoiding multi-second WindowServer stalls with slower providers such as Grok (#1376). Thanks @jangisaac-dev!
- OpenAI Web: evict cached dashboard WebViews after their idle timeout even when no later cache activity occurs, releasing hidden WebKit helper processes (#1386). Thanks @naoterumaker!
- Xiaomi MiMo: import automatic session cookies from Safari, Chrome variants, Firefox, and Edge instead of limiting discovery to Chrome (#1304). Thanks @Yuxin-Qiao!

## 0.32.5 — 2026-06-09

### Added
- Localization: add French as a selectable app language (#1241). Thanks @Yuxin-Qiao!
- Localization: add Ukrainian as a selectable app language (#1250). Thanks @Yuxin-Qiao!
- Localization: add Dutch as a selectable app language (#1252). Thanks @Yuxin-Qiao!
- Localization: add Vietnamese as a selectable app language (#1247). Thanks @Yuxin-Qiao!

### Fixed
- Menu bar: keep provider switching inside AppKit's menu-tracking transaction and defer structural dropdown rebuilds until mouse-up completes, preventing intermittent hangs when moving between providers and Overview.
- Localization: cache resolved localized bundles so repeated menu/status text lookups no longer hit disk on the main thread (#1355, fixes #1347). Thanks @Yuxin-Qiao!
- Menu bar: size hosted chart submenus directly instead of spinning up throwaway SwiftUI hosting controllers during menu layout (#1352). Thanks @Yuxin-Qiao!
- Menu bar: avoid recomputing expensive readiness signatures on closed-menu store ticks while preserving root-open refresh correctness for deferred observations (#1351). Thanks @Yuxin-Qiao!
- Menu bar: defer Quit from the status menu until AppKit menu tracking unwinds so shutdown does not wedge Dock autohide state (#1354, fixes #1353). Thanks @jskoiz!
- Claude: remove transient ClaudeProbe session artifacts after CLI usage polls so background refreshes no longer fill Claude Code project history with CodexBar `/usage` sessions (#1301). Thanks @LPFchan and @matthewod11-stack!
- Menu bar: keep z.ai overview rows with detail submenus in Overview so hovering quota details no longer recurses into a nested provider menu (#1279, fixes #1246). Thanks @RajvardhanPatil07!
- Codex: backfill visible-account reset timestamps and missing 5-hour/weekly window metadata from same-workspace plan history so segmented multi-account JSON keeps machine-readable reset data (#1283). Thanks @callmepopo!
- Antigravity: detect CLI local language-server processes and allow empty CSRF tokens only for explicit CLI matches so Antigravity CLI quota usage renders without weakening IDE CSRF detection (#1341). Thanks @oyaah!
- Menu bar: skip closed attached-menu rebuilds during stale background data-refresh ticks so closed dropdowns are not pre-warmed while the user is not interacting (#1291). Thanks @Nicolas0315!
- Cursor: show deficit and run-out pace details for 30-day Total, Auto, and API billing-cycle usage rows (#1336). Thanks @dhruv-anand-aintech!
- Codex: time out stalled managed `codex login` processes so account switches no longer stay stuck in progress after OAuth completes (#1330). Thanks @dhruv-anand-aintech!
- Codex Spark: show the same deficit and run-out pace details as the core Codex quota lanes for 5-hour and weekly model limits (#1335). Thanks @dhruv-anand-aintech!
- Antigravity: make the automatic menu-bar summary choose the most constrained family quota so an exhausted Gemini lane is no longer hidden by a full Claude lane (#1334). Thanks @dhruv-anand-aintech!
- Performance: memoize models.dev cost catalog load outcomes so large Codex history scans no longer re-read and decode the same cache file per row (#1322, refs #1311). Thanks @turbothad!
- Menu bar: compute Claude pace/reserve from the selected menu-bar metric window so Primary (Session) no longer pairs the session percentage with the weekly reserve (#1302). Thanks @outfoxer!
- Menu bar: defer merged-menu close rebuilds and cache repeated menu-card height measurements so dismissing or rapidly switching the merged dropdown avoids rebuilding SwiftUI-backed cards on the main thread (#1274, #1286, #1314). Thanks @hhh2210!
- Menu bar: keep merged provider tab selection from invalidating broad settings observers so switching providers no longer triggers background refresh and status-icon work.
- Menu bar: observe a compact icon-state signature so merged status icons no longer redraw for provider snapshot changes that cannot affect the visible icon (#1297). Thanks @hhh2210!
- Menu bar: keep provider-switcher quota bars from replacing Auto Layout constraints when the visible ratio is unchanged, making tab switches responsive with many providers enabled (#1303, #1315). Thanks @juanjoseluisgarcia!
- Kiro: retry login-shell PATH capture when CLI discovery races a slow cold shell startup, so `kiro-cli` is no longer stuck as missing for the whole app session (#1316). Thanks @bt-justtrack!

## 0.32.4 — 2026-06-02

### Fixed
- Menu bar: avoid queuing redundant provider refreshes when opening a fresh merged-menu dropdown, while still retrying missing or stale provider data after menu tracking ends (#1235, #1277). Thanks @hhh2210!

## 0.32.3 — 2026-06-02

### Fixed
- Menu bar: stop forcing a private preferred-position value for fresh status items; suspicious stored positions are now cleared so AppKit can place CodexBar normally on macOS 26 / 5K displays (#1267). Thanks @AdrianSimionov, @kirocop, and @Yuxin-Qiao!
- Menu bar: cache provider brand icons so merged-icon status updates no longer repeatedly parse SVG assets on the main thread during hover/open animations (#1235, #1274). Thanks @andradebruno, @xingpz2008, and @Yuxin-Qiao!
- Copilot: treat GitHub Copilot Business token-billing zero-entitlement quotas as unavailable instead of showing misleading 0% used usage (#1258, #1270). Thanks @devYRPauli!
- Menu bar: prepare closed menus after refresh and only reuse stale dropdown content for data-refresh invalidations so merged menu opens stay responsive without bypassing privacy or structure changes (#1261). Thanks @ProspectOre!
- OpenAI Web: stop reloading away from login and Cloudflare blocking states so the dashboard WebView does not loop on route corrections (#1259). Thanks @ProspectOre!

## 0.32.2 — 2026-06-01

### Added
- QA: document the live CodexBar e2e flow and add a redacted provider-matrix helper for packaged CLI smoke tests.

### Fixed
- Menu bar: add breathing room to compact Codex account rows so the provider, account, status, and plan labels no longer hug the row edges.
- Performance: make Codex token-cost scanning faster and more memory-efficient on large local session corpora.

## 0.32.1 — 2026-05-31

### Fixed
- Claude: keep Claude CLI-owned OAuth refresh tokens delegated to Claude Code when CLI storage is present, preventing CodexBar from consuming rotating refresh tokens and forcing re-login (#1161, #1239). Thanks @RajvardhanPatil07!
- Menu bar: reuse short-lived Codex account reconciliation snapshots so repeated menu rebuilds do not reread local auth state on every open.
- Menu bar: defer automatic provider refreshes until after AppKit menu tracking ends so opening the dropdown no longer starts work that can freeze focus and keyboard input.
- Menu bar: suppress background keychain and OpenAI dashboard work during startup/menu tracking so the dropdown stays clickable without macOS keychain prompts or WebKit memory spikes.

## 0.32.0 — 2026-05-31

### Added
- Settings: add search to the Providers pane so large provider lists can be filtered by name or id (#1184). Thanks @046081-dotcom!

### Fixed
- Augment: parse the updated `auggie account status` output format, fall back to browser cookies when CLI parsing fails, and restore session cookie detection (#1224). Thanks @bcharleson!
- Amp/Ollama: require HTTPS before reattaching imported browser cookies on provider redirects to avoid cleartext cookie exposure (#1226). Thanks @Hinotoi-agent!
- Antigravity: filter noisy remote OAuth per-model quota rows, keep consumed noisy rows detail-only, and prevent image/lite/autocomplete/internal rows from driving summary bars (#1209). Thanks @guhyun9454!
- Claude: preserve the last good Claude Web usage snapshot across transient Unauthorized refresh failures while still surfacing repeated auth failures (#1220). Thanks @LeoLin990405!
- CLI: avoid executing a same-user mutable temporary installer script across the macOS administrator privilege boundary (#1222). Thanks @Hinotoi-agent!
- Codex: cancel OpenAI WebKit dashboard refreshes promptly and avoid an immediate second background WebView retry after timeouts, reducing launch-time Web Content CPU spikes (#1217).
- Menu: refresh open Codex menu adjuncts as dashboard, credits, token-cost, and plan-history data become ready after cold start (#1150). Thanks @AmrMohamad!
- Menu bar: defer background parent-menu rebuilds until AppKit menu tracking ends so late-arriving usage data cannot stall dropdown hover on macOS 26.5 (#1227).
- Menu bar: give CodexBar status items stable placement identities while preserving existing upgrade placement state (#1216). Thanks @pdurlej!
- Release: isolate notarization API keys and upload ZIPs in a private per-run temporary directory instead of predictable shared /tmp paths (#1228). Thanks @Hinotoi-agent!
- Status: retry startup refreshes a few times after transient offline/network failures so provider status can recover after macOS brings the network online (#1211).

## 0.31.0 — 2026-05-28

### Changed
- Docs: update the Homebrew install command to use the official `codexbar` cask now that it supports Intel Macs (#1189). Thanks @SSakutaro!
- Tests: document and audit that routine validation must not trigger macOS Keychain prompts.
- Localization: localize popup panels and provider settings UI across supported languages (#1181). Thanks @jack24254029!
- Localization: complete Brazilian Portuguese coverage so pt-BR no longer falls back to English for new UI strings (#1188). Thanks @ManuzimFerreira!

### Added
- AWS Bedrock: support resolving usage and cost-history credentials from a named AWS profile via the AWS CLI (#1190). Thanks @oleksandr-soldatov!
- Codex: show Codex Spark model-specific usage as an optional extra quota lane (#1195, fixes #1177). Thanks @LeoLin990405!
- Localization: add Swedish as a selectable app language (#1186). Thanks @yeager!

### Fixed
- CLI: bound `codexbar serve` requests with a configurable timeout and coalesce concurrent cache misses so hung `/usage` callers no longer stampede provider refreshes (#1208). Thanks @enieuwy!
- Claude: add Opus 4.8 to the built-in pricing fallback so stale models.dev caches still show token cost (#1214, fixes #1210). Thanks @devYRPauli!
- Codex: preserve authorized web dashboard credits-only snapshots instead of treating missing usage windows as a failed refresh (#1206, fixes #1204). Thanks @soumikbhatta!
- Cost history: make token-cost JSONL scans cancellation-aware so quitting, forced refreshes, and account switches can stop stale scans sooner.
- Codex: show Spark 5-hour and weekly usage as separate quota lanes in Codex breakdowns (#1201).
- Codex: show captured `codex login` output when managed Add Account fails so users can recover from account-selection or OAuth failures (#1199). Thanks @chapati23!
- Claude: hide the obsolete Design quota lane now that Claude Design shares the main Claude usage limit (#1197).
- Menu bar: coalesce visible-menu rebuilds and reduce hover highlight work so the dropdown stays responsive on macOS 26.5 (#1196).

## 0.30.1 — 2026-05-28

### Changed
- CLI: make `codexbar diagnose` use a generic safe provider diagnostic export for all providers, with MiniMax details attached only as provider-specific metadata.

### Fixed
- Settings: add trailing breathing room to provider-sidebar controls (#1183). Thanks @Yuxin-Qiao!
- Claude: treat OAuth usage HTTP 429s as rate limits, preserve cached credentials, and back off background retries while still allowing manual refresh (#1179). Thanks @LeoLin990405!
- Menu bar: stop repeated display-change status-item recreation from corrupting Control Center or confusing menu bar managers (#1176, fixes #1175). Thanks @diazdesandi!

## 0.30.0 — 2026-05-27

### Added
- MiniMax: add a redacted diagnostic CLI export for safe issue reports (#1128). Thanks @Yuxin-Qiao!
- Antigravity: show the complete per-model quota breakdown alongside the existing summary lanes (#1139). Thanks @guhyun9454!
- Widget: show tertiary usage rows for providers that expose a third quota lane (#1160). Thanks @LeoLin990405!
- DeepSeek: show optional web-session usage and cost summaries alongside the balance card (#1166). Thanks @Yuxin-Qiao!
- OpenAI: scope Admin API usage to the configured project and keep token accounts from inheriting stale project filters (#1168). Thanks @mstallone!

### Fixed
- App shutdown: detach status items, close tracked menus, and cancel menu tasks before quit so Dock autohide stays responsive on macOS 26.5 (#1174). Thanks @jskoiz!
- Widgets: package the macOS widget as a real Xcode app-extension target so WidgetKit descriptors load on macOS 26.5 (#1095). Thanks @jamesjlopez!
- Menu: render quota-warning markers as subtle inset ticks instead of full-height bars (#1149).
- Codex: show sign-in guidance when the Codex CLI is logged out instead of reporting a temporary usage outage (#1171, fixes #1170). Thanks @jskoiz!
- Menu bar: clear stale hidden macOS status-item visibility defaults once before creating CodexBar items (#1169).
- StepFun: refresh expired Oasis tokens and persist recovered manual sessions. Thanks @LeoLin990405!
- Release: prevent manual CLI artifact builds from publishing or clobbering release assets (#1154). Thanks @jskoiz!
- Cost history: route OpenAI and Mistral API spend through the shared cost-history cards, including OpenAI request counts (#1163). Thanks @LeoLin990405!
- Menu: keep provider switcher Cmd-number and arrow shortcuts working while the open menu is tracking events (#1157, fixes #1156 and #1144). Thanks @anirudhvee!
- Codex: prevent fork token replay from overcounting corrected cumulative session totals (#1164). Thanks @xx205!
- Alibaba Token Plan: update usage refreshes to the Bailian subscription-summary endpoint (#1142). Thanks @YanxinXue!
- Ollama: show pace projections for documented 5-hour session and 7-day weekly usage windows (#1136). Thanks @bdamokos!
- Localization: polish Simplified Chinese wording and add notification strings (#1165). Thanks @fanfanci!
- Localization: improve Traditional Chinese wording and localize notification copy (#1158). Thanks @jack24254029!
- Localization: improve Simplified Chinese visible menu, dashboard, and usage labels (#1145). Thanks @Yuxin-Qiao!

## 0.29.1 — 2026-05-26

### Added
- Integrations: list the Noctalia/Quickshell Codex usage plugin in the Linux CLI integrations (#1115). Thanks @rayoplateado!
- Display: add optional workday markers for weekly progress bars (#1102). Thanks @Yuxin-Qiao!
- Localization: add Traditional Chinese (`zh-Hant`) app strings. Thanks @ilyaliao!

### Fixed
- Claude: classify Claude CLI 2.1 subscription-only `/usage` output separately and fall back to direct CLI usage when the PTY panel fails to load (#1121, fixes #1116). Thanks @Yuxin-Qiao!
- Provider switcher: keep multi-row account/provider controls compact so large menus stay within bounds (#1113). Thanks @Yuxin-Qiao!
- Grok: label usage bars from the actual reset window instead of the remaining reset distance (#1148). Thanks @kiankyars!
- Config: keep legacy credentials when migrated config changes fail to save so retry can recover them (#1146). Thanks @RajvardhanPatil07!
- Codex: avoid overcounting forked sessions when parent logs are missing while still counting incremental usage (#1143). Thanks @jskoiz!
- Groq: show a distinct Groq provider icon instead of reusing the Grok glyph (#1112). Thanks @kiankyars!
- Claude: normalize OAuth extra-usage spend limits from minor units so Enterprise spend displays as currency instead of 100x too high (#1114, fixes #1111). Thanks @Yuxin-Qiao!
- Menu bar: preserve status item identity during display-change recovery so menu bar managers do not treat CodexBar as a new hidden item (#1122, fixes #1109). Thanks @lederniermagicien!
- OpenAI: retry transient Admin API usage failures once before surfacing an access error (#1117).
- OpenCode Go: read local usage history before falling back to browser-cookie dashboard fetches (#1021). Thanks @sopenlaz0!
- Menu bar: show extra-usage spend as currency text for Claude and Cursor when that metric is selected (#1107). Thanks @Yuxin-Qiao!
- Codex: run regular credits and OpenAI dashboard refreshes in the background while coalescing overlapping refresh work (#1078). Thanks @ptstory!

## 0.29.0 — 2026-05-22

### Added
- Cost history: show Codex standard and fast spend/token splits in model breakdowns (#1070). Thanks @iam-brain!
- Alibaba Token Plan: add Bailian token-plan quota tracking via browser or manual cookies (#1098). Thanks @YanxinXue!
- OpenCode: show workspace renewal dates for OpenCode and OpenCode Go usage windows (#1099). Thanks @Yuxin-Qiao!

### Fixed
- Localization: improve Simplified Chinese settings and menu translations (#1059). Thanks @narallee!
- Alibaba Token Plan: reject non-HTTPS endpoint overrides and keep the provider building on Linux (#1104). Thanks @YanxinXue!
- Settings: avoid crashing when API key or cookie settings contain only a single quote character (#1106). Thanks @m1qaweb!
- Build scripts: derive the local development signing team ID from the certificate OU before falling back to the CN suffix (#1095).
- Menu bar: keep retrying display-change recovery when macOS leaves status items detached from the current screen (#1077, #1088).
- Codex: preserve last successful per-account quota snapshots when later network or DNS refreshes fail (#1097, #1101). Thanks @Yuxin-Qiao!

## 0.28.0 — 2026-05-22

### Added
- Ollama: add API key authentication as an alternative to browser cookies for validating Cloud access (#1044). Thanks @nandorocker!
- Azure OpenAI: add deployment-status validation via API key, endpoint, and deployment settings (#1045). Thanks @ZenoRewn!
- Localizations: add Spanish and Catalan language packs and fill missing localization keys (#1041). Thanks @seifreed!
- Providers: T3 Chat - add web-session usage tracking, can paste a full browser cURL when cookie-only refreshes hit a 429 challenge (#1091). Thanks @Quicksaver!

### Fixed
- Menu: restore full-width provider switcher quota bars and refresh them while the menu stays open (#1094). Thanks @bcharleson!
- Codex: accept the first click in the account switcher inside menu popovers (#1079). Thanks @ptstory!
- Codex/Claude: terminate PTY child process trees during probe cleanup so wrapper-launched CLI descendants do not linger after sessions finish (#1085). Thanks @mickobizzle!
- MiniMax: exclude explicitly failed billing-history records from token charts and model/method totals (#1089). Thanks @Yuxin-Qiao!
- OpenAI: parse Wednesday and Saturday dashboard reset lines so rate-limit reset times are not dropped on those days (#1080). Thanks @m1qaweb!
- Localization: translate provider-detail labels and empty states when Simplified Chinese is selected (#1051). Thanks @wang93wei!
- Antigravity: discover OAuth credentials from the bundled extension language server in newer IDE builds so Add Account works again (#1076). Thanks @xARSENICx!
- Menu bar: suppress redundant icon observer work during refresh cycles, reducing icon update passes without changing rendered state (#1081). Thanks @ptstory!
- Menu bar: wait for display changes to settle before recovering status items and retry if macOS still leaves the icon detached (#1074). Thanks @yipjunkai!
- Menu: keep lower action rows stable when Refresh is highlighted or pressed (#1071). Thanks @MadanChaollaPark!
- Linux CLI: avoid linking JetBrains provider parsing against `libxml2.so.2`, improving compatibility with newer distros that ship libxml2 2.15+ (#1046). Thanks @semsemyonoff!
- Claude: remove the obsolete peak-hours indicator and setting now that Anthropic no longer applies peak-hour limits (#1023). Thanks @rohitjavvadi!
- Antigravity: verify cloud model lists that report every quota as full against the user quota endpoint before showing remote OAuth usage (#1063). Thanks @devpras22!
- Codex: avoid recounting repeated local token snapshots when total usage has not changed (#1062). Thanks @BarryYangi!
- Antigravity: discover OAuth clients from Antigravity 2 app bundles and binary artifacts so Add Account works again (#1053). Thanks @vyctorbrzezowski!
- Codex: honor the explicit OAuth credits source and keep automatic credits refresh falling back to CLI when OAuth usage has no credits (#1054). Thanks @soumikbhatta!
- Codex: show missing-CLI installation guidance in app and CLI errors without dropping cached-refresh context (#1030). Thanks @rohitjavvadi!
- LLM Proxy: parse fractional-second quota reset timestamps from API responses (#1022). Thanks @rohitjavvadi!
- ElevenLabs: keep progress text legible in light mode (#1055). Thanks @vyctorbrzezowski!
- Claude: detect loading-only CLI usage screens and give CLI-only auto refreshes one longer retry instead of stalling or reporting a false missing-session error (#1032, fixes #1031). Thanks @rohitjavvadi!
- OpenAI: avoid serializing the full dashboard DOM during normal web refreshes, reducing CPU and memory churn while preserving account and plan detection (#1034, fixes #1033). Thanks @jb510!
- Codex: skip macOS-blocked Codex CLI candidates during automatic binary resolution and let CLI auto mode use OAuth before falling back to `codex app-server` (#1038, fixes #1028). Thanks @m-rokai!
- Codex: wait for explicit Refresh to finish token-cost history before rebuilding open menus, while keeping automatic/menu-open refreshes non-blocking (#1040). Thanks @zhulijin1991!
- Antigravity: detect the new 2.0 unsuffixed `language_server` process so local IDE usage probing works again (#1049). Thanks @urbanonymous!
- Claude: prevent headless CLI usage probes from creating Claude Code URL Handler apps in Launchpad (#1047).
- Codex: invalidate local cost-history caches from the scanner source hash so parser fixes rebuild stale cached rows automatically (#1042). Thanks @hhh2210!
- Release: update Homebrew automation so CodexBar releases publish both the CLI formula and app cask from the same workflow.

## 0.27.0 — 2026-05-18

### Added
- Usage charts: reuse the OpenAI API inline dashboard for local Codex/Claude/Vertex/Bedrock cost history, OpenRouter day/week/month spend, z.ai hourly tokens, and Mistral daily spend.
- Usage history: let OpenAI Admin API charts and local cost-history scans use a configurable 1–365 day window instead of a fixed 30 days (#83).
- Grok: add xAI Grok provider support with local identity detection and billing decoding for the Grok CLI integration (#965). Thanks @taibaran!
- ElevenLabs: add API-key usage tracking for subscription credits, reset time, and voice-slot limits.
- Deepgram: add API-key usage tracking with project discovery and speech/agent usage breakdowns (#1003, fixes #994). Thanks @czjzpz!
- GroqCloud: add API-key usage tracking for Enterprise Prometheus metrics with request, token, and cache-hit rate summaries (#993).
- LLM Proxy: add API-key quota-stats support for aggregate proxy usage, key health, spend, provider breakdowns, and reset windows (#264).
- Claude: add an Anthropic Admin API source and allow `sk-ant-admin...` keys in Claude token accounts for API spend/token tracking (#966).
- MiniMax: add web-session billing-history summaries with 30-day token charts and top model/method breakdowns (#1007).
- OpenCode Go: show the optional Zen pay-as-you-go balance from the workspace dashboard alongside subscription windows (#1006).
- Kiro: add overage-credit and overage-cost menu bar display modes for exhausted plans (#972). Thanks @raflyazf!
- CLI: add `codexbar config set-api-key` for safely storing provider API keys from stdin.
- CLI: add `codexbar config providers`, `enable`, and `disable` for scripting the same provider toggles used by Settings.
- CLI: let `--all-accounts` and `codexbar serve` export every visible Codex account instead of only the selected account (#1019).
- Permissions: notify when a provider probe detects a macOS/browser permission prompt waiting for user action (#456).
- Quota warnings: include the triggering account in notification copy when personal info is visible (#973). Thanks @raflyazf!
- Website: replace provider-letter tiles with brand logos, add light/dark landing-page themes, and collapse OpenCode/OpenCode Go into one company entry (#989). Thanks @pasangimhana!
- Providers: route app-owned provider HTTP calls through a shared transport seam for cleaner proxy and test support (#892). Thanks @serezha93!

### Fixed
- Codex: make local cost-history scans faster and more stable for large session archives while preserving fork attribution, priority pricing, and cached history windows.
- Codex: collapse near-duplicate session and weekly plan-utilization history windows so charts no longer show repeated tabs (#1027). Thanks @ngutman!
- Multi-account menus: fetch stacked Codex/token-account usage concurrently so account switchers stay responsive with many accounts (#1011).
- Codex: keep local cost history attributed to the correct model when long or oversized `turn_context` rows precede model-less token events (#1014, fixes #1013). Thanks @hhh2210!
- Codex: prefer per-event token usage over divergent total counters when scanning local cost history, preventing large false cost spikes (#968). Thanks @Ifan24!
- Claude: de-duplicate copied fork/resume transcript history by provider response identity so local cost estimates do not overcount repeated rows (#1002). Thanks @Neverdie-2!
- Codex: improve multi-account switching with quota-aware ordering, workspace grouping, persisted per-account snapshots, health labels, and auth fingerprint matching.
- Codex: improve managed account login recovery guidance when macOS blocks or moves a stale `codex` CLI to Trash (#977).
- Codex: show weekly pace reserve details in the menu even when the caller did not precompute pace data (#1009). Thanks @zhulijin1991!
- Overview: expose provider chart and storage detail submenus from overview rows instead of requiring a provider-tab switch first.
- Claude: reset stuck CLI sessions after usage probe timeouts, give slow probes longer to render, and keep stale data visible across transient timeouts.
- Claude: keep the last successful usage card visible across transient probe timeouts while still clearing stale data after Claude auth changes.
- Claude: keep Team and Personal Max plan-utilization history separate when the same email appears on multiple Claude accounts (#213).
- Claude: label Extra usage denominators as the monthly cap so recharge balances are not confused with the maximum spend limit (#975).
- Claude: wait for the CLI usage panel to finish rendering after the Current session label so slow Claude Code builds do not produce false "Missing Current session" errors (#959).
- Claude: label five-hour session pace as "Projected empty" so it is not confused with the reset countdown (#960).
- Claude: show Enterprise spend-limit usage in automatic menu bar metrics and expose the Extra usage metric picker when spend data is available (#964).
- Grok: retry transient web billing timeouts once and allow slower billing RPCs to finish before showing an error.
- Grok: fall back to grok.com's billing endpoint when `grok agent stdio` omits the xAI billing method (#984). Thanks @bcharleson!
- OpenAI: shorten the provider label to "OpenAI" so the menu tab no longer clips.
- OpenAI: accept numeric-string Admin API cost amounts so usage does not fail when `/v1/organization/costs` returns `"amount": { "value": "12.50" }` (#999, #1000). Thanks @SergeyLavrentev!
- Menu: keep provider switcher buttons centered by moving quota indicators out of the button layout.
- Menu: rebuild the selected provider content after switching tabs while an overview chart submenu is open.
- Menu: keep the persistent Refresh row at a fixed height while highlighted or pressed so nearby items no longer jump (#1001).
- Menu bar: avoid re-reading provider credentials, Codex account state, Claude terminal probe text, and storage footprints on hot menu paths, reducing idle CPU while providers are still loading.
- Menu bar: skip unchanged split-provider icon redraws and avoid an extra animation-state scan during blink ticks.
- Menu bar: recover visible status items after the display hosting the menu bar item is unplugged (#998, fixes #997). Thanks @Llldmiao!
- Menu bar: recreate status items on startup when macOS reports them visible but never attaches a menu bar button/window (#988).
- MiniMax: show Coding Plan model-remains quotas as used/limit cards and include weekly text-generation quota windows (#970). Thanks @Yuxin-Qiao!
- Ollama: let automatic session import fall back from Chrome to Safari, Comet, and the rest of the browser import order when Chrome has no Ollama session (#962).
- Kimi K2: label the legacy provider as unofficial and remove links that presented the legacy endpoint as an official Kimi account surface (#967, fixes #473). Thanks @mturac!
- CLI: use explicit provider HTTP timeouts so blocked network connections fail instead of leaving usage commands stuck for days (#1005, fixes #1004). Thanks @msmolkin!
- CLI: reject non-loopback `Host` headers in `codexbar serve` before serving local usage and cost metadata (#995). Thanks @rohitjavvadi!
- Packaging: skip slow widget App Intents metadata during dev restarts and preserve the previous app bundle if required metadata generation times out.
- Localization: fall back to English when a bundled localized string is blank instead of rendering empty menu/settings text (#952). Thanks @xiaoqianWX!
- Settings: localize the provider storage usage toggle in the Advanced pane (#985, fixes #971). Thanks @tanish19078!

## 0.26.1 — 2026-05-15

### Added
- OpenAI API: show Admin API usage inline with Today/7d/30d summaries, a 30-day spend graph, and an interactive detail chart for daily spend, tokens, and requests.
- CLI: add `codexbar serve` for localhost JSON access to usage and cost endpoints (#957). Thanks @ThiagoCAltoe!

### Fixed
- OpenCode Go: block cross-host redirects when fetching usage so imported cookies cannot follow external redirect targets (#969). Thanks @pavbar!
- Codex: keep background `/status` probes out of Codex Desktop history by using isolated non-persistent CLI storage (#953).
- Menu: stabilize the Cost submenu by using a native menu item and deferring open-menu rebuilds while tracking (#954). Thanks @getogrand!
- Localization: add Brazilian Portuguese quota-warning settings strings (#958). Thanks @ThiagoCAltoe!

## 0.26.0 — 2026-05-15

### Added
- Codex: add tiered long-context and Fast/Priority pricing to local cost history using local app-server priority traces (#917). Thanks @iam-brain!
- Kiro: show account/auth details, plan labels, credit and bonus-credit balances, overage state, and Kiro-specific menu bar display options (#933, fixes #934). Thanks @solnikhil!
- Antigravity: add Google OAuth token-account switching with selected-account refresh persistence (#937, fixes #936). Thanks @hhh2210!
- OpenRouter: show daily and weekly API key spend from `/api/v1/key` in the menu (#685). Thanks @ThiagoCAltoe!
- Display: add a setting to hide quota-warning tick marks on usage bars while keeping quota warning notifications active (#918, fixes #916). Thanks @ThiagoCAltoe!
- Menu: add left/right arrow keyboard navigation for the merged provider switcher (#266).
- Menu: add an opt-in setting for provider changelog links, starting with Codex, Claude Code, and Gemini CLI (#929, fixes #660). Thanks @ThiagoCAltoe!
- AWS Bedrock: add Cost Explorer usage and monthly budget tracking (#897). Thanks @afalk42!
- Kilo: add organization selection, scoped organization fetches, and stacked Kilo usage cards (#920). Thanks @NoeFabris!
- Moonshot / Kimi API: add API-key balance tracking, CLI support, docs, and menu bar balance copy (#899). Thanks @giuseppebisemi!
- z.ai: add an hourly per-model token usage chart in the menu (#913). Thanks @n1majne3!
- Localization: add Brazilian Portuguese translations (#902). Thanks @ThiagoCAltoe!
- Localization: add Simplified Chinese translations for Claude peak-hour labels (#921). Thanks @whtis!

### Fixed
- Codex: show authenticated plan/account rows as "Limits not available" instead of a red no-rate-limit error when Codex reports profile data but no rate-limit windows yet.
- Overview: hide provider rows that only contain an error, and avoid showing a one-item Codex System Account submenu.
- Menu: disable implicit provider-switcher layer animations and reuse the deferred rebuild path so open menus stay stable under pointer movement (#950).
- Menu: defer account-switcher menu rebuilds so switching Codex or token accounts does not send the open menu into a flicker loop (#946, fixes #944). Thanks @kubahasek!
- Menu: avoid rebuilding visible menus during background open-menu refreshes so hover submenus stay responsive (#923, fixes #909). Thanks @AmrMohamad!
- Codex: scope local cost history to the selected managed account's `CODEX_HOME` and label cost cards as local-log estimates (#910).
- Cost history: label local log totals as API-rate estimates in menu cards, charts, and CLI output (#926). Thanks @yashiels!
- Cursor: open Add Account in the user's browser and import the resulting browser session instead of trapping login in an embedded web view (#922).
- Claude: handle Enterprise and organization spend-limit usage across OAuth/web accounts, including null session quota windows, inline spend-limit usage, `extra_usage`-only responses, and token-account Org ID support (#925, #941, fixes #940). Thanks @clintandrewhall!
- OpenCode Go: let automatic cookie import scan all supported browser sources instead of Chrome only (#665).
- Copilot: preserve over-quota usage so paid overage can show above 100% instead of clamping to exhausted (#818).
- Codex: pause background CLI launches after macOS blocks or quarantines `codex`, avoiding repeated "Malware Blocked" prompts (#942).
- Claude: clarify that local cost/token estimates include cache read/write tokens and may differ from Claude Code `/status` (#781, #787).
- Updates: make the restart/apply-update menu action use Sparkle's prepared install callback on the first click (#947). Thanks @velvet-shark!
- Multi-account menus: keep stacked token-account cards capped to current accounts and ignore stale snapshots from removed accounts (#949).
- Droid: accept pasted Factory `Authorization: Bearer` headers and bearer tokens for manual sessions when cookies alone are insufficient (#914).
- Menu bar: detect when macOS Tahoe hides CodexBar behind the new Allow in Menu Bar setting and show recovery guidance (#945, fixes #890). Thanks @pdurlej!
- CLI: route Claude token-account `--source cli` reads through the selected OAuth/session credential so `--all-accounts` no longer relabels ambient CLI usage (#403).
- Codex: route menu account refreshes through the resolved live-vs-managed account source so matched accounts keep using the stable `CODEX_HOME` (#932, fixes #931). Thanks @ThiagoCAltoe!
- Gemini: refresh OAuth credentials when the CLI has a refresh token but no cached access token instead of reporting "not logged in" after authentication (#915).
- Gemini: label OAuth-backed API fetches as `oauth-api` instead of plain `api` (#930). Thanks @ThiagoCAltoe!
- Codex: keep session and weekly quota-warning marker thresholds independent so usage bars do not duplicate marker lines (#938, fixes #927). Thanks @iam-brain!
- Codex: coalesce historical pace reset timestamps into 5-minute buckets so dashboard and live reset jitter do not duplicate weekly history windows (#901). Thanks @zhulijin1991!
- Menu: middle-truncate long account emails in Codex account controls and keep the Codex account switcher visible during merged-menu refreshes with transient account snapshots.
- Settings: apply the selected app language from packaged SwiftPM resources instead of falling back to English when the `.lproj` directory casing differs (#908).
- Settings: let stale managed Codex account records be removed even when their stored home path is outside CodexBar's managed-home directory, and keep CLI known-owner tests from writing fixtures into the live app store.
- ChatGPT credits: restrict purchase links to real HTTPS `chatgpt.com` settings/usage/billing/credits paths and drop query/fragment data (#903). Thanks @ThiagoCAltoe!
- z.ai: show the MCP quota bucket as monthly instead of a misleading 1-minute window (#904). Thanks @ThiagoCAltoe!
- Kimi: rebalance provider icon alignment within its viewBox (#912). Thanks @giuseppebisemi!
- Release: include macOS platform and architecture in notarized app and dSYM asset names (#164).
- Upstream tooling: resolve remote default branches and tolerate missing upstream remotes in review scripts (#906).

## 0.25.1 — 2026-05-11

### Fixed
- Settings: avoid packaged-app crashes from SwiftPM localization bundle lookup when opening Settings or About (#896, fixes #891). Thanks @lederniermagicien!
- CLI: include a VERSION file in standalone release archives so `--version` reports the release tag outside the app bundle (#898). Thanks @ThiagoCAltoe!
- Pi: rebuild stale session cost caches after cache-version migrations so refreshed cost history reflects current scanner data.
- Keychain cache: reduce repeated development prompt churn by trusting the bundled helper when writing CodexBar-owned cache items (#888).

## 0.25 — 2026-05-10

### Highlights
- Localization: add Simplified Chinese app strings and an in-app language selector (#819). Thanks @markhome1!
- New providers: Manus, MiMo, Qwen, Doubao, Command Code, StepFun, Crof, Venice, and OpenAI API balance support.
- MiniMax: add multi-service quota cards for text, speech, image, video, and music coding-plan usage (#605). Thanks @XWind18!
- Notifications: add opt-in quota warning notifications, warning markers, and provider-level thresholds for session and weekly quota windows (#852). Thanks @Alekstodo!
- Codex: add stacked multi-account switchers and show official Pro 5x/Pro 20x plan labels (#869, #882). Thanks @ajmccall and @xiaoqianWX!
- Cost history: use live models.dev pricing metadata, preserve tiered pricing boundaries, and keep large Codex/Claude log scans incremental (#863, #884, #886). Thanks @iam-brain!
- Menu bar: fix hidden/stale status items, keep manual refreshes open, and improve balance-style menu bar text for providers without useful quota percentages (#845, #853, #861). Thanks @OlimjonovOtabek and @willytop8!
- Accessibility: add VoiceOver labels for status icons, menu rows, provider switcher buttons, and usage charts (#860, fixes #859). Thanks @WadydX!

### Providers & Usage
- Manus: add browser-cookie provider support for credit balance, monthly credits, and daily refresh tracking (#700). Thanks @hhh2210!
- MiMo: add browser-cookie provider support for Xiaomi token-plan usage, plan labels, balance fallback, CLI, widget, and docs (#651). Thanks @debpramanik!
- Qwen and Doubao: add API-key provider support for Alibaba Qwen and Volcengine Ark request-limit tracking (#498). Thanks @LeoLin990405!
- MiniMax: add multi-service quota cards for text, speech, image, video, and music coding-plan usage (#605). Thanks @XWind18!
- Antigravity: add OAuth-backed remote usage fetching so quotas can refresh even when the IDE is closed (#635). Thanks @abnormal749!
- Venice: add API-key balance provider support with DIEM/USD balance display and token-account CLI wiring (#865). Thanks @clawSean!
- Crof: add API-key provider support with request quota and credit balance tracking (#872). Thanks @baanish!
- OpenAI API: add optional platform credit-balance tracking from the billing credit-grants endpoint (#877).
- Command Code: add browser-cookie provider support for monthly USD billing credits (#857). Thanks @sixhobbits!
- StepFun: add username/password or Oasis-Token provider support for Step Plan rate-limit tracking (#815). Thanks @tevenfeng!
- Factory/Droid: add token-rate-limit billing windows, Core fallback buckets, and extra usage balance display (#878). Thanks @dantemoon1!
- OpenRouter, Mistral, and Kimi K2: show balance/spend metrics in menu bar text when quota percentage is not useful (#853). Thanks @willytop8!
- Usage pace: show session-level pace indicators for Codex and Claude 5-hour windows, and compute pace for any explicit reset window instead of a provider allowlist (#355, #875). Thanks @johnlarkin1 and @ViperThanks!
- Cost history: add a models.dev pricing metadata parser/cache pipeline and prefer cached models.dev pricing for Codex and Claude before bundled fallback tables (#863, #884). Thanks @iam-brain!
- Browser cookies: bump SweetCookieKit to 0.4.1 for Comet and Yandex browser discovery, Safari profile cookie stores, and per-browser Chromium Safe Storage keys.

### Menu & Settings
- Codex: add a stacked multi-account menu layout for account switchers (#869). Thanks @ajmccall!
- Notifications: add opt-in quota warning notifications, warning markers, and provider-level thresholds for session and weekly quota windows (#852). Thanks @Alekstodo!
- Accessibility: add VoiceOver labels for status icons, menu rows, provider switcher buttons, and usage charts (#860, fixes #859). Thanks @WadydX!
- Menu bar: keep status items visible on launch by avoiding macOS autosaved hidden menu-extra state from v0.24 (#861).
- Menu bar: remove stale split provider status items instead of hiding them, avoiding leftover second-icon slots on macOS 26.4.
- Menu: keep the status menu open when manually refreshing usage from the menu (#845). Thanks @OlimjonovOtabek!
- Menu: route provider switcher tab clicks through the parent view's mouse tracking so a sub-provider tab still responds after switching back from the Overview tab (#867). Thanks @Karl-Dai!
- Menu: keep long Codex account labels from widening the status menu when switching to the Codex tab.
- Menu: keep Cost and Subscription Utilization submenus stable by deferring parent card rebuilds while hosted submenus are open (#862).
- Settings: avoid a crash when opening the display overview provider picker.

### Fixes
- Startup: avoid blocking menu-bar creation on synchronous defaults migration/default seeding when macOS preferences services stall.
- Codex: honor the legacy `openAIWebAccess` defaults key when importing OpenAI web extras preferences, so existing terminal workarounds no longer get ignored on launch (#794).
- Codex: restrict OAuth auto fallback to missing/invalid auth so transient API/decode errors do not spawn `codex app-server` and burn tokens (#876, fixes #874). Thanks @ViperThanks!
- Codex: show official Pro 5x/Pro 20x plan labels instead of Pro Lite/Pro in menu and CLI output (#882). Thanks @xiaoqianWX!
- Cost history: keep manual refreshes on the incremental scanner cache and drain per-line JSON parse allocations so large Codex/Claude histories do not trigger full local log rescans and CPU/memory spikes.
- Cost history: preserve cached models.dev pricing when an upstream catalog only changes a pinned snapshot suffix for the same model family (#883). Thanks @iam-brain!
- Cost history: preserve per-request tiered pricing boundaries when aggregating Claude/Pi daily reports (#886). Thanks @iam-brain!
- Keychain cache: trust the bundled CodexBarCLI helper when writing CodexBar-owned cache items, reducing repeated "CodexBar Cache" prompts from CLI usage (#679). Thanks @QuarkAssistant!
- Locale: keep relative timestamps in hardcoded-English UI labels consistently English on non-English macOS systems (#868, fixes #866). Thanks @Karl-Dai!
- Droid: send the bearer JWT subject as the usage `userId` when Factory omits `userProfile.id`, avoiding false login failures (#626). Thanks @CrystalChen1017!
- Droid: fall back to token/allowance math when the Factory API reports a zero ratio despite non-zero usage (#864). Thanks @proxynico!
- Alibaba: point the International Coding Plan dashboard link at the current `coding_plan` route and clarify unsupported API-key quota errors (#612).
- Claude: allow web/sessionKey token accounts to specify `organizationId` so linked Anthropic emails can target the intended org (#848).
- DeepSeek: show a positive CNY balance when the API also returns an empty USD balance (#873).
- Vertex AI: detect service-account ADC files from `GOOGLE_APPLICATION_CREDENTIALS` and use `gcloud` to fetch access tokens (#871).
- Gemini: retry direct API requests with curl when URLSession times out on hosts where curl succeeds (#826).
- Gemini: locate Homebrew-installed CLI bundles and parse bundled OAuth client constants so token refresh works with newer `gemini-cli` installs (#695).
- OpenRouter: keep the menu bar rendering the usage meter instead of falling back to the provider logo when no key limit is configured (#854). Thanks @willytop8!
- DeepSeek: show balance as plain text instead of a misleading quota-style progress bar (#856). Thanks @jb381!
- Augment: report the real 1-minute keepalive check/min-refresh intervals in startup logs and docs (#434). Thanks @guglielmofonda!
- Website: refresh codex.bar with the current canonical domain, structured background, and updated social preview.

## 0.24 — 2026-05-06

### Providers & Usage
- Windsurf: add provider support with web-session usage fetching and local SQLite-cache fallback (#583). Thanks @Coooolfan!
- Codebuff: add provider support with credit balance tracking, weekly rate-limit usage, API-token settings, and `codebuff login` credential import (#837). Thanks @anandghegde!
- Copilot: add multi-account support with GitHub OAuth sign-in, account switching, and per-account usage cards (#637). Thanks @ajmccall!
- DeepSeek: add provider support with token-account balance tracking, paid vs. granted credit breakdown, and CLI support (#811). Thanks @willytop8!
- Storage: add an opt-in menu view for local provider storage usage with background scans and copyable path breakdowns (#829). Thanks @fatiheminoge!
- OpenRouter and DeepSeek: show remaining account balances in the menu bar, while preserving OpenRouter's API-key limit metric when explicitly selected (#832). Thanks @giuseppebisemi!
- Claude: add a peak-hours menu-card indicator with countdowns and a provider setting to hide it (#611). Thanks @hello-amed!
- Cost history: show per-model cost details as a compact vertical list when hovering daily bars (#513). Thanks @iam-brain!
- Copilot: support GitHub Enterprise hosts for the device-flow login and usage API paths (#827). Thanks @ramzesenok!
- Alibaba: clarify China-region API-key failures when the console endpoint requires a browser session (#628). Thanks @XWind18!

### Fixes
- Codex: time out hung `codex app-server` RPC reads and cap loading animation runtime so stalled refreshes no longer keep the menu bar redrawing indefinitely (#842, #844). Thanks @hyspacex!
- Codex: make OpenAI dashboard refreshes handle non-English pages, lazy-loaded credits history, timeout retries, and unrelated Skillusage rows (#825). Thanks @xiaoqianWX!
- Cursor: show Enterprise/Team usage from personal caps and shared pools instead of reporting 100% remaining (#813). Thanks @fcamus00!
- Codex: keep same-workspace managed accounts distinct by matching workspace identity with email, so different OpenAI users in one workspace no longer overwrite each other (#796). Thanks @leezhuuuuu!
- Claude: enable Claude and switch to OAuth after a successful login, clear stale selected-provider state when Claude is disabled, and tolerate OAuth payloads that omit the five-hour window (#816, #726). Thanks @pdurlej and @Brandawg93!
- Claude: recognize OAuth `subscriptionType` before `rateLimitTier` so Pro accounts with generic Claude Code tiers
  open the subscription usage dashboard correctly (#836, fixes #824). Thanks @shixy96!
- Usage: preserve known reset countdowns when a refresh returns current usage without reset metadata (#427). Thanks @Whoaa512!
- Menu: refresh open usage cards after live data changes so the “Updated” timestamp advances after manual or cadence refreshes (#715). Thanks @cooper-matt!
- Menu: make the global open-menu shortcut behave as a true toggle when the menu is already open, avoiding queued reopens after repeated key presses (#218).
- Menu bar: preserve existing status items and assign stable autosave names so provider icon positions survive provider toggles (#538). Thanks @hxy91819!
- Settings: make the Preferences window 10% wider and taller so dense provider/settings panes have more breathing room.
- CLI releases: publish macOS arm64 and x86_64 CLI tarballs alongside Linux artifacts, with release-workflow smoke tests and docs (#457, #839). Thanks @androidshu and @mondary!
- CLI: query only enabled providers by default when three or more providers are enabled instead of expanding to every registered provider (#830). Thanks @lhoBas!
- CLI: read MiniMax coding-plan tokens from `MINIMAX_CODING_API_KEY`, accept Alibaba Qwen/DashScope API-key aliases, and avoid duplicate generic JSON error rows after provider failures.
- CLI discovery: prefer known install paths before interactive shell probing so common Claude installs no longer run shell init hooks during binary detection (#775).
- CLI lookup: drain login-shell probe output and terminate spawned process groups so interactive shell helpers cannot leak after path detection (#822, fixes #821). Thanks @LPFchan!
- OpenCode Go: open the workspace-specific usage dashboard when a workspace ID is configured (#667). Thanks @RizaSatya!
- Augment: use the API-provided credits limit when available instead of reconstructing the limit from consumed plus remaining credits (#338). Thanks @bcharleson!
- MiniMax: ignore login strings embedded in scripts when checking web-session pages for signed-out state (#508). Thanks @qipihen!
- Accounts: refresh the selected provider data and open menu after switching token accounts, even while a menu-open refresh is running (#799, fixes #798). Thanks @Zeko369!
- Codex: prefer session turn-context model metadata when calculating local cost history so GPT-5.4 sessions are not bucketed as GPT-5 (#620). Thanks @betive37!
- Codex: stop falling back from app-server RPC to bare CLI TUI during automatic usage refreshes, preventing unexpected OpenAI auth browser tabs.
- Menu/keychain: block delayed test-time menu mutations after teardown and enforce no-UI keychain reads more reliably (#381). Thanks @artuskg!
- Menu bar: fix invisible status item icon on macOS 26.4 by removing remaining RenderBox-triggering SwiftUI compositing modifiers from `UsageProgressBar` (rewritten as a single Canvas) and eliminating ~28 redundant Keychain reads on every launch after the first-run migration (#805). Thanks @willytop8!

## 0.23 — 2026-04-26

### Highlights
- Mistral: add provider support with monthly spend tracking, browser-cookie import, manual cookies, and CLI/token-account support (#607). Thanks @welcoMattic!
- Claude: show Designs and Daily Routines usage bars from live Claude OAuth/Web quota data, and restore the Web-mode Sonnet bar (#740). Thanks @AISupplyGuy!
- Cursor: add an Extra usage menu bar metric for on-demand budgets (#789). Thanks @huiye98!
- Usage: add an opt-in confetti celebration when weekly limits reset after active use (#785). Thanks @zats!
- Codex: add GPT-5.5 and GPT-5.5 Pro pricing so local cost scanning recognizes the new models.
- Copilot: show a clearer GitHub Device Flow hint in Settings when the copied device code needs to be pasted into GitHub (#369). Thanks @amoranio!

### Fixes
- Droid: preserve Factory session fallbacks, use the current usage endpoint, and clarify browser-login messaging (#792). Thanks @JosephDoUrden for the original stale-session fix!
- Widgets: package App Intents metadata for the widget extension and use configuration defaults so configurable widgets load correctly in WidgetKit (#783). Thanks @ngutman and @vincentyangch!
- Menu: keep merged-menu cards, switcher rows, wrapped status text, and hosted chart submenus aligned with the real AppKit menu width so menus no longer grow oversized or show narrower chart submenus after width changes. Thanks @ngutman!
- Codex: ignore invalid zero-minute subscription history so the utilization submenu no longer shows duplicate Session tabs.
- CLI: report the app bundle version correctly when the bundled helper is launched through a symlink.
- Codex/Claude: clean up cached CLI status probes during app shutdown so `codex -s read-only` workers are not orphaned after restart.

## 0.22 — 2026-04-21

### Highlights
- Codex: restore OpenAI web dashboard fetching on the new analytics route and tighten hidden WebView reuse/expiry.
- Synthetic: parse live quota payloads for five-hour, weekly, and search limits, including continuous reset/regeneration details (#732). Thanks @baanish!
- Antigravity: restore account/quota probing across newer localhost endpoint/token layouts and retry paths (#727). Thanks @icey-zhang!
- Menu: add standard shortcuts for Refresh, Settings, and Quit while the status menu is open (#737). Thanks @anirudhvee!
- Widgets: migrate app-group sharing to the Team-ID-prefixed container and carry widget state across the move (#701). Thanks @ngutman!

### Providers & Usage
- Synthetic: parse live five-hour, weekly, and search quota payloads, including continuous reset/regeneration details (#732). Thanks @baanish!
- Antigravity: restore localhost probing with async TLS challenge handling, extension-token fallback, and best-effort port selection (#727). Thanks @icey-zhang!
- Gemini: discover OAuth config in fnm/Homebrew/bundled CLI layouts so expired-token refresh keeps working (#723). Thanks @Leechael!
- Copilot: open the complete device-login verification URL when available so the browser flow carries the user code (#739). Thanks @skhe!
- Alibaba: update the China mainland Coding Plan endpoint and browser-cookie domain while keeping older domains as fallbacks (#712). Thanks @hezhongtang!
- Codex: restore OpenAI web dashboard fetching on the new analytics route and tighten hidden WebView reuse/expiry. @ratulsarna

### Menu & Settings
- Menu: show and handle standard shortcuts for Refresh (⌘R), Settings (⌘,), and Quit (⌘Q) while the status menu is open (#737). Thanks @anirudhvee!
- Settings: fix provider-sidebar clipping on macOS Tahoe and resize the Preferences window when switching tabs (#580). Thanks @chadneal!

### Fixes
- Keychain cache: preserve cached credentials when macOS temporarily denies keychain UI after wake, avoiding repeated prompts (#594). Thanks @josepe98!

## 0.21 — 2026-04-18

### Highlights
- Abacus AI: add a new provider for ChatLLM and RouteLLM credit tracking with browser-cookie import, manual-cookie support, and monthly pace rendering. Thanks @ChrisGVE!
- Codex: recognize the new Pro $100 plan in OAuth, OpenAI web, menu, and CLI rendering, and preserve CLI fallback when partial OAuth payloads lose the 5-hour session lane (#691, #709). Thanks @ImLukeF!
- Codex: make OpenAI web extras opt-in for fresh installs, preserve working legacy setups on upgrade, add an OpenAI web battery-saver toggle, and keep account-scoped dashboard state aligned during refreshes and account switches (#529). Thanks @cbrane!
- Codex: fix local cost scanner overcounting and cross-day undercounting across forked sessions, cold-cache refreshes, and sessions-root changes (#698). Thanks @xx205!
- z.ai: preserve weekly and 5-hour token quotas together, surface the 5-hour lane correctly across the menu/menu bar, and add regression coverage (#662). Thanks to @takumi3488 for the original fix and investigation.
- Cursor: fix a crash in the usage fetch path and add regression coverage (#663). Thanks @anirudhvee for the report and validation!
- Antigravity: restore account and quota probing across newer localhost endpoint/token layouts and API-level retry failures (#693, fixes #692). Thanks @anirudhvee!
- Menu bar: fix missing icons on affected macOS 26 systems by avoiding RenderBox-triggering SwiftUI effects (#677). Thanks @andrzejchm!
- Battery / refresh: cut menu redraw churn, skip background work for unavailable providers, and reuse cached OpenAI web views more efficiently (#708).
- Claude: add Opus 4.7 pricing so local cost scanning and cost breakdowns recognize the new model. Thanks @knivram!
- Codex: add Microsoft Edge as a browser-cookie import option for the Codex provider while preserving the contributor-branch workflow from the original PR (#694). Thanks @Astro-Han!

### Providers & Usage
- Abacus AI: add provider support for ChatLLM and RouteLLM monthly compute-credit tracking with cookie import, manual cookie headers, timeout/browser-detection threading, optional billing fallback, and hardened cached-session retry behavior. Thanks @ChrisGVE!
- Codex: render the new Pro $100 plan consistently across OAuth, OpenAI web, menu, and CLI surfaces, tolerate newer Codex OAuth payload variants like `prolite`, and only fall back to the CLI in auto mode when OAuth decode damage actually drops the session lane (#691, #709).
- Codex: make OpenAI web extras opt-in by default, preserve legacy implicit-auto cookie setups during upgrade inference, add battery-saver gating for non-forced dashboard refreshes, and preserve provider/dashboard state for enabled providers that are temporarily unavailable.
- Cost: tighten the local Codex cost scanner around fork inheritance, cold-cache discovery, incremental parsing, and sessions-root changes so replayed sessions no longer overcount or slip usage across day boundaries (#698). Thanks @xx205!
- z.ai: preserve both weekly and 5-hour token quotas, keep the existing 2-limit behavior unchanged, and render the 5-hour quota as a tertiary row in provider snapshots and CLI/menu cards (#662). Credit to @takumi3488 for the original fix and investigation.
- Cursor: fix the usage fetch path so failed or cancelled requests no longer crash, and add Linux build and regression test coverage fixes (#663).
- Antigravity: try both language-server and extension-server endpoint/token combinations, retry after API-level errors, scope insecure localhost trust handling to loopback hosts, and restore local quota/account probing on newer Antigravity builds (#693, fixes #692). Thanks @anirudhvee!
- Antigravity: prefer `userTier.name` over generic plan info when rendering the account plan so Google AI Ultra and similar tiers show their real subscription name, while still falling back cleanly when the tier label is absent or blank (#303). Thanks @zacklavin11!
- Ollama: recognize `__Secure-session` cookies during manual cookie entry and browser-cookie import so authenticated usage fetching continues to work with the newer cookie name (#707). Thanks @anirudhvee!
- OpenCode: enable weekly pace visualization for the app and CLI so weekly bars show reserve percentage, expected-usage markers, and "Lasts until reset" details like Codex and Claude (#639). Thanks @Zachary!
- Refresh pipeline: skip background work for unavailable providers, clear stale cached state, and show explicit unavailable messages (#708).
- Codex: support Microsoft Edge in browser-cookie import for the Codex provider while keeping the contributor branch untouched in the superseding integration path (#694). Thanks @Astro-Han!
- OpenCode / OpenCode Go: treat serialized `_server` auth/account-context failures as invalid credentials so cached browser cookies are cleared and retried instead of surfacing a misleading HTTP 500.
- OpenAI web: keep cached WebViews across same-account refreshes and clean them up only when accounts or providers go stale (#708).
- Claude: add Opus 4.7 pricing so local cost usage and breakdowns price the new model correctly. Thanks @knivram!
- Claude: broaden CLI binary lookup to native installer paths (#731). Thanks @dingtang2008!

### Menu & Settings
- Menu bar: fix missing icons on affected macOS 26 systems by replacing RenderBox-triggering material/offscreen SwiftUI effects in the provider sidebar and highlighted progress bar (#677). Thanks @andrzejchm!
- z.ai: fix menu bar selection when both weekly and 5-hour quotas are present (#662).
- Menu bar: avoid redundant merged-icon redraws and make hosted chart submenus load lazily without losing provider context (#708).
- Merged menu: when Overview is selected, keep the merged menu bar icon aligned with the first Overview provider in configured order, even while that provider is still loading (#724). Thanks @anirudhvee!
- Codex: add an OpenAI web battery-saver toggle, keep manual refresh available when battery saver is on, and hide OpenAI web submenus when web extras are disabled.

### Development & Tooling
- CLI / Debug: add user-facing browser-cookie cache clearing, including provider-scoped CLI clearing that removes managed Codex account cookie caches (#592, fixes #591). Thanks @coygeek!
- Diagnostics: add lightweight battery instrumentation for menu updates and refresh work (#708).
- Build script: make CodexBar-owned ad-hoc keychain cleanup opt-in with `--clear-adhoc-keychain`, and extend the explicit reset path to clear both `com.steipete.CodexBar` and `com.steipete.codexbar.cache`. Thanks @magnaprog!

## 0.20 — 2026-04-07

### Highlights
- Codex: switch between system accounts/profiles without manually logging out and back in. @ratulsarna
- Add Perplexity provider support with recurring, bonus, and purchased-credit tracking, Pro/Max plan detection, browser-cookie auto-import, and manual-cookie fallback (#449). Thanks @BeelixGit!
- Add OpenCode Go as a separate provider with 5-hour, weekly, and monthly web usage tracking, widget integration, and browser-cookie support.
- Claude: fix token and cost inflation caused by cross-file double counting of subagent JSONL logs, fix streaming chunk deduplication, and add `claude-sonnet-4-6` pricing. Thanks @enzonaute for the investigation!
- Cost history: include supported pi session usage in Codex/Claude provider history so provider charts reflect those local runs (#653). Thanks @ngutman!

### Providers & Usage
- Perplexity: add recurring, bonus, and purchased-credit tracking; plan detection for Pro/Max; browser-cookie auto-import; and manual-cookie fallback (#449). Thanks @BeelixGit!
- OpenCode Go: add a dedicated provider, parse live authenticated workspace Go usage from the web app, keep monthly optional and honor workspace env overrides.
- Codex: add workspace attribution for account labels and same-email multi-workspace accounts.
- Codex: reconcile live-system and managed accounts by canonical identity, preserve account-scoped usage/history/dashboard state, allow OAuth CLI fallback, and tighten OpenAI web ownership gating so quota and credits only attach to the matching account. Thanks @monterrr and @Rag30 for the initial effort and ideas!
- Codex: normalize weekly-only rate limits across OAuth and CLI/RPC so free-plan accounts render as Weekly instead of a fake Session, preserve unknown single-window payloads in the primary lane, hide the empty Session lane in widgets, and accept weekly-only Codex CLI `/status`/RPC data without failing. @ratulsarna
- Codex: refactor the provider end to end into clearer components and better division of responsibilities.
- OpenCode: preserve product separation between Zen and Go, improve null/unsupported usage handling, and harden cookie/domain behavior for authenticated web fetches.
- Cost history: merge supported pi session usage into Codex/Claude provider history (#653). Thanks @ngutman!

### Menu & Settings
- Codex: add UI for switching the system-level Codex account and promoting a managed account into the live system slot.
- Codex: hide display-only OpenAI web extras in widgets and fix buy-credits / credits-only presentation regressions.
- Claude: enable “Avoid Keychain prompts” by default, remove the experimental label, and preserve user-action cooldown clearing plus startup bootstrap when Security.framework fallback is still needed.
- Fix alignment of menu chart hover coordinates on macOS. Thanks @cuidong233!

## 0.19.0 — 2026-03-23
### Highlights
- Add Alibaba Coding Plan provider with region-aware quota fetching, widget integration, and browser-cookie import defaults (#574).
- Align Cursor usage with the dashboard's Total/Auto/API lanes. (#587). Thanks @Rag30!
- Add subscription utilization history chart to the menu with DST-safe data point identification (#589). Thanks @maxceem!
- Refactor the Claude provider end to end into clearer, better-tested components while preserving behavior (#494). @ratulsarna
- Add reset time display for Codex code review limits (#581). Thanks @Q1CHENL!
- Add per-model token counts to cost history (#546). Thanks @iam-brain!
- Fix Antigravity model selection to use stable model-family matching for Claude, Gemini Pro, and Gemini Flash, and preserve fallback lane visibility in the menu bar and icon (#590). Thanks @skainguyen1412!
- Add GPT-5.4 mini and nano pricing (#561). Thanks @iam-brain!

### Providers & Usage
- Alibaba: add Coding Plan provider support with region-aware web/API quota fetching, widget integration, and browser-cookie import defaults (#574).
- Cursor: trust dashboard percent fields for Total/Auto/API usage, preserve on-demand remaining fallback views, and keep scanning imported browser-cookie candidates until a working Cursor session is found (#587, supersedes #579). Thanks @Rag30!
- Claude: refactor the provider end to end into clearer components, with baseline docs and expanded tests to lock down behavior (#494).
- Codex: show reset times for code review limits, including Core review reset parsing support (#581). Thanks @Q1CHENL!
- Cost history: add per-model token counts so token usage is broken out by model (#546). Thanks @iam-brain!
- Antigravity: replace label-order guessing with stable model-family selection for Claude, Gemini Pro, and Gemini Flash; fix mapping for Claude thinking models and placeholder model IDs; preserve fallback lane visibility in the menu bar and icon when only fallback lanes exist (#590). Thanks @skainguyen1412!
- Kimi: tolerate API responses without `resetTime` so usage decoding no longer fails on sparse payloads.
- Codex: add GPT-5.4 mini and nano pricing (#561). Thanks @iam-brain!

### Menu & Settings
- Menu: add subscription utilization history chart with DST-safe chart point identifiers and per-provider plan utilization tracking (#589). Thanks @maxceem!
- Menu bar: in Both display mode, fall back to percent when pace data is unavailable so text stays visible for providers without pace metrics (#527). Thanks @Astro-Han!
- Settings: persist the resolved refresh cadence default to `UserDefaults` on first launch and repair invalid stored values so the setting stays normalized across relaunches (#519). Thanks @Astro-Han!
- Menu: wrap long status blurbs and preserve wrapped titles for multiline entries (#543). Thanks @zkforge!

## 0.18.0 — 2026-03-15
### Highlights
- Add Kilo provider support with API/CLI source modes, widget integration, and pass/credit handling (#454). Built on work by @coreh.
- Add Ollama provider, including token-account support in Settings and CLI (#380). Thanks @CryptoSageSnr!
- Add OpenRouter provider for credit-based usage tracking (#396). Thanks @chountalas!
- Add Codex historical pace with risk forecasting, backfill, and zero-usage-day handling (#482, supersedes #438). Thanks @tristanmanchester!
- Add a merged-menu Overview tab with configurable providers and row-to-provider navigation (#416). @ratulsarna
- Add an experimental option to suppress Claude Keychain prompts (#388).
- Reduce CPU/energy regressions and JSONL scanner overhead in Codex/web usage paths (#402, #392). Thanks @bald-ai and @asonawalla!

### Providers & Usage
- Codex: add historical pace risk forecasting and backfill, gate pace computation by display mode, and handle zero-usage days in historical data (#482, supersedes #438). Thanks @tristanmanchester!
- Kilo: add provider support with source-mode fallback, clearer credential/login guidance, auto top-up activity labeling, zero-balance credit handling, and pass parsing/menu rendering (#454). Thanks @coreh!
- Ollama: add provider support with token-account support in app/CLI, Chrome-default auto cookie import, and manual-cookie mode (#380). Thanks @CryptoSageSnr!
- OpenRouter: add provider support with credit tracking, key-quota popup support, token-account labels, fallback status icons, and updated icon/color (#396). Thanks @chountalas!
- Gemini: show separate Pro, Flash, and Flash Lite meters by splitting Gemini CLI quota buckets for `gemini-2.5-flash` and `gemini-2.5-flash-lite` (#496). Thanks @aladh
- Codex: in percent display mode with "show remaining," show remaining credits in the menu bar when session or weekly usage is exhausted (#336). Thanks @teron131!
- Claude: surface rate-limit errors from the CLI `/usage` probe with a user-friendly message, and harden "Failed to load usage data" matching against whitespace-collapsed output.
- Claude: restore weekly/Sonnet reset parsing from whitespace-collapsed CLI `/usage` output so reset times and pace details still appear after CLI fallback.
- Claude: fix extra-usage double conversion so OAuth/Web values stay on a single normalization path (#472, supersedes #463). Thanks @Priyans-hu!
- Claude: remove root-directory mtime short-circuiting in cost scanning so new session logs inside existing `~/.claude/projects/*` folders are discovered reliably (#462, fixes #411). Thanks @Priyans-hu!
- Copilot: harden free-plan quota parsing and fallback behavior by treating underdetermined values as unknown, preserving missing metadata as nil (#432, supersedes #393). Thanks @emanuelst!
- OpenCode: treat explicit `null` subscription responses as missing usage data, skip POST fallback, and return a clearer workspace-specific error (#412).
- OpenCode: surface clearer HTTP errors. Thanks @SalimBinYousuf1!
- Codex: preserve exact GPT-5 model IDs in local cost history, add GPT-5.4 pricing, and label zero-cost `gpt-5.3-codex-spark` sessions as "Research Preview" in cost breakdowns (#511). Thanks @iam-brain!
- Augment: prevent refresh stalls when `auggie account status` hangs by replacing unbounded CLI waits with timed subprocess execution and fallback handling (#481). Thanks @bryant24hao!
- Update Kiro parsing for `kiro-cli` 1.24+ / Q Developer formats and non-managed plan handling (#288). Thanks @kilhyeonjun!
- Kimi: in automatic metric mode, prioritize the 5-hour rate-limit window for menu bar and merged highest-usage calculations (#390). Thanks @ajaxjiang96!
- Browser cookie import: match Gecko `*.default*` profile directories case-insensitively so Firefox/Zen cookie detection works with uppercase `.Default` directories (#422). Thanks @bald-ai!
- MiniMax: make both Settings "Open Coding Plan" actions region-aware so China mainland selection opens `platform.minimaxi.com` instead of the global domain (#426, fixes #378). Thanks @bald-ai!
- Menu: rebuild the merged provider switcher when “Show usage as used” changes so switcher progress updates immediately (#306). Thanks @Flohhhhh!
- Warp: update API key setup guidance.
- Claude: update the "not installed" help link to the current Claude Code documentation URL (#431). Thanks @skebby11!
- Fix Claude setup message package name (#376). Thanks @daegwang!

### Menu & Settings
- Merged menu: keep Merge Icons, the switcher, and Overview tied to user-enabled providers even when some providers are temporarily unavailable, while defaulting menu content and icon state to an available provider when possible (#525). Thanks @Astro-Han!
- Merged menu: add an Overview switcher tab that shows up to three provider usage rows in provider order (#416).
- Settings: add "Overview tab providers" controls to choose/deselect Overview providers, with persisted selection reconciliation as enabled providers change (#416).
- Menu: hide contextual provider actions while Overview is selected and rebuild switcher state when overview availability changes (#416).

### Claude OAuth & Keychain
- Add an experimental Claude OAuth Security-CLI reader path and option in settings.
- Apply stored prompt mode and fallback policy to silent/noninteractive keychain probes.
- Add cooldown for background OAuth keychain retries.
- Disable experimental toggle when keychain access is disabled.
- Use a `claude-code/<version>` User-Agent for OAuth usage requests instead of a generic identifier.

### Performance & Reliability
- Codex/OpenAI web: reduce CPU and energy overhead by shortening failed CLI probe windows, capping web retry timeouts, and using adaptive idle blink scheduling (#402). Thanks @bald-ai!
- Cost usage scanner: optimize JSONL chunk parsing to avoid buffer-front removal overhead on large logs (#392). Thanks @asonawalla!
- TTY runner: fence shutdown registration to avoid launch/shutdown races, isolate process groups before shutdown rejection, and ensure lingering CLI descendants are cleaned up on app termination (#429). Thanks @uraimo!


## 0.18.0-beta.3 — 2026-02-13
### Highlights
- Claude OAuth/keychain flows were reworked across a series of follow-up PRs to reduce prompt storms, stabilize background behavior, surface a setting to control prompt policy and make failure modes deterministic (#245, #305, #308, #309, #364). Thanks @manikv12!
- Claude: harden Claude Code PTY capture for `/usage` and `/status` (prompt automation, safer command palette confirmation, partial UTF-8 handling, and parsing guards against status-bar context meters) (#320).
- New provider: Warp (credits + add-on credits) (#352). Thanks @Kathie-yu!
- Provider correctness fixes landed for Cursor plan parsing and MiniMax region routing (#240, #234, #344). Thanks @robinebers and @theglove44!
- Menu bar animation behavior was hardened in merged mode and fallback mode (#283, #291). Thanks @vignesh07 and @Ilakiancs!
- CI/tooling reliability improved via pinned lint tools, deterministic macOS test execution, and PTY timing test stabilization plus Node 24-ready GitHub Actions upgrades (#292, #312, #290).

### Claude OAuth & Keychain
- Claude OAuth creds are cached in CodexBar Keychain to reduce repeated prompts.
- Prompts can still appear when Claude OAuth credentials are expired, invalid, or missing and re-auth is required.
- In Auto mode, background refresh keeps prompts suppressed; interactive prompts are limited to user actions (menu open or manual refresh).
- OAuth-only mode remains strict (no silent Web/CLI fallback); Auto mode may do one delegated CLI refresh + one OAuth retry before falling back.
- Preferences now expose a Claude Keychain prompt policy (Never / Only on user action / Always allow prompts) under Providers → Claude; if global Keychain access is disabled in Advanced, this control remains visible but inactive.

### Provider & Usage Fixes
- Warp: add Warp provider support (credits + add-on credits), configurable via Settings or `WARP_API_KEY`/`WARP_TOKEN` (#352). Thanks @Kathie-yu!
- Cursor: compute usage against `plan.limit` rather than `breakdown.total` to avoid incorrect limit interpretation (#240). Thanks @robinebers!
- MiniMax: correct API region URL selection to route requests to the expected regional endpoint (#234). Thanks @theglove44!
- MiniMax: always show the API region picker and retry the China endpoint when the global host rejects the token to avoid upgrade regressions for users without a persisted region (#344). Thanks @apoorvdarshan!
- Claude: add Opus 4.6 pricing so token cost scanning tracks USD consumed correctly (#348). Thanks @arandaschimpf!
- z.ai: handle quota responses with missing token-limit fields, avoid incorrect used-percent calculations, and harden empty-response behavior with safer logging (#346). Thanks @MohamedMohana and @halilertekin!
- z.ai: fix provider visibility in the menu when enabled with token-account credentials (availability now considers the effective fetch environment).
- Amp: detect login redirects during usage fetch and fail fast when the session is invalid (#339). Thanks @JosephDoUrden!
- Resource loading: fix app bundle lookup path to avoid "could not load resource bundle" startup failures (#223). Thanks @validatedev!
- OpenAI Web dashboard: keep WebView instances cached for reuse to reduce repeated network fetch overhead; tests were updated to avoid network-dependent flakes (#284). Thanks @vignesh07!
- Token-account precedence: selected token account env injection now correctly overrides provider config `apiKey` values in app and CLI environments. Thanks @arvindcr4!
- Claude: make Claude CLI probing more resilient by scoping auto-input to the active subcommand and trimming to the latest Usage panel before parsing to avoid false matches from earlier screen fragments (#320).

### Menu Bar & UI Behavior
- Prevent fallback-provider loading animation loops (battery/CPU drain when no providers are enabled) (#283). Thanks @vignesh07!
- Prevent status overlay rendering for disabled providers while in merged mode (#291). Thanks @Ilakiancs!

### CI, Tooling & Test Stability
- Pin SwiftFormat/SwiftLint versions and harden lint installer behavior (version drift + temp-file leak fixes) (#292).
- Use more deterministic macOS CI test settings (including non-parallel paths where needed) and align runner/toolchain behavior for stability (#292).
- Stabilize PTY command timing tests to reduce CI flakiness (#312).
- Upgrade `actions/checkout` to v6 and `actions/github-script` to v8 for Node 24 compatibility in `upstream-monitor.yml` (#290). Thanks @salmanmkc!
- Tests: add TaskLocal-based keychain/cache overrides so keychain gating and KeychainCacheStore test stores do not leak across concurrent test execution (#320).

### Docs & Maintenance
- Update docs for Claude data fetch behavior and keychain troubleshooting notes.
- Update MIT license year.

## 0.18.0-beta.2 — 2026-01-21
### Highlights
- OpenAI web dashboard refresh cadence now follows 5× the base refresh interval.
- OpenAI web dashboard WebView is kept warm between scrapes to avoid repeated SPA downloads while idle CPU stays low (#284). Thanks @vignesh07!
- Menu bar: avoid fallback animation loop when all providers are disabled (#283). Thanks @vignesh07!
- Codex settings now include a toggle to disable OpenAI web extras.

### Providers
- Providers: add Dia browser support across cookie import and profile detection (#209). Thanks @validatedev!
- Codex: include archived session logs in local token cost scanning and dedupe by session id.
- Claude: harden CLI /usage parsing and avoid ANTHROPIC_* env interference during probes.

### Menu & Menu Bar
- Menu: opening OpenAI web submenus triggers a refresh when the data is stale.
- Menu: fix usage line labels to honor “Show usage as used”.
- Debug: add a toggle to keep Codex/Claude CLI sessions alive between probes.
- Debug: add a button to reset CLI probe sessions.
- App icon: use the classic icon on macOS 15 and earlier while keeping Liquid Glass for macOS 26+ (#178). Thanks @zerone0x!

## 0.18.0-beta.1 — 2026-01-18
### Highlights
- New providers: OpenCode (web usage), Vertex AI, Kiro, Kimi, Kimi K2, Augment, Amp, Synthetic.
- Provider source controls: usage source pickers for Codex/Claude, manual cookie headers, cookie caching with source/timestamp.
- Menu bar upgrades: display mode picker (percent/pace/both), auto-select near limit, absolute reset times, pace summary line.
- CLI/config revamp: config-backed provider settings, JSON-only errors, config validate/dump.

### Providers
- OpenCode: add web usage provider with workspace override + Chrome-first cookie import (#188). Thanks @anthnykr!
- OpenCode: refresh provider logo (#190). Thanks @anthnykr!
- Vertex AI: add provider with quota-based usage from gcloud ADC. Thanks @bahag-chaurasiak!
- Vertex AI: token costs are shown via the Claude provider (same local logs).
- Vertex AI: harden quota usage parsing for edge-case responses.
- Kiro: add CLI-based usage provider via kiro-cli. Thanks @neror!
- Kiro: clean up provider wiring and show plan name in the menu.
- Kiro: harden CLI idle handling to avoid partial usage snapshots (#145). Thanks @chadneal!
- Kimi: add usage provider with cookie-based API token stored in Keychain (#146). Thanks @rehanchrl!
- Kimi K2: add API-key usage provider for credit totals (#147). Thanks @0-CYBERDYNE-SYSTEMS-0!
- Augment: add provider with browser-cookie usage tracking.
- Augment: prefer Auggie CLI usage with web fallback, plus session refresh + recovery tools (#142). Thanks @bcharleson!
- Amp: add provider with Amp Free usage tracking (#167). Thanks @duailibe!
- Synthetic: add API-key usage provider with quota snapshots (#171). Thanks @monotykamary!
- JetBrains AI: include IDEs missing quota files, expand custom paths, and add Android Studio base paths (#194). Thanks @steipete!
- JetBrains AI: detect IDE directories case-insensitively (#200). Thanks @zerone0x!
- Cursor: support legacy request-based plans and show individual on-demand usage (#125) — thanks @vltansky
- Cursor: avoid Intel crash when opening login and harden WebKit teardown. Thanks @meghanto!
- Cursor: load stored session cookies before reads to make relaunches deterministic.
- z.ai: add BigModel CN region option for API endpoint selection (#140). Thanks @nailuoGG!
- MiniMax: add China mainland region option + host overrides (#143). Thanks @nailuoGG!
- MiniMax: support API token or cookie auth; API token takes precedence and hides cookie UI (#149). Thanks @aonsyed!
- Gemini: prefer loadCodeAssist project IDs for quota fetches (#172). Thanks @lolwierd!
- Gemini: honor loadCodeAssist project IDs for quota + support Nix CLI layout (#184). Thanks @HaukeSchnau!
- Claude: fix OAuth “Extra usage” spend/limit units when the API returns minor currency units (#97).
- Claude: rescale extra usage costs when plan hints are missing and prefer web plan hints for extras (#181). Thanks @jorda0mega!
- Usage formatting: fix currency parsing/formatting on non-US locales (e.g., pt-BR). Thanks @mneves75!

### Provider Sources & Security
- Providers: cache browser cookies in Keychain (per provider) and show cached source/time in settings.
- Codex/Claude/Cursor/Factory/MiniMax: cookie sources now include Manual (paste a Cookie header) in addition to Automatic.
- Codex/Claude/Cursor/Factory/MiniMax: skip cookie imports from browsers without usable cookie stores (profile/cookie DB) to avoid unnecessary Keychain prompts.
- Providers: suppress repeated Chromium Keychain prompts after access denied and honor disabled Keychain access.

### Preferences & Settings
- Preferences: swap provider refresh button and enable toggle order.
- Preferences: animate settings width and widen Providers on selection.
- Preferences: shrink default settings size and reduce overall height.
- Preferences: move “Hide personal information” to Advanced.
- Providers: shorten fetch subtitle to relative time only.
- Preferences: soften provider sidebar background and stabilize drag reordering.
- Preferences: restrict provider drag handle to handle-only.
- Preferences: move provider refresh timing to a dedicated second line.
- Preferences: tighten provider usage metrics spacing.
- Preferences: show refresh timing inline in provider detail subtitle.
- Preferences: move “Access OpenAI via web” into Providers → Codex.
- Preferences: add usage source pickers for Codex + Claude with auto fallback.
- Preferences: add cookie source pickers with contextual helper text for the selected mode.
- Preferences: move “Disable Keychain access” to Advanced and require manual cookies when enabled.
- Preferences: add per-provider menu bar metric picker (#185) — thanks @HaukeSchnau
- Preferences: tighten provider rows (inline pickers, compact layout, inline refresh + auto-source status).
- Preferences: remove the “experimental” label from Antigravity.

### Menu & Menu Bar
- Menu: add a toggle to show reset times as absolute clock values (instead of countdowns).
- Menu: show an “Open Terminal” action when Claude OAuth fails.
- Menu: add “Hide personal information” toggle and redact emails in menu UI (#137). Thanks @t3dotgg!
- Menu: keep a pace summary line alongside the visual marker (#155). Thanks @antons!
- Menu: reduce provider-switch flicker and avoid redundant menu card sizing for faster opens (#132). Thanks @ibehnam!
- Menu: keep background refresh on open without forcing token usage (#158). Thanks @weequan93!
- Menu: Cursor switcher shows On-Demand remaining when Plan is exhausted in show-remaining mode (#193). Thanks @vltansky!
- Menu: avoid single-letter wraps in provider switcher titles.
- Menu: widen provider switcher buttons to avoid clipped titles.
- Menu bar: rebuild provider status items on reorder so icons update correctly.
- Menu bar: optional auto-select provider closest to its rate limit and keep switcher progress visible (#159). Thanks @phillco!
- Menu bar: add display mode picker for percent/pace/both in the menu bar icon (#169). Thanks @PhilETaylor!
- Menu bar: fix combined loading indicator flicker during loading animation (incl. debug replay).
- Menu bar: prevent blink updates from clobbering the loading animation.

### CLI & Config
- CLI: respect the reset time display setting.
- CLI: add pink accents, usage bars, and weekly pace lines to text output.
- CLI: add config-backed provider settings, `--json-only`, and `--source api` for key-based providers.
- CLI: add `config validate`/`config dump` commands and per-provider JSON error payloads.
- CLI/App: move provider secrets + ordering to `~/.codexbar/config.json` (no Keychain persistence).
- Providers: resolve API tokens from config/env only (no Keychain fallback).

### Dev & Tests
- Dev: move Chromium profile discovery into SweetCookieKit (adds Helium net.imput.helium). Thanks @hhushhas!
- Dev: bump SweetCookieKit to 0.2.0.
- Dev: migrate stored Keychain items to reduce rebuild prompts.
- Dev: move path debug snapshot off the main thread and debounce refreshes to avoid startup hitches (#131). Thanks @ibehnam!
- Tests: expand Kiro CLI coverage.
- Tests: stabilize Claude PTY integration cleanup and reset CLI sessions after probes.
- Tests: kill leaked codex app-server after tests.
- Tests: add regression coverage for merged loading icon layout stability.
- Tests: cover config validation and JSON-only CLI errors.
- Build: stabilize Swift test runtime.

## 0.17.0 — 2025-12-31
- New providers: MiniMax.
- Keychain: show a preflight explanation before macOS prompts for OAuth tokens or cookie decryption.
- Providers: defer z.ai + Copilot Keychain reads until the user interacts with the token field.
- Menu bar: avoid status item menu reattachment and layout flips during refresh to reduce icon flicker.
- Dev: align SweetCookieKit local-storage tests with Swift Testing.
- Charts: align hover selection bands with visible bars in credits + usage breakdown history.
- About: fix website link in the About panel. Thanks @felipeorlando!

## 0.16.1 — 2025-12-29
- Menu: reduce layout thrash when opening menus and sizing charts. Thanks @ibehnam!
- Packaging: default release notarization builds universal (arm64 + x86_64) zip.
- OpenAI web: reduce idle CPU by suspending cached WebViews when not scraping. Thanks @douglascamata!
- Icons: switch provider brand icons to SVGs for sharper rendering. Thanks @vandamd!

## 0.16.0 — 2025-12-29
- Menu bar: optional “percent mode” (provider brand icons + percentage labels) via Advanced toggle.
- CLI: add `codexbar cost` to print local cost usage (text/JSON) for Codex + Claude.
- Cost: align local cost scanner with ccusage; stabilize parsing/decoding and handle large JSONL lines.
- Claude: skip pricing for unknown models (tokens still tracked) to avoid hard-coded legacy prices.
- Performance: reduce menu bar CPU usage by caching morph icons, skipping redundant status-item updates, and caching provider enablement/order during animations.
- Menu: improve provider switcher hover contrast in light mode.
- Icons: refresh Droid + Claude brand assets to better match menu sizing.
- CI: avoid interactive login-shell probes to reduce noisy “CLI missing” errors.

## 0.15.3 — 2025-12-28
- Codex: default to OAuth usage API (ChatGPT backend) with CLI-only override in Debug.
- Codex: map OAuth credits balance directly, avoiding web fallback for credits.
- Preferences: add optional “Access OpenAI via web” toggle and show blended source labels when web extras are active.
- Copilot: replace blocking auth wait dialog with a non-modal sheet to avoid stuck login.

## 0.15.2 — 2025-12-28
- Copilot: fix device-flow waiting modal to close reliably after auth (and avoid stuck waits).
- Packaging: include the KeyboardShortcuts resource bundle to prevent Settings → Keyboard shortcut crashes in packaged builds.

## 0.15.1 — 2025-12-28
- Preferences: fix provider API key fields reusing the wrong input when switching rows.
- Preferences: avoid Advanced tab crash when opening settings.

## 0.15.0 — 2025-12-28
- New providers: Droid (Factory), Cursor, z.ai, Copilot.
- macOS: CodexBar now supports Intel Macs (x86_64 builds + Sonoma fallbacks). Thanks @epoyraz!
- Droid (Factory): new provider with Standard + Premium usage via browser cookies, plus dashboard + status links. Thanks @shashank-factory!
- Menu: allow multi-line error messages in the provider subtitle (up to 4 lines).
- Menu: fix subtitle sizing for multi-line error states.
- Menu: avoid clipping on multi-line error subtitles.
- Menu: widen the menu card when 7+ providers are enabled.
- Providers: Codex, Claude Code, Cursor, Gemini, Antigravity, z.ai.
- Gemini: switch plan detection to loadCodeAssist tier lookup (Paid/Workspace/Free/Legacy). Thanks @381181295!
- Codex: OpenAI web dashboard is now the primary source for usage + credits; CLI fallback only when no matching cookies exist.
- Claude: prefer OAuth when credentials exist; fall back to web cookies or CLI (thanks @ibehnam).
- CLI: replace `--web`/`--claude-source` with `--source` (auto/web/cli/oauth); auto falls back only when cookies are missing.
- Homebrew: cask now installs the `codexbar` CLI symlink. Thanks @dalisoft!
- Cursor: add new usage provider with browser cookie auth (cursor.com + cursor.sh), on-demand bar support, and dashboard access.
- Cursor: keep stored sessions on transient failures; clear only on invalid auth.
- z.ai: new provider support with Tokens + MCP usage bars and MCP details submenu; API token now lives in Preferences (stored in Keychain); usage bars respect the show-used toggle. Thanks @uwe-schwarz for the initial work!
- Copilot: new GitHub Copilot provider with device flow login plus Premium + Chat usage bars (including CLI support). Thanks @roshan-c!
- Preferences: fix Advanced Display checkboxes and move the Quit button to the bottom of General.
- Preferences: hide “Augment Claude via web” unless Claude usage source is CLI; rename the cost toggle to “Show cost summary”.
- Preferences: add an Advanced toggle to show/hide optional Codex Credits + Claude Extra usage sections (on by default).
- Widgets: add a new “CodexBar Switcher” widget that lets you switch providers and remember the selection.
- Menu: provider switcher now uses crisp brand icons with equal-width segments and a per-provider usage indicator.
- Menu: tighten provider switcher sizing and increase spacing between label and weekly indicator bar.
- Menu: provider switcher no longer forces a wider menu when many providers are enabled; segments clamp to the menu width.
- Menu: provider switcher now aligns to the same horizontal padding grid as the menu cards when space allows.
- Dev: `compile_and_run.sh` now force-kills old instances to avoid launching duplicates.
- Dev: `compile_and_run.sh` now waits for slow launches (polling for the process).
- Dev: `compile_and_run.sh` now launches a single app instance (no more extra windows).
- CI: build/test Linux `CodexBarCLI` (x86_64 + aarch64) and publish release assets as `CodexBarCLI-<tag>-linux-<arch>.tar.gz` (+ `.sha256`).
- CLI: add alias fallback for Codex/Claude detection when PATH lookups fail.
- Providers: support Arc browser cookies for Factory/Droid (and other Chromium-based cookie imports).
- Providers: support ChatGPT Atlas browser data for Chromium cookie imports.
- Providers: accept Auth.js secure session cookies for Factory/Droid login detection.
- Providers: accept Factory auth session cookies (session/access-token) for Droid.
- Droid: surface Factory API errors instead of masking them as missing sessions.
- Droid: retry auth without access-token cookies when Factory flags a stale token.
- Droid: try all detected browser profiles before giving up.
- Droid: fall back to auth.factory.ai endpoints when cookies live on the auth host.
- Droid: use WorkOS refresh tokens from browser local storage when cookies fail.
- Droid: read WorkOS refresh tokens from Safari local storage.
- Droid: try stored/WorkOS tokens before Chrome cookies to reduce Chrome Safe Storage prompts.
- Menu: provider switcher bars now track primary quotas (Plan/Tokens/Pro), with Premium shown for Droid.
- Menu: avoid duplicate summary blocks when a provider has no action rows.
- OpenAI web: ignore cookie sets without session tokens to avoid false-positive dashboard fetches.
- Providers: hide z.ai in the menu until an API key is set.
- Menu: refresh runs automatically when opening the menu with a short retry (refresh row removed).
- Menu: hide the Status Page row when a provider has no status URL.
- Menu: align switcher bar with the “show usage as used” toggle.
- Antigravity: fix lsof port filtering by ANDing listen + pid conditions. Thanks @shaw-baobao!
- Claude: default to Claude Code OAuth usage API (credentials from Keychain or `~/.claude/.credentials.json`), with Debug selector + `--claude-source` CLI override (OAuth/Web/CLI).
- OpenAI web: allow importing any signed-in browser session when Codex email is unknown (first-run friendly).
- Core: Linux CLI builds now compile (mac-only WebKit/logging gated; FoundationNetworking imports where needed).
- Core: fix CI flake for Claude trust prompts by making PTY writes fully reliable.
- Core: Cursor provider is macOS-only (Linux CLI builds stub it).
- Core: make `RateWindow` equatable (used by OpenAI dashboard snapshots and tests).
- Tests: cover alias fallback resolution for Codex/Claude and add Linux platform gating coverage (run in CI).
- Tests: cover hiding Codex Credits + Claude Extra usage via the Advanced toggle.
- Docs: expand CLI docs for Linux install + flags.

## 0.14.0 — 2025-12-25
- New providers: Antigravity.
- Antigravity: new local provider for the Antigravity language server (Claude + Gemini quotas) with an experimental toggle; improved plan display + debug output; clearer not-running/port errors; hide account switch.
- Status: poll Google Workspace incidents for Gemini + Antigravity; Status Page opens the Workspace status page.
- Settings: add Providers tab; move ccusage + status toggles to General; keep display controls in Advanced.
- Menu/UI: widen the menu for four providers; cards/charts adapt to menu width; tighten provider switcher/toggle spacing; keep menus refreshed while open.
- Gemini: hide the dashboard action when unsupported.
- Claude: fix Extra usage spend/limit units (cents); improve CLI probe stability; surface web session info in Debug.
- OpenAI web: fix dashboard ghost overlay on desktop (WebKit keepalive window).
- Debug: add a debug-lldb build mode for troubleshooting.

## 0.13.0 — 2025-12-24
- Claude: add optional web-first usage via Safari/Chrome cookies (no CLI fallback) including “Extra usage” budget bar.
- Claude: web identity now uses `/api/account` for email + plan (via rate_limit_tier).
- Settings: standardize “Augment … via web” copy for Codex + Claude web cookie features.
- Debug: Claude dump now shows web strategy, cookie discovery, HTTP status codes, and parsed summary.
- Dev: add Claude web probe CLI to enumerate endpoints/fields using browser cookies.
- Tests: add unit coverage for Claude web API usage, overage, and account parsing.
- Menu: custom menu items now use the native selection highlight color (plus matching selection text/track colors).
- Charts: boost hover highlight contrast for credits/usage history bands.
- Menu: reorder Codex blocks to show credits before cost.
- Menu: split Claude “Extra usage” (no submenu) from “Cost” (history submenu) and trim redundant extra-usage subtext.

## 0.12.0 — 2025-12-23
- Widgets: add WidgetKit extension backed by a shared app‑group usage snapshot.
- New local cost usage tracking (Codex + Claude) via a lightweight scanner — inspired by ccusage (MIT). Computes cost from local JSONL logs without Node CLIs. Thanks @ryoppippi!
- Cost summary now includes last‑30‑days tokens; weekly pace indicators (with runout copy) hide when usage is fully depleted. Thanks @Remedy92!
- Claude: PTY probes now stop after idle, auto‑clean on restart, and run under a watchdog to avoid runaway CLI processes.
- Menu polish: group history under card sections, simplify history labels, and refresh menus live while open.
- Performance: faster usage log scanning + cost parsing; cache menu icons and speed up OpenAI dashboard parsing.
- Sparkle: auto-download updates when auto-check is enabled, and only show the restart menu entry once an update is ready.
- Widgets: experimental WidgetKit extension (may require restarting the widget gallery/Dock to appear).
- Credits: show credits as a progress bar and add a credits history chart when OpenAI web data is available.
- Credits: move “Buy Credits…” into its own menu item and improve auto-start checkout flow.

## 0.11.2 — 2025-12-21
- ccusage-codex cost fetch is faster and more reliable by limiting the session scan window.
- Fix ccusage cost fetch hanging for large Codex histories by draining subprocess output while commands run.
- Fix merged-icon loading animation when another provider is fetching (only the selected provider animates).
- CLI PATH capture now uses an interactive login shell and merges with the app PATH, fixing missing Node/Codex/Claude/Gemini resolution for NVM-style installs.

## 0.11.1 — 2025-12-21
- Gemini OAuth token refresh now supports Bun/npm installations. Thanks @ben-vargas!

## 0.11.0 — 2025-12-21
- New optional cost display in the menu (session + last 30 days), powered by ccusage. Thanks @Xuanwo!
- Fix loading-state card spacing to avoid double separators.

## 0.10.0 — 2025-12-20
- Gemini provider support (usage, plan detection, login flow). Thanks @381181295!
- Unified menu bar icon mode with a provider switcher and Merge Icons toggle (default on when multiple providers are enabled). Thanks @ibehnam!
- Fix regression from 0.9.1 where CLI detection failed for some installs by restoring interactive login-shell PATH loading.

## 0.9.1 — 2025-12-19
- CLI resolution now uses the login shell PATH directly (no more heuristic path scanning), so Codex/Claude match your shell config reliably.

## 0.9.0 — 2025-12-19
- New optional OpenAI web access: reuses your signed-in Safari/Chrome session to show **Code review remaining**, **Usage breakdown**, and **Credits usage history** in the menu (no credentials stored).
- Credits still come from the Codex CLI; OpenAI web access is only used for the dashboard extras above.
- OpenAI web sessions auto-sync to the Codex CLI email, support multiple accounts, and reset/re-import cookies on account switches to avoid stale cross-account data.
- Fix Chrome cookie import (macOS 10): signed-in Chrome sessions are detected reliably (thanks @tobihagemann!).
- Usage breakdown submenu: compact chart with hover details for day/service totals.
- New “Show usage as used” toggle to invert progress bars (default remains “% left”, now in Advanced).
- Session (5-hour) reset now shows a relative countdown (“Resets in 3h 31m”) in the menu card for Codex and Claude.
- Claude: fix reset parsing so “Resets …” can’t be mis-attributed to the wrong window (session vs weekly).

## 0.8.1 — 2025-12-17
- Claude trust prompts (“Do you trust the files in this folder?”) are now auto-accepted during probes to prevent stuck refreshes. Thanks @tobihagemann!

## 0.8.0 — 2025-12-17
- CodexBar is now available via Homebrew: `brew install --cask steipete/tap/codexbar` (updates via `brew upgrade --cask steipete/tap/codexbar`).
- Added session quota notifications for the sliding 5-hour window (Codex + Claude): notifies when it hits 0% and when it’s available again, based only on observed refresh data (including startup when already depleted). Thanks @GKannanDev!

## 0.7.3 — 2025-12-17
- Claude Enterprise accounts whose Claude Code `/usage` panel only shows “Current session” no longer fail parsing; weekly usage is treated as unavailable (fixes #19).

## 0.7.2 — 2025-12-13
- Claude “Open Dashboard” now routes subscription accounts (Max/Pro/Ultra/Team) to the usage page instead of the API console billing page. Thanks @auroraflux!
- Codex/Claude binary resolution now detects mise/rtx installs (shims and newest installed tool version), fixing missing CLI detection for mise users. Thanks @philipp-spiess!
- Claude usage/status probes now auto-accept the first-run “Ready to code here?” permission prompt (when launched from Finder), preventing timeouts and parse errors. Thanks @alexissan!
- General preferences now surface full Codex/Claude fetch errors with one-click copy and expandable details, reducing first-run confusion when a CLI is missing.
- Polished the menu bar “critter” icons: Claude is now a crisper, blockier pixel crab, and Codex has punchier eyes with reduced blurring in SwiftUI/menu rendering.

## 0.7.1 — 2025-12-09
- Menu bar icons now render on a true 18 pt/2× backing with pixel-aligned bars and overlays for noticeably crisper edges.
- PTY runner now preserves the caller’s environment (HOME/TERM/bun installs) while enriching PATH, preventing Codex/Claude
  probes from failing when CLIs are installed via bun/nvm or need their auth/config paths.
- Added regression tests to lock in the enriched environment behavior.
- Fixed a first-launch crash on macOS 26 caused by the 1×1 keepalive window triggering endless constraint updates; the hidden
  window now uses a safe size and no longer spams SwiftUI state warnings.
- Menu action rows now ship with SF Symbol icons (refresh, dashboard, status, settings, about, quit, copy error) for clearer at-a-glance affordances.
- When the Codex CLI is missing, menu and CLI now surface an actionable install hint (`npm i -g @openai/codex` / bun) instead of a generic PATH error.
- Node manager (nvm/fnm) resolution corrected so codex/claude binaries — and their `node` — are found reliably even when installed via fnm aliases or nvm defaults. Thanks @aliceisjustplaying for surfacing the gaps.
- Login menu now shows phase-specific subtitles and disables interaction while running: “Requesting login…” while starting the CLI, then “Waiting in browser…” once the auth URL is printed; success still triggers the macOS notification.
- Login state is tracked per provider so Codex and Claude icons/menus no longer share the same in-flight status when switching accounts.
- Claude login PTY runner detects the auth URL without clearing buffers, keeps the session alive until confirmation, and exposes a Sendable phase callback used by the menu.
- Claude CLI detection now includes Claude Code’s self-updating paths (`~/.claude/local/claude`, `~/.claude/bin/claude`) so PTY probes work even when only the bundled installer is used.

## 0.7.0 — 2025-12-07
- ✨ New rich menu card with inline progress bars and reset times for each provider, giving the menu a beautiful, at-a-glance dashboard feel (credit: Anton Sotkov @antons).

## 0.6.1 — 2025-12-07
- Claude CLI probes stop passing `--dangerously-skip-permissions`, aligning with the default permission prompt and avoiding hidden first-run failures.

## 0.6.0 — 2025-12-04
- New bundled CLI (`codexbar`) with single `usage` command, `--format text|json`, `--status`, and fast `-h/-V`.
- CLI output now shows consistent headers (`Codex 0.x.y (codex-cli)`, `Claude Code <ver> (claude)`) and JSON includes `source` + `status`.
- Advanced prefs install button symlinks `codexbar` into /usr/local/bin and /opt/homebrew/bin; docs refreshed.

## 0.5.7 — 2025-11-26
- Status Page and Usage Dashboard menu actions now honor the icon you click; Codex menus no longer open the Claude status site.

## 0.5.6 — 2025-11-25
- New playful “Surprise me” option adds occasional blinks/tilts/wiggles to the menu bar icons (one random effect at a time) plus a Debug “Blink now” trigger.
- Preferences now include an Advanced tab (refresh cadence, Surprise me toggle, Debug visibility); window height trimmed ~20% for a tighter fit.
- Motion timing eased and lengthened so blinks/wiggles feel smoother and less twitchy.

## 0.5.5 — 2025-11-25
- Claude usage scrape now recognizes the new “Current week (Sonnet only)” bar while keeping the legacy Opus label as a fallback.
- Menu and docs now label the Claude tertiary limit as Sonnet to match the latest CLI wording.
- PATH seeding now uses a deterministic binary locator plus a one-shot login-shell capture at startup (no globbed nvm paths); the Debug tab shows the resolved Codex binary and effective PATH layers.

## 0.5.4 — 2025-11-24
- Status blurb under “Status Page” no longer prefixes the text with “Status:”, keeping the incident description concise.
- PTY runner now registers cleanup before launch so both ends of the TTY and the process group are torn down even when `Process.run()` throws (no leaked fds when spawn fails).

## 0.5.3 — 2025-11-22
- Added a per-provider “Status Page” menu item beneath Usage that opens the provider’s live status page (OpenAI or Claude).
- Status API now refreshes alongside usage; incident states show a dot/! overlay on the status icon plus a status blurb under the menu item.
- General preferences now include a default-on “Check provider status” toggle above refresh cadence.

## 0.5.2 — 2025-11-22
- Release packaging now includes uploading the dSYM archive alongside the app zip to aid crash symbolication (policy documented in the shared mac release guide).
- Claude PTY fallback removed: Claude probes now rely solely on `script` stdout parsing, and the generic TTY runner is trimmed to Codex `/status` handling.
- Fixed a busy-loop on the codex RPC stderr pipe (handler now detaches on EOF), eliminating the long-running high-CPU spin reported in issue #9.

## 0.5.1 — 2025-11-22
- Debug pane now exposes the Claude parse dump toggle, keeping the captured raw scrape in memory for inspection.
- Claude About/debug views embed the current git hash so builds can be identified precisely.
- Minor runtime robustness tweaks in the PTY runner and usage fetcher.

## 0.5.0 — 2025-11-22
- Codex usage/credits now use the codex app-server RPC by default (with PTY `/status` fallback when RPC is unavailable), reducing flakiness and speeding refreshes.
- Codex CLI launches seed PATH with Homebrew/bun/npm/nvm/fnm defaults to avoid ENOENT in hardened/release builds; TTY probes reuse the same PATH.
- Claude CLI probe now runs `/usage` and `/status` in parallel (no simulated typing), captures reset strings, and uses a resilient parser (label-first with ordered fallback) while keeping org/email separate by provider.
- TTY runner now always tears down the spawned process group (even on early Claude login prompts) to avoid leaking CLI processes.
- Default refresh cadence is now 5 minutes, and a 15-minute option was added to the settings picker.
- Claude probes/version detection now start with `--allowed-tools ""` (tool access disabled) while keeping interactive PTY mode working.
- Codex probes and version detection now launch the CLI with `-s read-only -a untrusted` to keep PTY runs sandboxed.
- Codex warm-up screens (“data not available yet”) are handled gracefully: cached credits stay visible and the menu skips the scary parse error.
- Codex reset times are shown for both RPC and TTY fallback, and plan labels are capitalized while emails stay verbatim.

## 0.4.3 — 2025-11-21
- Fix status item creation timing on macOS 15 by deferring NSStatusItem setup to after launch; adds a regression test for the path.
- Menu bar icon with unknown usage now draws empty tracks (instead of a full bar when decorations are shown) by treating nil values as 0%.

## 0.4.2 — 2025-11-21
- Sparkle updates re-enabled in release builds (disabled only for the debug bundle ID).

## 0.4.1 — 2025-11-21
- Both Codex and Claude probes now run off the main thread (background PTY), avoiding menu/UI stalls during `/status` or `/usage` fetches.
- Codex credits stay available even when `/status` times out: cached values are kept and errors are surfaced separately.
- Claude/Codex provider autodetect runs on first launch (defaults to Codex if neither is installed) with a debug reset button.
- Sparkle updates re-enabled in release builds (disabled only for debug bundle ID).
- Claude probe now issues the `/usage` slash command directly to land on the Usage tab reliably and avoid palette misfires.

## 0.4.0 — 2025-11-21
- Claude Code support: dedicated Claude menu/icon plus dual-wired menus when both providers are enabled; shows email/org/plan and Sonnet usage with clickable errors.
- New Preferences window: General/About tabs with provider toggles, refresh cadence, start-at-login, and always-on Quit.
- Codex credits without web login: we now read `codex /status` in a PTY, auto-skip the update prompt, and parse session/weekly/credits; cached credits stay visible on transient timeouts.
- Resilience: longer PTY timeouts, cached-credit fallback, one-line menu errors, and clearer parse/update messages.

## 0.3.0 — 2025-11-18
- Credits support: reads Codex CLI `/status` via PTY (no browser login), shows remaining credits inline, and moves history to a submenu.
- Sign-in window with cookie reuse and a logout/clear-cookies action; waits out workspace picker and auto-navigates to usage page.
- Menu: credits line bolded; login prompt hides once credits load; debug toggle always visible (HTML dump).
- Icon: when weekly is empty, top bar becomes a thick credits bar (capped at 1k); otherwise bars stay 5h/weekly.

## 0.2.2 — 2025-11-17
- Menu bar icon stays static when no account/usage is present; loading animation only runs while fetching (12 fps) to keep idle CPU low.
- Usage refresh first tails the newest session log (512 KB window) before scanning everything, reducing IO on large Codex logs.
- Packaging/signing hardened: strip extended attributes, delete AppleDouble (`._*`) files, and re-sign Sparkle + app bundle to satisfy Gatekeeper.

## 0.2.1 — 2025-11-17
- Patch bump for refactor/relative-time changes; packaging scripts set to 0.2.1 (5).
- Streamlined Codex usage parsing: modern rate-limit handling, flexible reset time parsing, and account rate-limit updates (thanks @jazzyalex and https://jazzyalex.github.io/agent-sessions/).

## 0.2.0 — 2025-11-16
- CADisplayLink-based loading animations (macOS 15 displayLink API) with randomized patterns (Knight Rider, Cylon, outside-in, race, pulse) and debug replay cycling through all.
- Debug replay toggle (`defaults write com.steipete.codexbar debugMenuEnabled -bool YES`) to view every pattern.
- Usage Dashboard link in menu; menu layout tweaked.
- Updated time now shows relative formatting when fresher than 24h; refactored sources into smaller files for maintainability.
- Version bumped to 0.2.0 (4).

## 0.1.2 — 2025-11-16
- Animated loading icon (dual bars sweep until usage arrives); always uses rendered template icon.
- Sparkle embedding/signing fixed with deep+timestamp; notarization pipeline solid.
- Icon conversion scripted via ictool with docs.
- Menu: settings submenu, no GitHub item; About link clickable.

## 0.1.1 — 2025-11-16
- Launch-at-login toggle (SMAppService) and saved preference applied at startup.
- Sparkle auto-update wiring (SUFeedURL to GitHub, SUPublicEDKey set); Settings submenu with auto-update toggle + Check for Updates.
- Menu cleanup: settings grouped, GitHub menu removed, About link clickable.
- Usage parser scans newest session logs until it finds `token_count` events.
- Icon pipeline fixed: regenerated `.icns` via ictool with proper transparency (docs in docs/icon.md).
- Added lint/format configs, Swift Testing, strict concurrency, and usage parser tests.
- Notarized release build "CodexBar-0.1.0.zip" remains current artifact; app version 0.1.1.

## 0.1.0 — 2025-11-16
- Initial CodexBar release: macOS 15+ menu bar app, no Dock icon.
- Reads latest Codex CLI `token_count` events from session logs (5h + weekly usage, reset times); no extra login or browser scraping.
- Shows account email/plan decoded locally from `auth.json`.
- Horizontal dual-bar icon (top = 5h, bottom = weekly); dims on errors.
- Configurable refresh cadence, manual refresh, and About links.
- Async off-main log parsing for responsiveness; strict-concurrency build flags enabled.
- Packaging + signing/notarization scripts (arm64); build scripts convert `.icon` bundle to `.icns`.
