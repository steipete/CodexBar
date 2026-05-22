---
summary: "Homebrew Cask release steps for CodexBar (Sparkle-disabled builds)."
read_when:
  - Publishing a CodexBar release via Homebrew
  - Updating the Homebrew tap cask definition
---

# CodexBar Homebrew Release Playbook

Homebrew is for the UI app via Cask. When installed via Homebrew, CodexBar disables Sparkle and shows a "update via brew" hint in About.

## Prereqs
- Homebrew installed.
- Access to the tap repo: `../homebrew-tap`.

## 1) Release CodexBar normally
Follow `docs/RELEASING.md` to publish `CodexBar-macos-universal-<version>.zip` to GitHub Releases.

## 2) Let the Release CLI workflow update the tap
After the GitHub release is published, `.github/workflows/release-cli.yml` builds the standalone CLI assets and dispatches `steipete/homebrew-tap`'s `update-formula.yml`. That tap workflow updates both:
- `Casks/codexbar.rb` for the app zip.
- `Formula/codexbar.rb` for the standalone CLI tarballs.

If dispatch fails or is rate-limited, update the files manually.

## 2a) Manual cask update
In `../homebrew-tap`, update the cask at `Casks/codexbar.rb`:
- `url` points at the GitHub release asset: `.../releases/download/v<version>/CodexBar-macos-universal-<version>.zip`
- Update `sha256` to match that zip.
- Keep `depends_on arch: :arm64` and `depends_on macos: ">= :sonoma"` (CodexBar is macOS 14+).

## 2b) Manual formula update
In `../homebrew-tap`, update the formula at `Formula/codexbar.rb`:
- `url` points at the GitHub release assets:
  - macOS: `.../releases/download/v<version>/CodexBarCLI-v<version>-macos-arm64.tar.gz`
  - macOS: `.../releases/download/v<version>/CodexBarCLI-v<version>-macos-x86_64.tar.gz`
  - Linux: `.../releases/download/v<version>/CodexBarCLI-v<version>-linux-aarch64.tar.gz`
  - Linux: `.../releases/download/v<version>/CodexBarCLI-v<version>-linux-x86_64.tar.gz`
- Update all `sha256` values to match those tarballs.

## 3) Verify install
```sh
brew uninstall --cask codexbar || true
brew untap steipete/tap || true
brew tap steipete/tap
brew install --cask steipete/tap/codexbar
open -a CodexBar
```

## 4) Push tap changes
Commit + push in the tap repo.
