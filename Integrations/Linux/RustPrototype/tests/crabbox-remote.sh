#!/usr/bin/env bash
# Runs only on the disposable Ubuntu ARM VM, from the synced repository root.
set -euo pipefail
[[ $(uname -m) == aarch64 ]] || { echo 'Expected native ARM64' >&2; exit 1; }
root_dir=$PWD
prototype_dir="$root_dir/Integrations/Linux/RustPrototype"
bash "$prototype_dir/tests/setup-ubuntu.sh"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=1.98.1
export QMAKE=qmake6
export CARGO_BUILD_JOBS=2
if ! command -v rustup >/dev/null; then
  installer=$(mktemp)
  trap 'rm -f -- "$installer"' EXIT
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$installer"
  sh "$installer" -y --profile minimal --default-toolchain "$RUSTUP_TOOLCHAIN" --no-modify-path
fi
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --component rustfmt --component clippy
export PROTOTYPE_EVIDENCE_DIR="$root_dir/rust-evidence"
mkdir -p "$PROTOTYPE_EVIDENCE_DIR"
{ uname -m; rustc --version; qmake6 -query QT_VERSION; ldd --version | head -1; } > "$PROTOTYPE_EVIDENCE_DIR/platform.txt"
cd "$prototype_dir"
cargo fmt --check
cargo build --locked
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
file target/debug/codexbar-rust-prototype >> "$PROTOTYPE_EVIDENCE_DIR/platform.txt"
python3 tests/smoke.py
python3 tests/test_omarchy.py
bash tests/desktop-session.sh
