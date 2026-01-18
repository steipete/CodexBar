# CodexBar for Windows/Linux

This is the cross-platform port of [CodexBar](https://github.com/steipete/CodexBar), originally a macOS menu bar app for monitoring AI provider API usage.

## Features

- **System tray app** with usage menu (like macOS menu bar)
- **12 AI providers** supported:
  - Codex (OpenAI)
  - Claude (Anthropic)
  - Cursor
  - Gemini (Google)
  - GitHub Copilot
  - Antigravity
  - Factory/Droid
  - z.ai
  - Kiro
  - Vertex AI
  - Augment
  - MiniMax
- **Usage meters** with session + weekly + monthly tracking
- **Settings window** for provider toggles and preferences
- **Auto-updates** via electron-updater
- **CLI** for terminal usage

## Installation

### Download

Download the latest release from [GitHub Releases](https://github.com/steipete/CodexBar/releases).

- **Windows**: Download `CodexBar-Setup-x.x.x.exe` (installer) or `CodexBar-x.x.x-portable.exe`
- **Linux**: Download `CodexBar-x.x.x.AppImage` or `CodexBar-x.x.x.deb`

### Build from Source

```bash
cd codexbar-electron

# Install dependencies
npm install

# Development mode
npm run dev

# Build for production
npm run build

# Package for distribution
npm run dist:win   # Windows
npm run dist:linux # Linux
```

## Development

### Prerequisites

- Node.js 18+
- npm 9+

### Project Structure

```
codexbar-electron/
├── src/
│   ├── main/           # Electron main process
│   │   ├── providers/  # AI provider implementations
│   │   ├── store/      # Settings & usage persistence
│   │   ├── tray/       # System tray menu
│   │   └── utils/      # Utilities (logger, subprocess)
│   ├── renderer/       # React UI (settings window)
│   ├── cli/            # Command-line interface
│   └── shared/         # Shared types
├── assets/             # Icons and images
├── dist/               # Build output
└── release/            # Packaged apps
```

### Scripts

```bash
npm run dev          # Start in development mode
npm run build        # Build TypeScript
npm run start        # Run built app
npm run dist         # Package for current platform
npm run lint         # Run ESLint
npm run typecheck    # TypeScript check
npm run test         # Run tests
```

### Adding a New Provider

1. Create a new directory under `src/main/providers/<name>/`
2. Create `<Name>Provider.ts` extending `BaseProvider`
3. Implement `isConfigured()` and `fetchUsage()`
4. Register in `ProviderManager.ts`

Example:

```typescript
import { BaseProvider, ProviderUsage } from '../BaseProvider';

export class NewProvider extends BaseProvider {
  readonly id = 'newprovider';
  readonly name = 'New Provider';
  readonly icon = '🆕';
  readonly websiteUrl = 'https://newprovider.ai';
  
  async isConfigured(): Promise<boolean> {
    // Check if provider is set up
    return true;
  }
  
  async fetchUsage(): Promise<ProviderUsage | null> {
    // Fetch and return usage data
    return null;
  }
}
```

## CLI Usage

```bash
# Show status for all providers
codexbar status

# Show status for specific provider
codexbar status -p claude

# Output as JSON
codexbar status -j

# List all providers
codexbar list

# Refresh data
codexbar refresh
```

## Architecture

This port uses:

- **Electron** - Cross-platform desktop framework
- **React** - Settings UI
- **TypeScript** - Type safety
- **electron-store** - Settings persistence
- **electron-updater** - Auto-updates
- **winston** - Logging

The architecture mirrors the macOS app:
- Provider-based design for extensibility
- Background polling for usage updates
- System tray integration
- IPC for main/renderer communication

## License

MIT License - see [LICENSE](../LICENSE)
