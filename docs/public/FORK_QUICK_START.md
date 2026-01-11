# CodexBar Fork - Quick Start Guide

**Fork Maintainer:** Brandon Charleson ([topoffunnel.com](https://topoffunnel.com))  
**Original Author:** Peter Steinberger ([steipete](https://twitter.com/steipete))  
**Fork Repository:** https://github.com/topoffunnel/CodexBar

---

## 🎯 What Makes This Fork Different?

### Key Enhancements
1. **Augment Provider Support** - Full integration with Augment Code API
2. **Enhanced Security** - Improved keychain handling, no permission prompts
3. **Better Cookie Management** - Automatic session keepalive, Chrome Beta support
4. **Bug Fixes** - Cursor bonus credits, cookie domain filtering

### Planned Features
- Multi-account management per provider
- Enhanced diagnostics and logging
- Upstream sync automation
- Usage history tracking

---

## 🚀 Quick Commands

### Development
```bash
# Build and run (kills old instances, builds, tests, packages, relaunches)
./Scripts/compile_and_run.sh

# Quick build
swift build

# Run tests
swift test

# Format code
swiftformat Sources Tests
swiftlint --strict

# Package app
./Scripts/package_app.sh

# Restart app after rebuild
pkill -x CodexBar || pkill -f CodexBar.app || true
cd /Users/steipete/Projects/codexbar && open -n /Users/steipete/Projects/codexbar/CodexBar.app
```

### Release
```bash
# Sign and notarize (keep in foreground!)
./Scripts/sign-and-notarize.sh

# Create appcast
./Scripts/make_appcast.sh <zip> <feed-url>

# See full release process
cat docs/RELEASING.md
```

### Git Workflow
```bash
# Check status
git status

# Create feature branch
git checkout -b feature/my-feature

# Commit changes
git add -A
git commit -m "feat: description"

# Push to fork
git push origin feature/my-feature

# Sync with upstream (TBD - see docs/FORK_ROADMAP.md Phase 4)
```

---

## 📁 Key Files & Directories

### Source Code
- `Sources/CodexBar/` - Swift 6 menu bar app
- `Sources/CodexBarCore/` - Core logic, providers, utilities
- `Sources/CodexBarCore/Providers/Augment/` - Augment provider implementation
- `Tests/CodexBarTests/` - XCTest coverage

### Scripts
- `Scripts/compile_and_run.sh` - Main development script
- `Scripts/package_app.sh` - Package app bundle
- `Scripts/sign-and-notarize.sh` - Release signing
- `Scripts/make_appcast.sh` - Generate appcast XML

### Documentation
- `docs/augment.md` - Augment provider guide
- `docs/FORK_ROADMAP.md` - Development roadmap
- `docs/RELEASING.md` - Release process
- `docs/DEVELOPMENT.md` - Build instructions
- `README.md` - Main documentation

---

## 🔧 Common Tasks

### Adding a New Feature
1. Create feature branch: `git checkout -b feature/my-feature`
2. Make changes in `Sources/`
3. Add tests in `Tests/`
4. Run `./Scripts/compile_and_run.sh` to verify
5. Run `swiftformat Sources Tests && swiftlint --strict`
6. Commit with descriptive message
7. Push and create PR

### Debugging Augment Issues
1. Enable debug logging: `export CODEXBAR_LOG_LEVEL=debug`
2. Check Console.app for "com.steipete.codexbar"
3. Use Settings → Debug → Augment → Show Debug Info
4. Check `docs/augment.md` troubleshooting section

### Testing Changes
```bash
# Run all tests
swift test

# Run specific test
swift test --filter AugmentTests

# Build and test together
./Scripts/compile_and_run.sh
```

### Updating Documentation
1. Edit relevant `.md` file in `docs/`
2. Update `README.md` if needed
3. Commit with `docs:` prefix
4. No need to rebuild app

---

## 🐛 Troubleshooting

### App Won't Launch
```bash
# Kill all instances
pkill -x CodexBar || pkill -f CodexBar.app || true

# Rebuild and relaunch
./Scripts/compile_and_run.sh
```

### Build Errors
```bash
# Clean build
swift package clean
swift build

# Check for format issues
swiftformat Sources Tests --lint
swiftlint --strict
```

### Cookie Issues (Augment)
1. Check browser is logged into app.augmentcode.com
2. Verify cookie source in Settings → Providers → Augment
3. Try manual cookie import (see `docs/augment.md`)
4. Check debug logs for cookie import details

### Keychain Permission Prompts
- This fork includes fixes to eliminate prompts
- If you still see prompts, check `Sources/CodexBarCore/Keychain/`
- Ensure you're running the latest build

---

## 📚 Learning Resources

### Understanding the Codebase
1. Start with `Sources/CodexBar/CodexbarApp.swift` - App entry point
2. Review `Sources/CodexBarCore/UsageStore.swift` - Main state management
3. Check `Sources/CodexBarCore/Providers/` - Provider implementations
4. Read `docs/provider.md` - Provider authoring guide

### Swift 6 & SwiftUI
- Uses `@Observable` macro (not `ObservableObject`)
- Prefer `@State` ownership over `@StateObject`
- Use `@Bindable` in views for two-way binding
- Strict concurrency checking enabled

### Coding Style
- 4-space indentation
- 120-character line limit
- Explicit `self` is intentional (don't remove)
- Follow existing `MARK` organization
- Use descriptive variable names

---

## 🤝 Contributing

### To This Fork
1. Fork the fork repository
2. Create feature branch
3. Make changes with tests
4. Submit PR to `topoffunnel/CodexBar`

### To Upstream
1. Check if feature benefits all users
2. Create PR to `steipete/CodexBar`
3. Reference this fork if relevant
4. Be patient with review process

See `docs/FORK_ROADMAP.md` for contribution strategy.

---

## 📞 Support

### Fork-Specific Issues
- GitHub Issues: https://github.com/topoffunnel/CodexBar/issues
- Email: [your-email]@topoffunnel.com

### Upstream Issues
- GitHub Issues: https://github.com/steipete/CodexBar/issues
- Twitter: [@steipete](https://twitter.com/steipete)

---

## 📋 Next Steps

1. **Read the Roadmap:** `docs/FORK_ROADMAP.md`
2. **Set Up Development:** `./Scripts/compile_and_run.sh`
3. **Review Augment Docs:** `docs/augment.md`
4. **Check Current Issues:** GitHub Issues tab
5. **Join Development:** Pick a task from Phase 2-5

---

## 🎉 Quick Wins

Want to contribute but not sure where to start? Try these:

- [ ] Add more test coverage for Augment provider
- [ ] Improve error messages in cookie import
- [ ] Add screenshots to `docs/augment.md`
- [ ] Test on different macOS versions
- [ ] Report bugs you find
- [ ] Suggest UI improvements

Happy coding! 🚀

