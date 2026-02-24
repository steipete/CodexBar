import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let loadingPercentEpsilon = 0.0001
    private static let blinkActiveTickInterval: Duration = .milliseconds(75)
    private static let blinkIdleFallbackInterval: Duration = .seconds(1)

    func needsMenuBarIconAnimation() -> Bool {
        if self.shouldMergeIcons {
            let primaryProvider = self.primaryProviderForUnifiedIcon()
            return self.shouldAnimate(provider: primaryProvider)
        }
        return UsageProvider.allCases.contains { self.shouldAnimate(provider: $0) }
    }

    func updateBlinkingState() {
        // During the loading animation, blink ticks can overwrite the animated menu bar icon and cause flicker.
        if self.needsMenuBarIconAnimation() {
            self.stopBlinking()
            return
        }

        let blinkingEnabled = self.isBlinkingAllowed()
        // Cache enabled providers to avoid repeated enablement lookups.
        let enabledProviders = self.store.enabledProviders()
        let anyEnabled = !enabledProviders.isEmpty || self.store.debugForceAnimation
        let anyVisible = UsageProvider.allCases.contains { self.isVisible($0) }
        let mergeIcons = self.settings.mergeIcons && enabledProviders.count > 1
        let shouldBlink = mergeIcons ? anyEnabled : anyVisible
        if blinkingEnabled, shouldBlink {
            if self.blinkTask == nil {
                self.seedBlinkStatesIfNeeded()
                self.blinkTask = Task { [weak self] in
                    while !Task.isCancelled {
                        let delay = await MainActor.run {
                            self?.blinkTickSleepDuration(now: Date()) ?? Self.blinkIdleFallbackInterval
                        }
                        try? await Task.sleep(for: delay)
                        await MainActor.run { self?.tickBlink() }
                    }
                }
            }
        } else {
            self.stopBlinking()
        }
    }

    private func seedBlinkStatesIfNeeded() {
        let now = Date()
        for provider in UsageProvider.allCases where self.blinkStates[provider] == nil {
            self.blinkStates[provider] = BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
        }
    }

    private func stopBlinking() {
        self.blinkTask?.cancel()
        self.blinkTask = nil
        self.blinkAmounts.removeAll()
        let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
        if self.shouldMergeIcons {
            self.applyIcon(phase: phase)
        } else {
            for provider in UsageProvider.allCases {
                self.applyIcon(for: provider, phase: phase)
            }
        }
    }

    private func blinkTickSleepDuration(now: Date) -> Duration {
        let mergeIcons = self.shouldMergeIcons
        var nextWakeAt: Date?

        for provider in UsageProvider.allCases {
            let shouldRender = mergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldRender, !self.shouldAnimate(provider: provider, mergeIcons: mergeIcons) else { continue }

            let state = self
                .blinkStates[provider] ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
            if state.blinkStart != nil {
                return Self.blinkActiveTickInterval
            }

            let candidate: Date = state.pendingSecondStart ?? state.nextBlink
            if let current = nextWakeAt {
                if candidate < current {
                    nextWakeAt = candidate
                }
            } else {
                nextWakeAt = candidate
            }
        }

        guard let nextWakeAt else { return Self.blinkIdleFallbackInterval }
        let delay = nextWakeAt.timeIntervalSince(now)
        if delay <= 0 { return Self.blinkActiveTickInterval }
        return .seconds(delay)
    }

    private func tickBlink(now: Date = .init()) {
        guard self.isBlinkingAllowed(at: now) else {
            self.stopBlinking()
            return
        }

        let blinkDuration: TimeInterval = 0.36
        let doubleBlinkChance = 0.18
        let doubleDelayRange: ClosedRange<TimeInterval> = 0.22...0.34
        // Cache merge state once per tick to avoid repeated enabled-provider lookups.
        let mergeIcons = self.shouldMergeIcons

        for provider in UsageProvider.allCases {
            let shouldRender = mergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldRender, !self.shouldAnimate(provider: provider, mergeIcons: mergeIcons) else {
                self.clearMotion(for: provider)
                continue
            }

            var state = self
                .blinkStates[provider] ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))

            if let pendingSecond = state.pendingSecondStart, now >= pendingSecond {
                state.blinkStart = now
                state.pendingSecondStart = nil
            }

            if let start = state.blinkStart {
                let elapsed = now.timeIntervalSince(start)
                if elapsed >= blinkDuration {
                    state.blinkStart = nil
                    if let pending = state.pendingSecondStart, now < pending {
                        // Wait for the planned double-blink.
                    } else {
                        state.pendingSecondStart = nil
                        state.nextBlink = now.addingTimeInterval(BlinkState.randomDelay())
                    }
                    self.clearMotion(for: provider)
                } else {
                    let progress = max(0, min(elapsed / blinkDuration, 1))
                    let symmetric = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                    let eased = pow(symmetric, 2.2) // slightly punchier than smoothstep
                    self.assignMotion(amount: CGFloat(eased), for: provider, effect: state.effect)
                }
            } else if now >= state.nextBlink {
                state.blinkStart = now
                state.effect = self.randomEffect(for: provider)
                if state.effect == .blink, Double.random(in: 0...1) < doubleBlinkChance {
                    state.pendingSecondStart = now.addingTimeInterval(Double.random(in: doubleDelayRange))
                }
                self.clearMotion(for: provider)
            } else {
                self.clearMotion(for: provider)
            }

            self.blinkStates[provider] = state
            if !mergeIcons {
                self.applyIcon(for: provider, phase: nil)
            }
        }
        if mergeIcons {
            let phase: Double? = self.needsMenuBarIconAnimation() ? self.animationPhase : nil
            self.applyIcon(phase: phase)
        }
    }

    private func blinkAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.blinkAmounts[provider] ?? 0
    }

    private func wiggleAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.wiggleAmounts[provider] ?? 0
    }

    private func tiltAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.tiltAmounts[provider] ?? 0
    }

    private func assignMotion(amount: CGFloat, for provider: UsageProvider, effect: MotionEffect) {
        switch effect {
        case .blink:
            self.blinkAmounts[provider] = amount
            self.wiggleAmounts[provider] = 0
            self.tiltAmounts[provider] = 0
        case .wiggle:
            self.wiggleAmounts[provider] = amount
            self.blinkAmounts[provider] = 0
            self.tiltAmounts[provider] = 0
        case .tilt:
            self.tiltAmounts[provider] = amount
            self.blinkAmounts[provider] = 0
            self.wiggleAmounts[provider] = 0
        }
    }

    private func clearMotion(for provider: UsageProvider) {
        self.blinkAmounts[provider] = 0
        self.wiggleAmounts[provider] = 0
        self.tiltAmounts[provider] = 0
    }

    private func randomEffect(for provider: UsageProvider) -> MotionEffect {
        if provider == .claude {
            Bool.random() ? .blink : .wiggle
        } else {
            Bool.random() ? .blink : .tilt
        }
    }

    private func isBlinkingAllowed(at date: Date = .init()) -> Bool {
        if self.settings.randomBlinkEnabled { return true }
        if let until = self.blinkForceUntil, until > date { return true }
        self.blinkForceUntil = nil
        return false
    }

    func applyIcon(phase: Double?) {
        guard let button = self.statusItem.button else { return }

        let style = self.store.iconStyle
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let primaryProvider = self.primaryProviderForUnifiedIcon()
        let snapshot = self.store.snapshot(for: primaryProvider)

        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        var primary = showUsed ? snapshot?.primary?.usedPercent : snapshot?.primary?.remainingPercent
        var weekly = showUsed ? snapshot?.secondary?.usedPercent : snapshot?.secondary?.remainingPercent
        if showUsed,
           primaryProvider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining <= 0
        {
            // Preserve Warp "no bonus/exhausted bonus" layout even in show-used mode.
            weekly = 0
        }
        if showUsed,
           primaryProvider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining > 0,
           weekly == 0
        {
            // In show-used mode, `0` means "unused", not "missing". Keep the weekly lane present.
            weekly = Self.loadingPercentEpsilon
        }
        var credits: Double? = primaryProvider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: primaryProvider)
        var morphProgress: Double?

        let needsAnimation = self.needsMenuBarIconAnimation()
        if let phase, needsAnimation {
            var pattern = self.animationPattern
            if style == .combined, pattern == .unbraid {
                pattern = .cylon
            }
            if pattern == .unbraid {
                morphProgress = pattern.value(phase: phase) / 100
                primary = nil
                weekly = nil
                credits = nil
                stale = false
            } else {
                // Keep loading animation layout stable: IconRenderer uses `weeklyRemaining > 0` to switch layouts,
                // so hitting an exact 0 would flip between "normal" and "weekly exhausted" rendering.
                primary = max(pattern.value(phase: phase), Self.loadingPercentEpsilon)
                weekly = max(pattern.value(phase: phase + pattern.secondaryOffset), Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

        let blink: CGFloat = style == .combined ? 0 : self.blinkAmount(for: primaryProvider)
        let wiggle: CGFloat = style == .combined ? 0 : self.wiggleAmount(for: primaryProvider)
        let tilt: CGFloat = style == .combined ? 0 : self.tiltAmount(for: primaryProvider) * .pi / 28

        let statusIndicator: ProviderStatusIndicator = {
            for provider in self.store.enabledProviders() {
                let indicator = self.store.statusIndicator(for: provider)
                if indicator.hasIssue { return indicator }
            }
            return .none
        }()

        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: primaryProvider)
        {
            let displayText = self.menuBarDisplayText(for: primaryProvider, snapshot: snapshot)
            self.setButtonImage(brand, for: button)
            self.setButtonTitle(displayText, for: button)
            return
        }

        if Self.shouldUseOpenRouterBrandFallback(provider: primaryProvider, snapshot: snapshot),
           let brand = ProviderBrandIcon.image(for: primaryProvider)
        {
            self.setButtonTitle(nil, for: button)
            self.setButtonImage(
                Self.brandImageWithStatusOverlay(brand: brand, statusIndicator: statusIndicator),
                for: button)
            return
        }

        self.setButtonTitle(nil, for: button)
        if let morphProgress {
            let image = IconRenderer.makeMorphIcon(progress: morphProgress, style: style)
            self.setButtonImage(image, for: button)
        } else {
            let image = IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: stale,
                style: style,
                blink: blink,
                wiggle: wiggle,
                tilt: tilt,
                statusIndicator: statusIndicator)
            self.setButtonImage(image, for: button)
        }
    }

    func applyIcon(for provider: UsageProvider, phase: Double?) {
        guard let button = self.statusItems[provider]?.button else { return }
        let snapshot = self.store.snapshot(for: provider)
        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent

        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: provider)
        {
            let displayText = self.menuBarDisplayText(for: provider, snapshot: snapshot)
            self.setButtonImage(brand, for: button)
            self.setButtonTitle(displayText, for: button)
            return
        }

        if Self.shouldUseOpenRouterBrandFallback(provider: provider, snapshot: snapshot),
           let brand = ProviderBrandIcon.image(for: provider)
        {
            self.setButtonTitle(nil, for: button)
            self.setButtonImage(
                Self.brandImageWithStatusOverlay(
                    brand: brand,
                    statusIndicator: self.store.statusIndicator(for: provider)),
                for: button)
            return
        }
        var primary = showUsed ? snapshot?.primary?.usedPercent : snapshot?.primary?.remainingPercent
        var weekly = showUsed ? snapshot?.secondary?.usedPercent : snapshot?.secondary?.remainingPercent
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining <= 0
        {
            // Preserve Warp "no bonus/exhausted bonus" layout even in show-used mode.
            weekly = 0
        }
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining > 0,
           weekly == 0
        {
            // In show-used mode, `0` means "unused", not "missing". Keep the weekly lane present.
            weekly = Self.loadingPercentEpsilon
        }
        var credits: Double? = provider == .codex ? self.store.credits?.remaining : nil
        var stale = self.store.isStale(provider: provider)
        var morphProgress: Double?

        if let phase, self.shouldAnimate(provider: provider) {
            var pattern = self.animationPattern
            if provider == .claude, pattern == .unbraid {
                pattern = .cylon
            }
            if pattern == .unbraid {
                morphProgress = pattern.value(phase: phase) / 100
                primary = nil
                weekly = nil
                credits = nil
                stale = false
            } else {
                // Keep loading animation layout stable: IconRenderer switches layouts at `weeklyRemaining == 0`.
                primary = max(pattern.value(phase: phase), Self.loadingPercentEpsilon)
                weekly = max(pattern.value(phase: phase + pattern.secondaryOffset), Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

        let style: IconStyle = self.store.style(for: provider)
        let isLoading = phase != nil && self.shouldAnimate(provider: provider)
        let blink: CGFloat = {
            guard isLoading, style == .warp, let phase else {
                return self.blinkAmount(for: provider)
            }
            let normalized = (sin(phase * 3) + 1) / 2
            return CGFloat(max(0, min(normalized, 1)))
        }()
        let wiggle = self.wiggleAmount(for: provider)
        let tilt = self.tiltAmount(for: provider) * .pi / 28 // limit to ~6.4°
        if let morphProgress {
            let image = IconRenderer.makeMorphIcon(progress: morphProgress, style: style)
            self.setButtonImage(image, for: button)
        } else {
            self.setButtonTitle(nil, for: button)
            let image = IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: stale,
                style: style,
                blink: blink,
                wiggle: wiggle,
                tilt: tilt,
                statusIndicator: self.store.statusIndicator(for: provider))
            self.setButtonImage(image, for: button)
        }
    }

    private func setButtonImage(_ image: NSImage, for button: NSStatusBarButton) {
        if button.image === image { return }
        button.image = image
    }

    private func setButtonTitle(_ title: String?, for button: NSStatusBarButton) {
        let value = title ?? ""
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
    }

    func menuBarDisplayText(for provider: UsageProvider, snapshot: UsageSnapshot?) -> String? {
        let percentWindow = self.menuBarPercentWindow(for: provider, snapshot: snapshot)
        let displayText = MenuBarDisplayText.displayText(
            mode: self.settings.menuBarDisplayMode,
            provider: provider,
            percentWindow: percentWindow,
            paceWindow: snapshot?.secondary,
            showUsed: self.settings.usageBarsShowUsed)

        let sessionExhausted = (snapshot?.primary?.remainingPercent ?? 100) <= 0
        let weeklyExhausted = (snapshot?.secondary?.remainingPercent ?? 100) <= 0

        if provider == .codex,
           self.settings.menuBarDisplayMode == .percent,
           !self.settings.usageBarsShowUsed,
           sessionExhausted || weeklyExhausted,
           let creditsRemaining = self.store.credits?.remaining,
           creditsRemaining > 0
        {
            return UsageFormatter
                .creditsString(from: creditsRemaining)
                .replacingOccurrences(of: " left", with: "")
        }

        return displayText
    }

    private func menuBarPercentWindow(for provider: UsageProvider, snapshot: UsageSnapshot?) -> RateWindow? {
        self.menuBarMetricWindow(for: provider, snapshot: snapshot)
    }

    private func primaryProviderForUnifiedIcon() -> UsageProvider {
        // When "show highest usage" is enabled, auto-select the provider closest to rate limit.
        if self.settings.menuBarShowsHighestUsage,
           self.shouldMergeIcons,
           let highest = self.store.providerWithHighestUsage()
        {
            return highest.provider
        }
        if self.shouldMergeIcons,
           let selected = self.selectedMenuProvider,
           self.store.isEnabled(selected)
        {
            return selected
        }
        for provider in UsageProvider.allCases {
            if self.store.isEnabled(provider), self.store.snapshot(for: provider) != nil {
                return provider
            }
        }
        if let enabled = self.store.enabledProviders().first {
            return enabled
        }
        return .codex
    }

    @objc func handleDebugBlinkNotification() {
        self.forceBlinkNow()
    }

    private func forceBlinkNow() {
        let now = Date()
        self.blinkForceUntil = now.addingTimeInterval(0.6)
        self.seedBlinkStatesIfNeeded()

        for provider in UsageProvider.allCases {
            let shouldBlink = self.shouldMergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldBlink, !self.shouldAnimate(provider: provider) else { continue }
            var state = self
                .blinkStates[provider] ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
            state.blinkStart = now
            state.pendingSecondStart = nil
            state.effect = self.randomEffect(for: provider)
            state.nextBlink = now.addingTimeInterval(BlinkState.randomDelay())
            self.blinkStates[provider] = state
            self.assignMotion(amount: 0, for: provider, effect: state.effect)
        }

        // If the blink task is currently in a long idle sleep, restart it so this forced blink
        // keeps animating on the active frame cadence immediately.
        self.blinkTask?.cancel()
        self.blinkTask = nil
        self.updateBlinkingState()
        self.tickBlink(now: now)
    }

    private func shouldAnimate(provider: UsageProvider, mergeIcons: Bool? = nil) -> Bool {
        if self.store.debugForceAnimation { return true }

        let isMerged = mergeIcons ?? self.shouldMergeIcons
        let isVisible = isMerged ? self.isEnabled(provider) : self.isVisible(provider)
        guard isVisible else { return false }

        // Don't animate for fallback provider - it's only shown as a placeholder when nothing is enabled.
        // Animating the fallback causes unnecessary CPU usage (battery drain). See #269, #139.
        let isEnabled = self.isEnabled(provider)
        let isFallbackOnly = !isEnabled && self.fallbackProvider == provider
        if isFallbackOnly { return false }

        let isStale = self.store.isStale(provider: provider)
        let hasData = self.store.snapshot(for: provider) != nil
        if provider == .warp, !hasData, self.store.refreshingProviders.contains(provider) {
            return true
        }
        return !hasData && !isStale
    }

    func updateAnimationState() {
        let needsAnimation = self.needsMenuBarIconAnimation()
        if needsAnimation {
            if self.animationDriver == nil {
                if let forced = self.settings.debugLoadingPattern {
                    self.animationPattern = forced
                } else if !LoadingPattern.allCases.contains(self.animationPattern) {
                    self.animationPattern = .knightRider
                }
                self.animationPhase = 0
                let driver = DisplayLinkDriver(onTick: { [weak self] in
                    self?.updateAnimationFrame()
                })
                self.animationDriver = driver
                driver.start(fps: 60)
            } else if let forced = self.settings.debugLoadingPattern, forced != self.animationPattern {
                self.animationPattern = forced
                self.animationPhase = 0
            }
        } else {
            self.animationDriver?.stop()
            self.animationDriver = nil
            self.animationPhase = 0
            if self.shouldMergeIcons {
                self.applyIcon(phase: nil)
            } else {
                UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
            }
        }
    }

    private func updateAnimationFrame() {
        self.animationPhase += 0.045 // half-speed animation
        if self.shouldMergeIcons {
            self.applyIcon(phase: self.animationPhase)
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: self.animationPhase) }
        }
    }

    nonisolated static func shouldUseOpenRouterBrandFallback(
        provider: UsageProvider,
        snapshot: UsageSnapshot?) -> Bool
    {
        guard provider == .openrouter,
              let openRouterUsage = snapshot?.openRouterUsage
        else {
            return false
        }
        return openRouterUsage.keyQuotaStatus == .noLimitConfigured
    }

    nonisolated static func brandImageWithStatusOverlay(
        brand: NSImage,
        statusIndicator: ProviderStatusIndicator) -> NSImage
    {
        guard statusIndicator.hasIssue else { return brand }

        let image = NSImage(size: brand.size)
        image.lockFocus()
        brand.draw(
            at: .zero,
            from: NSRect(origin: .zero, size: brand.size),
            operation: .sourceOver,
            fraction: 1.0)
        Self.drawBrandStatusOverlay(indicator: statusIndicator, size: brand.size)
        image.unlockFocus()
        image.isTemplate = brand.isTemplate
        return image
    }

    private nonisolated static func drawBrandStatusOverlay(indicator: ProviderStatusIndicator, size: NSSize) {
        guard indicator.hasIssue else { return }

        let color = NSColor.labelColor
        switch indicator {
        case .minor, .maintenance:
            let dotSize = CGSize(width: 4, height: 4)
            let dotOrigin = CGPoint(x: size.width - dotSize.width - 2, y: 2)
            color.setFill()
            NSBezierPath(ovalIn: CGRect(origin: dotOrigin, size: dotSize)).fill()
        case .major, .critical, .unknown:
            color.setFill()
            let lineRect = CGRect(x: size.width - 6, y: 4, width: 2, height: 6)
            NSBezierPath(roundedRect: lineRect, xRadius: 1, yRadius: 1).fill()
            let dotRect = CGRect(x: size.width - 6, y: 2, width: 2, height: 2)
            NSBezierPath(ovalIn: dotRect).fill()
        case .none:
            break
        }
    }

    private func advanceAnimationPattern() {
        let patterns = LoadingPattern.allCases
        if let idx = patterns.firstIndex(of: self.animationPattern) {
            let next = patterns.indices.contains(idx + 1) ? patterns[idx + 1] : patterns.first
            self.animationPattern = next ?? .knightRider
        } else {
            self.animationPattern = .knightRider
        }
    }

    @objc func handleDebugReplayNotification(_ notification: Notification) {
        if let raw = notification.userInfo?["pattern"] as? String,
           let selected = LoadingPattern(rawValue: raw)
        {
            self.animationPattern = selected
        } else if let forced = self.settings.debugLoadingPattern {
            self.animationPattern = forced
        } else {
            self.advanceAnimationPattern()
        }
        self.animationPhase = 0
        self.updateAnimationState()
    }
}
