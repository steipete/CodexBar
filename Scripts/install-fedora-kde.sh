#!/usr/bin/env bash
set -euo pipefail

readonly CODEXBAR_REPOSITORY="steipete/CodexBar"
readonly KDE_WIDGET_REPOSITORY="psimaker/codexbar-plasmoid"
readonly KDE_WIDGET_ID="com.github.psimaker.codexbar"
readonly DEFAULT_KDE_WIDGET_REF="4ab8e365b789243b12fe853a53f0987efd1d54af"
readonly script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly plasma_compatibility_patch="$script_dir/linux-kde/codexbar-plasmoid-plasma-6.6.patch"

mode="install"
install_cli=true
install_widget=true
add_to_panel=false
restart_plasma=true

usage() {
    cat <<'EOF'
Install CodexBar's Linux CLI and KDE Plasma 6 widget on Fedora.

Usage:
  ./Scripts/install-fedora-kde.sh [options]

Options:
  --check             Verify the current Fedora/KDE installation without changing it.
  --add-to-panel      Add the widget to the first Plasma panel after installation.
  --skip-cli          Do not install or update the CodexBar CLI.
  --skip-widget       Do not install or update the Plasma widget.
  --no-restart        Do not restart plasmashell after installing the widget.
  -h, --help          Show this help.

Environment:
  CODEXBAR_VERSION    Release tag to install, for example v0.43.0. Defaults to latest.
  CODEXBAR_KDE_REF    Widget git ref. Defaults to the tested pinned commit.
  CODEXBAR_BIN_DIR    CLI destination. Defaults to ~/.local/bin.
  CODEXBAR_LINUX_VARIANT
                      musl (default, static) or glibc.
EOF
}

log() {
    printf '[codexbar-kde] %s\n' "$*"
}

fail() {
    printf '[codexbar-kde] error: %s\n' "$*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

while (($# > 0)); do
    case "$1" in
        --check)
            mode="check"
            ;;
        --add-to-panel)
            add_to_panel=true
            ;;
        --skip-cli)
            install_cli=false
            ;;
        --skip-widget)
            install_widget=false
            ;;
        --no-restart)
            restart_plasma=false
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
    shift
done

readonly bin_dir="${CODEXBAR_BIN_DIR:-$HOME/.local/bin}"
readonly codexbar_path="$bin_dir/codexbar"
readonly widget_ref="${CODEXBAR_KDE_REF:-$DEFAULT_KDE_WIDGET_REF}"

require_fedora_kde() {
    [[ -r /etc/os-release ]] || fail "cannot identify the Linux distribution"

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "fedora" ]] || fail "this installer currently supports Fedora; detected ${ID:-unknown}"

    have kpackagetool6 || fail "kpackagetool6 is missing; install KDE Plasma 6"
    have plasmashell || fail "plasmashell is missing; install KDE Plasma 6"
    have curl || fail "curl is required"
    have patch || fail "patch is required"
    have tar || fail "tar is required"
    have sha256sum || fail "sha256sum is required"

    local plasma_version
    plasma_version="$(plasmashell --version 2>/dev/null | awk '{print $2}')"
    [[ "$plasma_version" == 6.* ]] || fail "Plasma 6 is required; detected ${plasma_version:-unknown}"
}

linux_asset_arch() {
    case "$(uname -m)" in
        x86_64 | amd64)
            printf 'x86_64\n'
            ;;
        aarch64 | arm64)
            printf 'aarch64\n'
            ;;
        *)
            fail "unsupported CPU architecture: $(uname -m)"
            ;;
    esac
}

latest_release_tag() {
    if [[ -n "${CODEXBAR_VERSION:-}" ]]; then
        printf '%s\n' "$CODEXBAR_VERSION"
        return
    fi

    if have gh && gh auth status >/dev/null 2>&1; then
        gh release view --repo "$CODEXBAR_REPOSITORY" --json tagName --jq .tagName
        return
    fi

    local effective_url
    effective_url="$(
        curl --fail --silent --show-error --location \
            --output /dev/null --write-out '%{url_effective}' \
            "https://github.com/$CODEXBAR_REPOSITORY/releases/latest"
    )"
    [[ "$effective_url" == */tag/* ]] || fail "could not resolve the latest CodexBar release"
    printf '%s\n' "${effective_url##*/}"
}

download_file() {
    local url="$1"
    local destination="$2"
    curl --fail --location --retry 3 --retry-delay 1 \
        --output "$destination" "$url"
}

verify_checksum() {
    local directory="$1"
    local checksum_file="$2"
    local asset_name="$3"

    (
        cd "$directory"
        local expected
        expected="$(awk '{print $1}' "$checksum_file")"
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail "invalid checksum file for $asset_name"
        printf '%s  %s\n' "$expected" "$asset_name" | sha256sum --check -
    )
}

install_codexbar_cli() {
    local work_dir="$1"
    local release_tag release_version arch variant asset_platform asset_name release_base

    release_tag="$(latest_release_tag)"
    release_version="${release_tag#v}"
    arch="$(linux_asset_arch)"
    variant="${CODEXBAR_LINUX_VARIANT:-musl}"
    case "$variant" in
        musl)
            asset_platform="linux-musl"
            ;;
        glibc)
            asset_platform="linux"
            ;;
        *)
            fail "CODEXBAR_LINUX_VARIANT must be musl or glibc"
            ;;
    esac
    asset_name="CodexBarCLI-v${release_version}-${asset_platform}-${arch}.tar.gz"
    release_base="https://github.com/$CODEXBAR_REPOSITORY/releases/download/$release_tag"

    log "downloading CodexBar CLI $release_tag for Linux $arch ($variant)"
    download_file "$release_base/$asset_name" "$work_dir/$asset_name"
    download_file "$release_base/$asset_name.sha256" "$work_dir/$asset_name.sha256"
    verify_checksum "$work_dir" "$asset_name.sha256" "$asset_name"

    mkdir -p "$work_dir/cli"
    tar -xzf "$work_dir/$asset_name" -C "$work_dir/cli"

    local binary
    binary="$(find "$work_dir/cli" -type f -name CodexBarCLI -print -quit)"
    [[ -n "$binary" ]] || fail "CodexBarCLI was not found in $asset_name"

    mkdir -p "$bin_dir"
    install -m 0755 "$binary" "$codexbar_path"

    local version_file
    version_file="$(find "$work_dir/cli" -type f -name VERSION -print -quit)"
    if [[ -n "$version_file" ]]; then
        install -m 0644 "$version_file" "$bin_dir/VERSION"
    fi

    log "installed $("$codexbar_path" --version) at $codexbar_path"
}

widget_is_installed() {
    kpackagetool6 -t Plasma/Applet --list 2>/dev/null | grep -Fq "$KDE_WIDGET_ID"
}

patch_widget_for_plasma_6_6() {
    local package_dir="$1"

    # Plasma 6.6 rejects JavaScript null/undefined values assigned to bool QML
    # properties. Coerce optional payload guards so empty provider data remains
    # a clean false instead of logging "Unable to assign [undefined] to bool".
    [[ -f "$plasma_compatibility_patch" ]] || fail "missing Plasma compatibility patch"
    patch --directory "$package_dir" --strip=1 --forward --silent \
        < "$plasma_compatibility_patch" \
        || fail "the Plasma compatibility patch does not apply to widget ref $widget_ref"
}

install_kde_widget() {
    local work_dir="$1"
    local archive="$work_dir/codexbar-plasmoid.tar.gz"
    local package_dir="$work_dir/codexbar-plasmoid"
    local archive_url="https://github.com/$KDE_WIDGET_REPOSITORY/archive/$widget_ref.tar.gz"

    log "downloading KDE Plasma widget at $widget_ref"
    download_file "$archive_url" "$archive"
    mkdir -p "$package_dir"
    tar -xzf "$archive" --strip-components=1 -C "$package_dir"

    [[ -f "$package_dir/metadata.json" ]] || fail "invalid Plasma widget archive"
    [[ -f "$package_dir/contents/ui/main.qml" ]] || fail "Plasma widget has no main.qml"
    patch_widget_for_plasma_6_6 "$package_dir"

    if widget_is_installed; then
        log "updating installed Plasma widget"
        kpackagetool6 -t Plasma/Applet --upgrade "$package_dir"
    else
        log "installing Plasma widget"
        kpackagetool6 -t Plasma/Applet --install "$package_dir"
    fi

    if "$restart_plasma" && systemctl --user is-active plasma-plasmashell.service >/dev/null 2>&1; then
        log "restarting plasmashell to load the updated widget"
        systemctl --user restart plasma-plasmashell.service
    fi
}

add_widget_to_panel() {
    systemctl --user is-active plasma-plasmashell.service >/dev/null 2>&1 \
        || fail "plasmashell is not running"

    local script
    script=$(
        cat <<EOF
var allPanels = panels();
var alreadyPresent = false;
for (var i = 0; i < allPanels.length; i++) {
    var widgets = allPanels[i].widgets();
    for (var j = 0; j < widgets.length; j++) {
        if (widgets[j].type === "$KDE_WIDGET_ID") {
            alreadyPresent = true;
        }
    }
}
if (!alreadyPresent) {
    if (allPanels.length === 0) {
        throw new Error("No Plasma panel is available");
    }
    allPanels[0].addWidget("$KDE_WIDGET_ID");
}
alreadyPresent ? "already-present" : "added";
EOF
    )

    local result
    if have qdbus6; then
        result="$(
            qdbus6 org.kde.plasmashell /PlasmaShell \
                org.kde.PlasmaShell.evaluateScript "$script"
        )"
    elif have qdbus-qt6; then
        result="$(
            qdbus-qt6 org.kde.plasmashell /PlasmaShell \
                org.kde.PlasmaShell.evaluateScript "$script"
        )"
    elif have gdbus; then
        result="$(
            gdbus call --session --dest org.kde.plasmashell \
                --object-path /PlasmaShell \
                --method org.kde.PlasmaShell.evaluateScript "$script"
        )"
    else
        fail "qdbus6, qdbus-qt6, or gdbus is required for --add-to-panel"
    fi
    log "panel integration: ${result:-completed}"
}

check_installation() {
    local failed=false

    log "Fedora: $(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
    log "KDE Plasma: $(plasmashell --version)"

    if [[ -x "$codexbar_path" ]]; then
        log "CLI: $("$codexbar_path" --version) ($codexbar_path)"
    elif have codexbar; then
        log "CLI: $(codexbar --version) ($(command -v codexbar))"
    else
        printf '[codexbar-kde] missing: CodexBar CLI\n' >&2
        failed=true
    fi

    if widget_is_installed; then
        log "Plasma widget: installed ($KDE_WIDGET_ID)"
    else
        printf '[codexbar-kde] missing: Plasma widget %s\n' "$KDE_WIDGET_ID" >&2
        failed=true
    fi

    "$failed" && return 1
    log "Fedora/KDE integration is installed"
}

require_fedora_kde

if [[ "$mode" == "check" ]]; then
    check_installation
    exit
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-kde.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

"$install_cli" && install_codexbar_cli "$work_dir"
"$install_widget" && install_kde_widget "$work_dir"
"$add_to_panel" && add_widget_to_panel
check_installation

log "Open the widget settings to choose providers and refresh behavior."
if ! "$add_to_panel"; then
    log "Add CodexBar from Plasma's “Add Widgets…” dialog, or rerun with --add-to-panel."
fi
