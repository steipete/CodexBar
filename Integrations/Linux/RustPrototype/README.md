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
  `Usage.js` are reused without edits, through a small QML compatibility facade.
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

ARM64, the Ubuntu 24.04 release baseline, older Qt versions, KDE/GNOME sessions,
release packaging, accessibility, memory use and performance are not validated by this experiment.
Rust does not remove the Qt runtime requirement. `ksni` implements StatusNotifier;
legacy XEmbed tray support from Qt is not reproduced.

The next useful step is a fixture-backed real CLI runner with typed Rust state,
followed by native x86_64/ARM64 CI builds, before replacing the production controller.

References: [CXX-Qt](https://kdab.github.io/cxx-qt/book/),
[ksni](https://docs.rs/ksni/0.3.6/ksni/).
