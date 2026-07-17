import AppKit
import CodexBarCore
import QuartzCore

extension StatusItemController {
    private static let loadingPercentEpsilon = 0.0001
    private static let blinkActiveTickInterval: Duration = .milliseconds(75)
    private static let blinkIdleFallbackInterval: Duration = .seconds(1)
    static let loadingAnimationFPS: Double = 30.0
    static let loadingAnimationPhaseIncrement: Double =
        2.7 / StatusItemController.loadingAnimationFPS
    private static let loadingAnimationMaxContinuousDuration: TimeInterval = 30.0
    func needsMenuBarIconAnimation() -> Bool {
        if self.shouldMergeIcons {
            let primaryProvider = self.primaryProviderForUnifiedIcon()
            return self.shouldAnimate(provider: primaryProvider)
        }
        return UsageProvider.allCases.contains { self.shouldAnimate(provider: $0) }
    }

    func updateBlinkingState() {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        // During the loading animation, blink ticks can overwrite the animated menu bar icon and cause flicker.
        if self.needsMenuBarIconAnimation() {
            self.stopBlinking()
            return
        }

        let blinkingEnabled = self.isBlinkingAllowed()
        // Use display list so merged-mode visibility stays consistent with shouldMergeIcons.
        let displayProviders = self.store.enabledProvidersForDisplay()
        let anyEnabled = !displayProviders.isEmpty || self.store.debugForceAnimation
        let anyVisible = UsageProvider.allCases.contains { self.isVisible($0) }
        let mergeIcons = self.shouldMergeIcons
        let shouldBlink = mergeIcons ? anyEnabled : anyVisible
        if blinkingEnabled, shouldBlink {
            if self.blinkTask == nil {
                self.seedBlinkStatesIfNeeded()
                self.blinkTask = Task { [weak self] in
                    while !Task.isCancelled {
                        let delay = await MainActor.run {
                            self?.blinkTickSleepDuration(now: Date())
                                ?? Self.blinkIdleFallbackInterval
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
            self.blinkStates[provider] = BlinkState(
                nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
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
            guard shouldRender, !self.shouldAnimate(provider: provider, mergeIcons: mergeIcons)
            else { continue }

            let state =
                self
                    .blinkStates[provider]
                    ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
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
            guard shouldRender, !self.shouldAnimate(provider: provider, mergeIcons: mergeIcons)
            else {
                self.clearMotion(for: provider)
                continue
            }

            var state =
                self
                    .blinkStates[provider]
                    ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))

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
                    state.pendingSecondStart = now.addingTimeInterval(
                        Double.random(in: doubleDelayRange))
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
            self.applyIcon(phase: nil)
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

    @discardableResult
    func applyIcon(
        phase: Double?,
        bypassMergedMenuTrackingDeferral: Bool = false) -> Bool
    {
        guard let button = self.statusItem.button else { return false }
        if !bypassMergedMenuTrackingDeferral,
           self.deferMergedIconRenderDuringMenuTrackingIfNeeded() { return true }

        let style = self.store.iconStyle
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let primaryProvider = self.primaryProviderForUnifiedIcon()
        let resolverStyle = self.store.style(for: primaryProvider)
        let snapshot = self.store.snapshot(for: primaryProvider)
        let warningFlash = self.quotaWarningFlashActive(provider: primaryProvider)

        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let resolved = self.resolvedMenuBarIconPercents(
            provider: primaryProvider,
            snapshot: snapshot,
            style: resolverStyle,
            showUsed: showUsed,
            renderingStyle: style)
        var primary = resolved?.primary
        var weekly = resolved?.secondary
        var credits = self.menuBarCreditsRemainingForIcon(provider: primaryProvider, snapshot: snapshot)
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
                weekly = max(
                    pattern.value(phase: phase + pattern.secondaryOffset),
                    Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

        let blink: CGFloat = style == .combined ? 0 : self.blinkAmount(for: primaryProvider)
        let wiggle: CGFloat = style == .combined ? 0 : self.wiggleAmount(for: primaryProvider)
        let tilt: CGFloat =
            style == .combined ? 0 : self.tiltAmount(for: primaryProvider) * .pi / 28

        let statusIndicator = self.store.statusIndicator(for: primaryProvider)
        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: primaryProvider)
        {
            let displayText = self.menuBarDisplayText(for: primaryProvider, snapshot: snapshot)
            let displayedImage = warningFlash ? Self.quotaWarningFlashImage(base: brand) : brand
            let signature = [
                "mode=brandPercent",
                "provider=\(primaryProvider.rawValue)",
                "style=\(String(describing: style))",
                "primary=\(Self.iconSignatureValue(primary))",
                "weekly=\(Self.iconSignatureValue(weekly))",
                "credits=\(Self.iconSignatureValue(credits))",
                "stale=\(stale ? "1" : "0")",
                "status=\(statusIndicator.rawValue)",
                "text=\(displayText ?? "nil")",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "anim=\(needsAnimation ? "1" : "0")",
                "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipMergedIconRender(signature) {
                // AppKit can lose button content state independently of the cached render signature.
                // Keep this cheap path self-healing even when the provider image itself can be skipped.
                self.setButtonContent(image: displayedImage, title: displayText, for: button)
                self.noteIconPerfRender(skipped: true)
                return true
            }
            self.setButtonContent(image: displayedImage, title: displayText, for: button)
            self.noteIconPerfRender(skipped: false)
            return false
        }

        // Brand + percent returns above; remaining paths are image-only apart from the debug marker.
        let canSkipCachedRender = self.prepareButtonForImageOnlyCacheHit(button)
        if let morphProgress {
            let signature = [
                "mode=morph",
                "provider=\(primaryProvider.rawValue)",
                "style=\(String(describing: style))",
                "morph=\(Self.iconSignatureValue(morphProgress))",
                "status=\(statusIndicator.rawValue)",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "anim=\(needsAnimation ? "1" : "0")",
                "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipMergedIconRender(signature), canSkipCachedRender {
                self.noteIconPerfRender(skipped: true)
                return true
            }
            let image = IconRenderer.makeMorphIcon(
                progress: morphProgress,
                style: style,
                hideCritters: self.settings.menuBarHidesCritters)
            self.setButtonContent(
                image: warningFlash ? Self.quotaWarningFlashImage(base: image) : image,
                title: nil,
                for: button)
        } else {
            let signature = [
                "mode=icon",
                "provider=\(primaryProvider.rawValue)",
                "style=\(String(describing: style))",
                "primary=\(Self.iconSignatureValue(primary))",
                "weekly=\(Self.iconSignatureValue(weekly))",
                "credits=\(Self.iconSignatureValue(credits))",
                "stale=\(stale ? "1" : "0")",
                "status=\(statusIndicator.rawValue)",
                "blink=\(Self.iconSignatureValue(Double(blink)))",
                "wiggle=\(Self.iconSignatureValue(Double(wiggle)))",
                "tilt=\(Self.iconSignatureValue(Double(tilt)))",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "anim=\(needsAnimation ? "1" : "0")",
                "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipMergedIconRender(signature), canSkipCachedRender {
                self.noteIconPerfRender(skipped: true)
                return true
            }
            let image = IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: stale,
                style: style,
                blink: blink,
                wiggle: wiggle,
                tilt: tilt,
                statusIndicator: statusIndicator,
                hideCritters: self.settings.menuBarHidesCritters)
            self.setButtonContent(
                image: warningFlash ? Self.quotaWarningFlashImage(base: image) : image,
                title: nil,
                for: button)
        }
        self.noteIconPerfRender(skipped: false)
        return false
    }

    private func deferMergedIconRenderDuringMenuTrackingIfNeeded() -> Bool {
        guard self.shouldMergeIcons, self.isMergedMenuOpen else { return false }
        self.deferredMergedIconRenderAfterTracking = true
        self.noteIconPerfRender(skipped: true)
        return true
    }

    func applyDeferredMergedIconRenderAfterTrackingIfNeeded() {
        guard self.deferredMergedIconRenderAfterTracking else { return }
        guard self.shouldMergeIcons else {
            self.deferredMergedIconRenderAfterTracking = false
            return
        }
        guard !self.isMergedMenuOpen else { return }
        self.deferredMergedIconRenderAfterTracking = false
        let phase: Double? = self.animationDriver == nil ? nil : self.animationPhase
        self.applyIcon(phase: phase)
    }

    private func shouldSkipMergedIconRender(_ signature: String) -> Bool {
        guard self.shouldMergeIcons else {
            self.lastAppliedMergedIconRenderSignature = signature
            return false
        }
        if self.lastAppliedMergedIconRenderSignature == signature {
            return true
        }
        self.lastAppliedMergedIconRenderSignature = signature
        return false
    }

    private func shouldSkipProviderIconRender(provider: UsageProvider, signature: String) -> Bool {
        if self.lastAppliedProviderIconRenderSignatures[provider] == signature {
            return true
        }
        self.lastAppliedProviderIconRenderSignatures[provider] = signature
        return false
    }

    @discardableResult
    func applyIcon(for provider: UsageProvider, phase: Double?) -> Bool {
        guard let button = self.statusItems[provider]?.button else { return false }
        let snapshot = self.store.snapshot(for: provider)
        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let style: IconStyle = self.store.style(for: provider)
        let warningFlash = self.quotaWarningFlashActive(provider: provider)

        if showBrandPercent,
           let brand = ProviderBrandIcon.image(for: provider)
        {
            let displayText = self.menuBarDisplayText(for: provider, snapshot: snapshot)
            let displayedImage = warningFlash ? Self.quotaWarningFlashImage(base: brand) : brand
            let signature = [
                "mode=brandPercent",
                "provider=\(provider.rawValue)",
                "style=\(String(describing: style))",
                "text=\(displayText ?? "nil")",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipProviderIconRender(provider: provider, signature: signature) {
                self.setButtonContent(image: displayedImage, title: displayText, for: button)
                self.noteIconPerfRender(skipped: true)
                return true
            }
            self.setButtonContent(image: displayedImage, title: displayText, for: button)
            self.noteIconPerfRender(skipped: false)
            return false
        }

        // OpenRouter always gets a meter here — the brand-logo fallback was removed on purpose.
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider,
            snapshot: snapshot,
            style: style,
            showUsed: showUsed)
        var primary = resolved?.primary
        var weekly = resolved?.secondary
        var credits = self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
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
                weekly = max(
                    pattern.value(phase: phase + pattern.secondaryOffset),
                    Self.loadingPercentEpsilon)
                credits = nil
                stale = false
            }
        }

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
        let statusIndicator = self.store.statusIndicator(for: provider)
        // Brand + percent returns above; remaining paths are image-only apart from the debug marker.
        let canSkipCachedRender = self.prepareButtonForImageOnlyCacheHit(button)
        if let morphProgress {
            let signature = [
                "mode=morph",
                "provider=\(provider.rawValue)",
                "style=\(String(describing: style))",
                "morph=\(Self.iconSignatureValue(morphProgress))",
                "status=\(statusIndicator.rawValue)",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "loading=\(isLoading ? "1" : "0")",
                "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipProviderIconRender(provider: provider, signature: signature), canSkipCachedRender {
                self.noteIconPerfRender(skipped: true)
                return true
            }
            let image = IconRenderer.makeMorphIcon(
                progress: morphProgress,
                style: style,
                hideCritters: self.settings.menuBarHidesCritters)
            self.setButtonContent(
                image: warningFlash ? Self.quotaWarningFlashImage(base: image) : image,
                title: nil,
                for: button)
        } else {
            let signature = [
                "mode=icon",
                "provider=\(provider.rawValue)",
                "style=\(String(describing: style))",
                "primary=\(Self.iconSignatureValue(primary))",
                "weekly=\(Self.iconSignatureValue(weekly))",
                "credits=\(Self.iconSignatureValue(credits))",
                "stale=\(stale ? "1" : "0")",
                "status=\(statusIndicator.rawValue)",
                "blink=\(Self.iconSignatureValue(Double(blink)))",
                "wiggle=\(Self.iconSignatureValue(Double(wiggle)))",
                "tilt=\(Self.iconSignatureValue(Double(tilt)))",
                "warningFlash=\(warningFlash ? "1" : "0")",
                "loading=\(isLoading ? "1" : "0")",
                "hideCritters=\(self.settings.menuBarHidesCritters ? "1" : "0")",
                "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
            ].joined(separator: "|")
            if self.shouldSkipProviderIconRender(provider: provider, signature: signature), canSkipCachedRender {
                self.noteIconPerfRender(skipped: true)
                return true
            }
            let image = IconRenderer.makeIcon(
                primaryRemaining: primary,
                weeklyRemaining: weekly,
                creditsRemaining: credits,
                stale: stale,
                style: style,
                blink: blink,
                wiggle: wiggle,
                tilt: tilt,
                statusIndicator: statusIndicator,
                hideCritters: self.settings.menuBarHidesCritters)
            self.setButtonContent(
                image: warningFlash ? Self.quotaWarningFlashImage(base: image) : image,
                title: nil,
                for: button)
        }
        self.noteIconPerfRender(skipped: false)
        return false
    }

    static func iconSignatureValue(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.3f", value)
    }

    func resolvedMenuBarIconPercents(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        style: IconStyle,
        showUsed: Bool,
        renderingStyle: IconStyle? = nil)
        -> (primary: Double?, secondary: Double?)?
    {
        guard let snapshot else { return nil }
        let preference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        if preference == .monthlyPlan {
            guard let metricWindow = self.menuBarMetricWindowForIconOverride(
                preference: preference,
                provider: provider,
                snapshot: snapshot)
            else {
                return (primary: nil, secondary: nil)
            }
            return (
                primary: showUsed ? metricWindow.usedPercent : metricWindow.remainingPercent,
                secondary: nil)
        }
        if provider == .mistral {
            return (primary: nil, secondary: nil)
        }
        return IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: style,
            showUsed: showUsed,
            renderingStyle: renderingStyle,
            secondaryOverrideWindowID: self.settings.copilotIconSecondaryWindowOverrideID(snapshot: snapshot))
    }

    private func menuBarMetricWindowForIconOverride(
        preference: MenuBarMetricPreference,
        provider: UsageProvider,
        snapshot: UsageSnapshot)
        -> RateWindow?
    {
        MenuBarMetricWindowResolver.rateWindow(
            preference: preference,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider))
    }

    func menuBarCreditsRemainingForIcon(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = Date()) -> Double?
    {
        // Derive the menu-bar credits fallback from the same Codex projection path the rendered
        // icon and menu use (`codexConsumerProjection` -> `menuBarFallback`), instead of a
        // hand-rolled rate-window predicate. The projection is pure value composition over
        // already-loaded snapshot/credits state (no IO), so this stays cheap while keeping the
        // icon render, this signature input, and the menu-bar fallback semantics on a single
        // source of truth — a hand-rolled approximation can silently drift from the projection
        // as its fallback logic evolves.
        guard provider == .codex else { return nil }
        return self.store.codexMenuBarCreditsRemaining(
            snapshotOverride: snapshot,
            now: now)
    }

    func quotaWarningFlashActive(provider: UsageProvider, now: Date = Date()) -> Bool {
        guard let until = self.quotaWarningFlashUntil[provider] else { return false }
        if until > now { return true }
        self.quotaWarningFlashUntil.removeValue(forKey: provider)
        self.quotaWarningFlashTasks[provider]?.cancel()
        self.quotaWarningFlashTasks.removeValue(forKey: provider)
        return false
    }

    func startQuotaWarningFlash(provider: UsageProvider, postedAt: Date = Date()) {
        let until = postedAt.addingTimeInterval(Self.quotaWarningFlashDuration)
        self.quotaWarningFlashUntil[provider] = until
        self.quotaWarningFlashTasks[provider]?.cancel()
        self.updateIcons()
        self.applyQuotaWarningIconDuringMergedMenuTrackingIfNeeded()
        self.quotaWarningFlashTasks[provider] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.quotaWarningFlashDuration))
            await MainActor.run { [weak self] in
                self?.clearExpiredQuotaWarningFlash(provider: provider)
            }
        }
    }

    func clearExpiredQuotaWarningFlash(provider: UsageProvider, now: Date = Date()) {
        guard let currentUntil = self.quotaWarningFlashUntil[provider],
              currentUntil <= now
        else {
            return
        }
        self.quotaWarningFlashUntil.removeValue(forKey: provider)
        self.quotaWarningFlashTasks.removeValue(forKey: provider)
        self.updateIcons()
        self.applyQuotaWarningIconDuringMergedMenuTrackingIfNeeded()
    }

    private func applyQuotaWarningIconDuringMergedMenuTrackingIfNeeded() {
        guard self.shouldMergeIcons,
              self.isMergedMenuOpen
        else {
            return
        }
        let phase: Double? = self.animationDriver == nil ? nil : self.animationPhase
        self.applyIcon(phase: phase, bypassMergedMenuTrackingDeferral: true)
    }

    static func quotaWarningFlashImage(base: NSImage) -> NSImage {
        let image = NSImage(size: base.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: base.size)
        NSColor.systemRed.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.systemRed.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private var shouldUseHighContrastStatusItemContent: Bool {
        self.settings.menuBarHighContrastOnInactiveDisplays
            && self.settings.menuBarIconStyle == .iconAndPercent
    }

    func prepareButtonForImageOnlyCacheHit(_ button: NSStatusBarButton) -> Bool {
        if self.shouldUseHighContrastStatusItemContent {
            guard button.image == nil,
                  button.imagePosition == .noImage,
                  button.attributedTitle.length > 0
            else { return false }
            return button.attributedTitle.attribute(
                .attachment,
                at: 0,
                effectiveRange: nil) is NSTextAttachment
        }

        let value = Self.buttonTitle(
            nil,
            hasImage: true,
            isDebugApp: Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier))
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
        return true
    }

    private func setButtonContent(image: NSImage, title: String?, for button: NSStatusBarButton) {
        let isDebugApp = Self.isDebugApp(bundleIdentifier: Bundle.main.bundleIdentifier)
        let value = Self.buttonTitle(
            title,
            hasImage: true,
            isDebugApp: isDebugApp)

        if self.shouldUseHighContrastStatusItemContent {
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = Self.highContrastButtonTitle(image: image, title: value)
            return
        }

        if button.image !== image {
            button.image = image
        }
        if button.title != value {
            button.title = value
        }
        let position: NSControl.ImagePosition = value.isEmpty ? .imageOnly : .imageLeft
        if button.imagePosition != position {
            button.imagePosition = position
        }
    }

    static func highContrastButtonTitle(image: NSImage, title: String) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: ((font.capHeight - image.size.height) / 2).rounded(),
            width: image.size.width,
            height: image.size.height)

        let value = NSMutableAttributedString(attachment: attachment)
        if !title.isEmpty {
            value.append(NSAttributedString(
                string: title,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]))
        }
        return value
    }

    nonisolated static func buttonTitle(_ title: String?, hasImage: Bool, isDebugApp: Bool = false) -> String {
        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append(title)
        }
        if isDebugApp {
            parts.append("D")
        }
        let value = parts.joined(separator: " ")
        return hasImage && !value.isEmpty ? " \(value)" : value
    }

    func menuBarDisplayText(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        now: Date = .init()) -> String?
    {
        let mode = self.settings.menuBarDisplayMode
        if provider == .openrouter,
           self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic,
           let balance = snapshot?.openRouterUsage?.balance
        {
            return UsageFormatter.usdString(balance)
        }
        if provider == .opencodego,
           let balance = Self.openCodeGoZenBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .deepseek,
           let balance = Self.deepSeekBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .mimo,
           let balance = Self.miMoBalanceDisplayText(
               snapshot: snapshot,
               preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot))
        {
            return balance
        }
        if provider == .moonshot,
           let balance = Self.moonshotBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .poe,
           let balance = Self.poeBalanceDisplayText(snapshot: snapshot)
        {
            return balance
        }
        if provider == .mistral {
            let preference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
            let hasMonthlyPlan = snapshot?.extraRateWindows?.contains { $0.id == "mistral-monthly-plan" } == true
            if preference != .monthlyPlan || !hasMonthlyPlan,
               let spend = Self.mistralSpendDisplayText(snapshot: snapshot)
            {
                return spend
            }
        }
        if provider == .kiro {
            return Self.kiroDisplayText(
                snapshot: snapshot,
                mode: self.settings.kiroMenuBarDisplayMode,
                showUsed: self.settings.usageBarsShowUsed)
        }
        if mode != .resetTime,
           self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .extraUsage,
           provider != .cursor || mode == .pace,
           let spend = Self.extraUsageSpendDisplayText(snapshot: snapshot)
        {
            return spend
        }

        let percentWindow = self.menuBarPercentWindow(for: provider, snapshot: snapshot, now: now)
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)

        // The combined "Session + Weekly" metric (Codex and Claude) shows both lanes in percent mode
        // ("5h 12% · W 45%") and, in pace/both modes, pairs the session usage with the weekly pace.
        let combinedLanes = self.combinedSessionWeeklyLanes(
            for: provider, snapshot: snapshot, projection: codexProjection)

        let pace: UsagePace?
        switch mode {
        case .percent:
            pace = nil
        case .pace, .both:
            let paceWindow = self.menuBarPaceWindow(
                for: provider,
                snapshot: snapshot,
                projection: codexProjection,
                combinedLanes: combinedLanes,
                percentWindow: percentWindow)
            pace = paceWindow.flatMap { window in
                self.store.weeklyPace(provider: provider, window: window, now: now)
            }
        case .resetTime:
            return MenuBarDisplayText.displayText(
                mode: mode,
                percentWindow: percentWindow,
                showUsed: self.settings.usageBarsShowUsed,
                resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
                now: now)
        }
        if mode == .percent,
           !self.settings.usageBarsShowUsed,
           codexProjection?.menuBarFallback == .creditsBalance,
           let creditsRemaining = codexProjection?.credits?.remaining,
           creditsRemaining > 0
        {
            return
                UsageFormatter
                    .creditsString(from: creditsRemaining)
                    .replacingOccurrences(of: " left", with: "")
        }
        if let combinedLanes, mode == .percent {
            if let combinedText = MenuBarDisplayText.combinedSessionWeeklyPercentText(
                sessionWindow: combinedLanes.session,
                weeklyWindow: combinedLanes.weekly,
                showUsed: self.settings.usageBarsShowUsed,
                resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
                showsResetTimeWhenExhausted: self.settings.menuBarShowsResetTimeWhenExhausted,
                now: now)
            {
                return combinedText
            }
        }

        let displayPercentWindow: RateWindow? = if let combinedLanes {
            Self.combinedDisplayPercentWindow(lanes: combinedLanes, fallback: percentWindow)
        } else {
            percentWindow
        }
        return MenuBarDisplayText.displayText(
            mode: mode,
            percentWindow: displayPercentWindow,
            pace: pace,
            showUsed: self.settings.usageBarsShowUsed,
            resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
            showsResetTimeWhenExhausted: self.settings.menuBarShowsResetTimeWhenExhausted,
            now: now)
    }

    nonisolated static func deepSeekBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard
            let rawValue = snapshot?.primary?.resetDescription?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !rawValue.isEmpty,
                rawValue.hasPrefix("$") || rawValue.hasPrefix("¥")
        else {
            return nil
        }

        let balance = rawValue.split(separator: " ", maxSplits: 1).first
        return balance.map(String.init)
    }

    nonisolated static func miMoBalanceDisplayText(
        snapshot: UsageSnapshot?,
        preference: MenuBarMetricPreference) -> String?
    {
        guard let snapshot, let mimoUsage = snapshot.mimoUsage else { return nil }
        if snapshot.primary != nil, preference != .secondary { return nil }
        let detail = mimoUsage.balanceDetail
        return detail.components(separatedBy: " (Paid:").first
    }

    nonisolated static func poeBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        self.displayValue(
            from: snapshot?.loginMethod(for: .poe),
            prefix: "Balance:",
            removingSuffix: "")
    }

    nonisolated static func moonshotBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        self.displayValue(
            from: snapshot?.loginMethod(for: .moonshot),
            prefix: "Balance:",
            removingSuffix: "")
            .flatMap { value in
                value
                    .split(separator: "·", maxSplits: 1)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    nonisolated static func mistralSpendDisplayText(snapshot: UsageSnapshot?) -> String? {
        self.displayValue(
            from: snapshot?.identity?.loginMethod,
            prefix: "API spend:",
            removingSuffix: " this month")
    }

    nonisolated static func extraUsageSpendDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard let cost = snapshot?.providerCost,
              cost.limit > 0,
              cost.used >= 0
        else {
            return nil
        }
        return UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
    }

    nonisolated static func openCodeGoZenBalanceDisplayText(snapshot: UsageSnapshot?) -> String? {
        guard snapshot?.primary == nil,
              snapshot?.secondary == nil,
              let cost = snapshot?.providerCost,
              cost.period == "Zen balance"
        else {
            return nil
        }
        return UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
    }

    nonisolated static func kiroDisplayText(
        snapshot: UsageSnapshot?,
        mode: KiroMenuBarDisplayMode,
        showUsed: Bool)
        -> String?
    {
        guard mode != .hidden else { return nil }
        guard let usage = snapshot?.kiroUsage else {
            return MenuBarDisplayText.percentText(window: snapshot?.primary, showUsed: showUsed)
        }
        let percentText = MenuBarDisplayText.percentText(
            window: snapshot?.primary,
            showUsed: showUsed)
        let creditsLeft = UsageFormatter.kiroCreditNumber(usage.creditsRemaining)
        let usedTotal = [
            UsageFormatter.kiroCreditNumber(usage.creditsUsed),
            UsageFormatter.kiroCreditNumber(usage.creditsTotal),
        ].joined(separator: " / ")

        switch mode {
        case .automatic, .creditsLeft:
            if usage.creditsTotal > 0 {
                return creditsLeft
            }
            return percentText
        case .hidden:
            return nil
        case .percentLeft:
            return MenuBarDisplayText.percentText(window: snapshot?.primary, showUsed: false)
        case .creditsAndPercent:
            guard usage.creditsTotal > 0 else { return percentText }
            guard let percentText else { return creditsLeft }
            return "\(creditsLeft) · \(percentText)"
        case .usedAndTotal:
            guard usage.creditsTotal > 0 else { return percentText }
            return usedTotal
        case .overageCreditsWhenExhausted:
            return self.kiroOverageDisplayText(
                usage: usage,
                format: .credits,
                fallback: creditsLeft,
                percentFallback: percentText)
        case .overageCostWhenExhausted:
            return self.kiroOverageDisplayText(
                usage: usage,
                format: .cost,
                fallback: creditsLeft,
                percentFallback: percentText)
        case .overageCreditsAndCostWhenExhausted:
            return self.kiroOverageDisplayText(
                usage: usage,
                format: .creditsAndCost,
                fallback: creditsLeft,
                percentFallback: percentText)
        }
    }

    private enum KiroOverageDisplayFormat {
        case credits
        case cost
        case creditsAndCost
    }

    private nonisolated static func kiroOverageDisplayText(
        usage: KiroUsageDetails,
        format: KiroOverageDisplayFormat,
        fallback: String,
        percentFallback: String?)
        -> String?
    {
        guard usage.creditsTotal > 0 else { return percentFallback }
        guard usage.creditsRemaining <= 0 else { return fallback }
        guard
            usage.overagesStatus?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("enabled") == true
        else {
            return fallback
        }

        let credits = usage.overageCreditsUsed.map { "\(UsageFormatter.kiroCreditNumber($0)) over" }
        let cost = usage.estimatedOverageCostUSD.map { "\(UsageFormatter.usdString($0)) over" }

        switch format {
        case .credits:
            return credits ?? cost ?? fallback
        case .cost:
            return cost ?? credits ?? fallback
        case .creditsAndCost:
            if let credits, let cost {
                let creditsValue = credits.replacingOccurrences(of: " over", with: "")
                let costValue = cost.replacingOccurrences(of: " over", with: "")
                return "\(creditsValue) · \(costValue)"
            }
            return credits ?? cost ?? fallback
        }
    }

    private nonisolated static func displayValue(
        from text: String?,
        prefix: String,
        removingSuffix suffix: String)
        -> String?
    {
        guard let rawValue = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.hasPrefix(prefix)
        else {
            return nil
        }
        let valueStart = rawValue.index(rawValue.startIndex, offsetBy: prefix.count)
        var value = rawValue[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !suffix.isEmpty, value.hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    private func menuBarPercentWindow(for provider: UsageProvider, snapshot: UsageSnapshot?, now: Date)
        -> RateWindow?
    {
        self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now)
    }

    /// Resolves the session (5h) and weekly (7d) lanes for the combined "Session + Weekly" menu-bar
    /// metric, or nil when that metric is not active for `provider`. Codex resolves its lanes through the
    /// consumer projection; Claude has none, so it classifies by window cadence — a 7-day window the OAuth
    /// mapper parked in `primary` (the five_hour fallback) must not be mislabeled as a 5-hour session lane.
    private func combinedSessionWeeklyLanes(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?) -> (session: RateWindow?, weekly: RateWindow?)?
    {
        guard provider == .codex || provider == .claude,
              self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .primaryAndSecondary
        else { return nil }
        // A Claude account that only exposes an enterprise/extra-usage spend limit has no real
        // session/weekly lanes; defer to the resolver's spend-limit routing instead of rendering an
        // empty or 0% placeholder lane under the combined metric.
        if provider == .claude,
           let snapshot,
           MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) != nil
        {
            return nil
        }
        let session = Self.combinedSessionLane(snapshot: snapshot, projection: projection)
        let weekly: RateWindow? = if let projection {
            projection.menuBarSelectableRateWindow(for: .weekly)
        } else {
            Self.rateWindow(in: snapshot, matchingCadenceMinutes: Self.weeklyWindowMinutes)
        }
        return (session, weekly)
    }

    /// Reset dates for every lane whose menu-bar text is currently rendered as a reset time, so the
    /// countdown scheduler can refresh each of them. Reset-time mode drives a single window. The smart
    /// "reset time when exhausted" option can surface BOTH combined session/weekly lanes in percent mode,
    /// while pace/both render the one lane chosen by `combinedDisplayPercentWindow` — mirror that presentation
    /// here rather than scheduling whichever lane happened to drive the icon.
    func menuBarDisplayedResetDates(for provider: UsageProvider, now: Date) -> [Date] {
        let snapshot = self.store.snapshot(for: provider)
        let mode = self.settings.menuBarDisplayMode

        let projection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: now)
        if let lanes = self.combinedSessionWeeklyLanes(
            for: provider, snapshot: snapshot, projection: projection),
            lanes.session != nil || lanes.weekly != nil
        {
            switch mode {
            case .percent:
                // Percent renders both lanes independently, so schedule every exhausted reset.
                return [lanes.session, lanes.weekly]
                    .compactMap(\.self)
                    .filter { $0.remainingPercent <= 0 }
                    .compactMap(\.resetsAt)
            case .pace, .both:
                // Pace/both render one usage lane alongside the weekly pace. Use that exact lane rather
                // than `menuBarMetricWindow`, whose tie-breaking can select the other exhausted window.
                let window = Self.combinedDisplayPercentWindow(
                    lanes: lanes,
                    fallback: self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now))
                guard let window, window.remainingPercent <= 0 else { return [] }
                return window.resetsAt.map { [$0] } ?? []
            case .resetTime:
                break
            }
        }

        guard let window = self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now)
        else { return [] }
        // Outside reset-time mode the reset text is only visible once the quota is exhausted.
        if mode != .resetTime, window.remainingPercent > 0 { return [] }
        return window.resetsAt.map { [$0] } ?? []
    }

    /// The combined metric's session (5h) lane. Codex resolves it through the consumer projection; other
    /// providers classify by window cadence. A 5-hour lane the provider only synthesized to stand in for an
    /// absent session — Claude web's null `five_hour` placeholder, flagged at the boundary — is dropped so a
    /// weekly-only account falls back to its weekly lane instead of rendering a phantom `5h 0%`/`5h 100%`
    /// session. A genuine session (even one freshly reset to 0%) is not flagged, so it is kept.
    private static func combinedSessionLane(
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?) -> RateWindow?
    {
        if let projection {
            return projection.menuBarSelectableRateWindow(for: .session)
        }
        guard let session = Self.rateWindow(in: snapshot, matchingCadenceMinutes: Self.sessionWindowMinutes)
        else { return nil }
        if session.isSyntheticPlaceholder {
            return nil
        }
        return session
    }

    /// The window the weekly pace is computed on in pace/both modes. Codex paces on its projected weekly
    /// lane; the combined Session + Weekly metric paces on the weekly lane too (matching Codex); Abacus
    /// has no secondary window so it paces on the primary monthly credits; everything else paces on the
    /// selected percent window.
    private func menuBarPaceWindow(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        projection: CodexConsumerProjection?,
        combinedLanes: (session: RateWindow?, weekly: RateWindow?)?,
        percentWindow: RateWindow?) -> RateWindow?
    {
        if let projection {
            return projection.menuBarSelectableRateWindow(for: .weekly)
        }
        if provider == .abacus {
            return snapshot?.primary
        }
        if let combinedLanes {
            return combinedLanes.weekly
        }
        return percentWindow
    }

    /// The usage window shown for the combined metric in pace/both modes. It pairs the SESSION usage with
    /// the weekly pace, so the usage component normally comes from the session lane — not the
    /// most-constrained lane that drives the icon/bar. Two exceptions: fall back to the weekly lane when no
    /// session lane exists (the five_hour OAuth fallback or Claude web's filtered null-session
    /// placeholder), and surface the weekly lane when it is exhausted
    /// — it is then the binding cap with no pace to show, and a roomy session number would hide it.
    private static func combinedDisplayPercentWindow(
        lanes: (session: RateWindow?, weekly: RateWindow?),
        fallback: RateWindow?) -> RateWindow?
    {
        if let weekly = lanes.weekly, weekly.remainingPercent <= 0 {
            return weekly
        }
        return lanes.session ?? lanes.weekly ?? fallback
    }

    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    /// Returns the first session/weekly snapshot lane whose window cadence matches `minutes`.
    /// Used by the combined Session + Weekly metric for providers without a Codex consumer
    /// projection so a fallback weekly window parked in `primary` is not mislabeled as a session lane.
    private static func rateWindow(in snapshot: UsageSnapshot?, matchingCadenceMinutes minutes: Int) -> RateWindow? {
        [snapshot?.primary, snapshot?.secondary]
            .compactMap(\.self)
            .first { $0.windowMinutes == minutes }
    }

    func primaryProviderForUnifiedIcon() -> UsageProvider {
        // When "show highest usage" is enabled, rank the existing Overview subset by proximity to its limit.
        if self.settings.menuBarShowsHighestUsage, self.shouldMergeIcons {
            let activeProviders = self.store.enabledProvidersForDisplay()
            let overviewProviders = self.settings.resolvedMergedOverviewProviders(
                activeProviders: activeProviders,
                maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
            if let highest = self.store.providerWithHighestUsage(candidateProviders: overviewProviders) {
                return highest.provider
            }
            // A nonempty Overview selection remains authoritative while its providers are loading,
            // unrankable, or exhausted. Only an explicitly empty Overview may use the broad fallback.
            if let fallback = overviewProviders.first(where: { self.store.isEnabled($0) }) {
                return fallback
            }
        }
        if self.shouldMergeIcons, self.settings.mergedMenuLastSelectedWasOverview {
            let enabledProviders = self.store.enabledProvidersForDisplay()
            let overviewProviders = self.settings.resolvedMergedOverviewProviders(
                activeProviders: enabledProviders,
                maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
            if let provider = overviewProviders.first(where: { self.store.isEnabled($0) }) {
                return provider
            }
        }
        if self.shouldMergeIcons,
           let selected = self.selectedMenuProvider,
           self.store.isEnabled(selected)
        {
            return selected
        }
        for provider in self.store.enabledProviders() {
            if self.store.isEnabled(provider), self.store.snapshot(for: provider) != nil {
                return provider
            }
        }
        // Use availability-filtered list: fallback must pick a provider that can
        // actually animate, otherwise shouldAnimate() fails on credential-less providers.
        if let enabled = self.store.enabledProviders().first {
            return enabled
        }
        return .codex
    }

    @objc func handleDebugBlinkNotification() {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        self.forceBlinkNow()
    }

    private func forceBlinkNow() {
        let now = Date()
        self.blinkForceUntil = now.addingTimeInterval(0.6)
        self.seedBlinkStatesIfNeeded()

        for provider in UsageProvider.allCases {
            let shouldBlink =
                self.shouldMergeIcons ? self.isEnabled(provider) : self.isVisible(provider)
            guard shouldBlink, !self.shouldAnimate(provider: provider) else { continue }
            var state =
                self
                    .blinkStates[provider]
                    ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
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

    func shouldAnimate(provider: UsageProvider, mergeIcons: Bool? = nil) -> Bool {
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
        let hasSatisfiedUsageFetch = self.store.hasSatisfiedUsageFetch(for: provider)
        if provider == .warp, !hasSatisfiedUsageFetch, self.store.refreshingProviders.contains(provider) {
            return true
        }
        return !hasSatisfiedUsageFetch && !isStale
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
                self.animationStartedAt = Date()
                let driver = DisplayLinkDriver(onTick: { [weak self] in
                    self?.updateAnimationFrame()
                })
                self.animationDriver = driver
                driver.start(fps: Self.loadingAnimationFPS)
            } else if let forced = self.settings.debugLoadingPattern,
                      forced != self.animationPattern
            {
                self.animationPattern = forced
                self.animationPhase = 0
            }
        } else {
            self.stopLoadingAnimation()
        }
    }

    private func stopLoadingAnimation() {
        self.animationDriver?.stop()
        self.animationDriver = nil
        self.animationPhase = 0
        self.animationStartedAt = nil
        if self.shouldMergeIcons {
            self.applyIcon(phase: nil)
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: nil) }
        }
    }

    private func updateAnimationFrame() {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        if let startedAt = self.animationStartedAt,
           Date().timeIntervalSince(startedAt) > Self.loadingAnimationMaxContinuousDuration
        {
            self.stopLoadingAnimation()
            return
        }
        self.animationPhase += Self.loadingAnimationPhaseIncrement
        if self.shouldMergeIcons {
            self.applyIcon(phase: self.animationPhase)
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: self.animationPhase) }
        }
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

    private nonisolated static func drawBrandStatusOverlay(
        indicator: ProviderStatusIndicator, size: NSSize)
    {
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
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
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
