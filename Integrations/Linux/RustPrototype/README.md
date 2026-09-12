# Rust desktop prototype

An isolated feasibility experiment: Rust drives the existing CodexBar QML dashboard,
creates a dynamic system tray icon, and serves JSON snapshots over a Unix socket.
Everything displayed is synthetic. This does not invoke the CodexBar CLI, read
provider credentials, change desktop preferences, or install an Omarchy widget.

## Run

From this directory, with Rust/Cargo, a C++ compiler, qmake6 and the existing Linux
app's Qt dependencies installed:

```sh
QMAKE=qmake6 cargo build --locked
./target/debug/codexbar-rust-prototype
```

The window is titled **CodexBar Rust prototype — DEMO**. Refresh cycles the session
meter through 75%, 55%, 35% and 15%; the weekly meter stays at 42%. The tray updates
its two meters, warning color and tooltip from the same state. Left-click opens
Usage; middle-click refreshes. Its menu offers Usage, Refresh and Quit.

The default runtime directory is `$XDG_RUNTIME_DIR/codexbar-rust-prototype`, separate
from the installed C++ app. Alternatively pass `--runtime-dir /path/to/private-dir`;
its parent must exist, and an existing directory must be owned by you with mode 0700.
Use the same directory argument for clients. `--no-tray` runs the windows alone.

```sh
./target/debug/codexbar-rust-prototype --snapshot
./target/debug/codexbar-rust-prototype --refresh
./target/debug/codexbar-rust-prototype --usage
./target/debug/codexbar-rust-prototype --quit
```

Closing the window hides it. Quit exits the prototype and removes its socket.
Duplicate launches in the same runtime directory are rejected. Nothing is added
to login startup. This binary loads QML from its build-time worktree path; it is
not a relocatable release package.

## What this establishes

- CXX-Qt 0.10 exposes Rust state and methods to QML through generated bindings.
- The production `Dashboard.qml`, `UsageCard.qml`, `UsageChart.qml`, and shared
  `Usage.js` are reused through a small QML compatibility facade. ARM baseline screenshots
  exposed a Qt 6.4 plan-label layout issue; `UsageCard.qml` now anchors the plan
  beside the provider with a width capped at half the header. A rendered-geometry
  assertion catches the narrow-column regression.
- `ksni` 0.3.6 publishes a freedesktop StatusNotifierItem over D-Bus. Rust renders
  the ARGB meter pixels; no Qt Widgets tray wrapper is needed.
- Snapshot clients run before Qt initialization and work without a display.
- The prototype contains no handwritten C++ source. It still builds generated
  C++ and links Qt. One extra Qt static method, `QCoreApplication::exit`, is bound
  directly in the Rust bridge for explicit quit, which must bypass the dashboard's
  close-to-hide behavior.
- Explicit `cxx_qt::init_qml_module!` initialization is needed in this Cargo build.

## Validation

```sh
cargo fmt --check
QMAKE=qmake6 cargo clippy --locked --all-targets -- -D warnings
python3 tests/smoke.py
# On a desktop session with a running StatusNotifier host and busctl:
PROTOTYPE_TEST_TRAY=1 PROTOTYPE_QPA=wayland python3 tests/smoke.py
# X11 / XWayland:
PROTOTYPE_TEST_TRAY=1 PROTOTYPE_QPA=xcb python3 tests/smoke.py
```

The smoke test checks rendered QML meter labels before and after refresh, an image
capture, JSON snapshots, clients without a usable GUI platform, duplicate launch
rejection, malformed/oversized requests, and graceful shutdown/socket removal.
With tray testing enabled it additionally checks the exported D-Bus pixmap and
tooltip change and exercises activation. It never queries real providers.

Validated locally on x86_64 Omarchy, Qt 6.11.2 and Rust 1.98.1: Cargo build,
formatting, Clippy, offscreen rendering, native Wayland, XWayland and StatusNotifierItem.
The compiler emits upstream Qt/GCC header warnings and a CXX-Qt-selected gold
linker deprecation warning. These are distinct from Rust Clippy diagnostics.
Repository-wide `make test` and `make check` cannot complete here because `swift`
and macOS `plutil`, respectively, are unavailable.

## Native ARM CI

`.github/workflows/rust-linux-prototype.yml` builds on GitHub's native
`ubuntu-24.04-arm` and `ubuntu-24.04` runners. Both use the locked Cargo dependencies
and Rust 1.98.1. The job runs formatting, Clippy, offscreen smoke tests, and
`tests/desktop-session.sh`: a private D-Bus session, Xvfb, an Xfce Status Tray,
and a software-rendered Weston compositor nested in Xvfb. It tests X11 and Wayland clients against the
same real StatusNotifier host. The tray host lives on X11; this does not validate
an Omarchy/Quickshell or KDE/GNOME shell on ARM. Weston uses its X11 backend
to supply a virtual input seat; the seatless headless backend stalled Qt 6.4 startup.

[Native CI run 34679578167](https://github.com/steipete/CodexBar/actions/runs/34679578167)
passed on both architectures with Ubuntu 24.04, Qt 6.4.2 and Rust 1.98.1.
The ARM artifact identifies the executable as ELF ARM aarch64. Both jobs passed
build/Clippy and all three rendering/IPC modes, including tray updates and activation.

Each job uploads platform details, QML captures, a desktop screenshot, exported
tray pixels/tooltips, and application/compositor logs. Software rendering makes
these tests repeatable; GPU drivers and physical displays remain separate tests.

### Optional Crabbox run

Native GitHub Actions runners are the validation path for this experiment.
An additional cloud run is deferred and is not a prerequisite for continuing the
Rust migration. No cloud credentials are needed by the CI workflow.

For a disposable AWS Graviton run, install Crabbox v0.57.0 or newer and authenticate
1Password CLI. Copy `aws.env.example` to a private file, replacing its references
with your existing AWS item's vault/item/field names. Keep references rather than
credential values in that file. From this directory:

```sh
op run --env-file /absolute/path/to/aws-references.env -- bash tests/run-crabbox.sh
```

The wrapper requests exactly `c7g.xlarge`, ARM64, Ubuntu 24.04, On-Demand capacity,
a 40 GB disk and a 45-minute lease. The remote command has a 30-minute timeout;
`--stop-after always` requests cleanup on success or failure. It collects
`rust-evidence/*` as Crabbox artifacts. Region defaults to `us-east-1`; set
`CRABBOX_AWS_REGION` for an account's preferred region. Normal AWS charges apply.
Direct Crabbox uses the AWS SDK credential chain, so a separate AWS CLI install
is not required. The wrapper does not forward AWS keys to the test command.

The Crabbox wrapper has not completed a cloud run. The successful native ARM
result above comes from GitHub Actions; the wrapper is retained for optional
manual testing.

The remote script checks `uname -m` is `aarch64`, installs dependencies, builds
natively and runs the same suite as CI. Local scripts and workflow changes are
available on the experiment branch; this is not part of production releases.

## Remaining work before a migration

This is not a replacement for the released Linux app. Real provider execution,
timeouts/cancellation, settings persistence, spending, notifications, theme following,
account actions, clipboard and startup controls have not been ported. Settings and
clipboard actions show an explanatory dialog; Spending shows an empty disabled view.

The bridge currently transfers JSON and checks it on a 100 ms timer to keep this
experiment small. A production version should expose typed models and notify QML
when state changes, with backend work off the GUI thread. The existing JavaScript
normalization/notification rules need either retained Qt execution or a separately
tested Rust port. The current fixture is already normalized and does not test that
part of the migration.

KDE/GNOME sessions, Qt versions older than 6.4, release packaging, accessibility,
memory use and performance are not validated by this experiment.
Rust does not remove the Qt runtime requirement. `ksni` implements StatusNotifier;
legacy XEmbed tray support from Qt is not reproduced.

The next useful step is a fixture-backed real CLI runner with typed Rust state,
covered by the native x86_64/ARM64 CI matrix, before replacing the production controller.

References: [CXX-Qt](https://kdab.github.io/cxx-qt/book/),
[ksni](https://docs.rs/ksni/0.3.6/ksni/).
