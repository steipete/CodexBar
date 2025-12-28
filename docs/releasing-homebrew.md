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
Follow `docs/RELEASING.md` to publish `CodexBar-<version>.zip` to GitHub Releases.

## 2) Update the Homebrew tap cask
In `../homebrew-tap`, add/update the cask at `Casks/codexbar.rb`:
- `url` points at the GitHub release asset: `.../releases/download/v<version>/CodexBar-<version>.zip`
- Update `sha256` to match that zip.
- Keep `depends_on arch: :arm64` and `depends_on macos: ">= :sonoma"` (CodexBar is macOS 14+).

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
