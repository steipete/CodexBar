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
    private nonisolated static let loadingAnimationMaxContinuousDuration: TimeInterval = 30.0
    func needsMenuBarIconAnimation() -> Bool {
        if self.shouldMergeIcons {
            let primaryProvider = self.primaryProviderForUnifiedIcon()
            return self.shouldAnimate(provider: primaryProvider)
        }
        return UsageProvider.allCases.contains { self.shouldAnimate(provider: $0) }
    }

    func activeLoadingAnimationPhase() -> Double? {
        guard self.needsMenuBarIconAnimation(), self.animationDriver != nil else { return nil }
        return self.animationPhase
    }

    func anyEnabledProviderNeedsLoadingAnimation() -> Bool {
        UsageProvider.allCases.contains {
            self.isEnabled($0) && self.shouldAnimate(provider: $0, mergeIcons: false)
        }
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
        for provider in UsageProvider.allCases where self.blinkStates[provider.instanceID] == nil {
            self.blinkStates[provider.instanceID] = BlinkState(
                nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
        }
    }

    private func stopBlinking() {
        self.blinkTask?.cancel()
        self.blinkTask = nil
        self.blinkAmounts.removeAll()
        let phase: Double? = self.activeLoadingAnimationPhase()
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
                    .blinkStates[provider.instanceID]
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
        if delay <= 0 {
            return Self.blinkActiveTickInterval
        }
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
                    .blinkStates[provider.instanceID]
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

            self.blinkStates[provider.instanceID] = state
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
        return self.blinkAmounts[provider.instanceID] ?? 0
    }

    private func wiggleAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.wiggleAmounts[provider.instanceID] ?? 0
    }

    private func tiltAmount(for provider: UsageProvider) -> CGFloat {
        guard self.isBlinkingAllowed() else { return 0 }
        return self.tiltAmounts[provider.instanceID] ?? 0
    }

    private func assignMotion(amount: CGFloat, for provider: UsageProvider, effect: MotionEffect) {
        switch effect {
        case .blink:
            self.blinkAmounts[provider.instanceID] = amount
            self.wiggleAmounts[provider.instanceID] = 0
            self.tiltAmounts[provider.instanceID] = 0
        case .wiggle:
            self.wiggleAmounts[provider.instanceID] = amount
            self.blinkAmounts[provider.instanceID] = 0
            self.tiltAmounts[provider.instanceID] = 0
        case .tilt:
            self.tiltAmounts[provider.instanceID] = amount
            self.blinkAmounts[provider.instanceID] = 0
            self.wiggleAmounts[provider.instanceID] = 0
        }
    }

    private func clearMotion(for provider: UsageProvider) {
        self.blinkAmounts[provider.instanceID] = 0
        self.wiggleAmounts[provider.instanceID] = 0
        self.tiltAmounts[provider.instanceID] = 0
    }

    private func randomEffect(for provider: UsageProvider) -> MotionEffect {
        // Provider-specific by design: Claude's star glyph uses wiggle rather than rotational tilt.
        if provider == .claude {
            Bool.random() ? .blink : .wiggle
        } else {
            Bool.random() ? .blink : .tilt
        }
    }

    private func isBlinkingAllowed(at date: Date = .init()) -> Bool {
        if self.settings.randomBlinkEnabled {
            return true
        }
        if let until = self.blinkForceUntil, until > date {
            return true
        }
        self.blinkForceUntil = nil
        return false
    }

    @discardableResult
    // swiftlint:disable:next function_body_length
    func applyIcon(
        phase: Double?,
        bypassMergedMenuTrackingDeferral: Bool = false) -> Bool
    {
        guard let button = self.statusItem.button else { return false }
        if !bypassMergedMenuTrackingDeferral,
           self.deferMergedIconRenderDuringMenuTrackingIfNeeded()
        {
            return true
        }

        let style = self.store.iconStyle
        let showUsed = self.settings.usageBarsShowUsed
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        let primaryProvider = self.primaryProviderForUnifiedIcon()
        let resolverStyle = self.store.style(for: primaryProvider)
        let snapshot = self.store.menuBarSnapshot(for: primaryProvider.instanceID)
        let warningFlash = self.quotaWarningFlashActive(provider: primaryProvider)

        if let layoutResult = self.applyStoredUnifiedMenuBarLayoutIfNeeded(
            provider: primaryProvider,
            snapshot: snapshot,
            warningFlash: warningFlash)
        {
            return layoutResult
        }

        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let resolved = self.resolvedMenuBarIconPercents(
            provider: primaryProvider,
            snapshot: snapshot,
            style: resolverStyle,
            showUsed: showUsed)
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
                hideCritters: self.settings.menuBarHidesCritters,
                quotaLayoutPolicy: .provider(primaryProvider))
            self.setButtonContent(
                image: warningFlash ? Self.quotaWarningFlashImage(base: image) : image,
                title: nil,
                for: button)
        }
        self.noteIconPerfRender(skipped: false)
        return false
    }

    private func applyStoredUnifiedMenuBarLayoutIfNeeded(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        warningFlash: Bool)
        -> Bool?
    {
        guard self.settings.menuBarShowsBrandIconWithPercent else {
            self.statusItem.length = NSStatusItem.variableLength
            return nil
        }
        guard let wasCached = self.applyStoredMenuBarLayoutIfNeeded(
            provider: provider,
            snapshot: snapshot,
            icon: ProviderBrandIcon.image(for: provider),
            warningFlash: warningFlash,
            statusItem: self.statusItem)
        else { return nil }
        self.noteIconPerfRender(skipped: wasCached)
        return wasCached
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
        if self.lastAppliedProviderIconRenderSignatures[provider.instanceID] == signature {
            return true
        }
        self.lastAppliedProviderIconRenderSignatures[provider.instanceID] = signature
        return false
    }

    private struct ProviderIconRenderInput {
        let provider: UsageProvider
        let button: NSStatusBarButton
        let snapshot: UsageSnapshot?
        let stale: Bool
        let statusIndicator: ProviderStatusIndicator
        let phase: Double?
        let shouldAnimate: Bool
        let accountScoped: Bool
    }

    @discardableResult
    func applyIcon(for provider: UsageProvider, phase: Double?) -> Bool {
        guard let statusItem = self.statusItems[provider.instanceID],
              let button = statusItem.button
        else { return false }
        let snapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        let showBrandPercent = self.settings.menuBarShowsBrandIconWithPercent
        if !showBrandPercent {
            statusItem.length = NSStatusItem.variableLength
        }
        let warningFlash = self.quotaWarningFlashActive(provider: provider)
        if showBrandPercent,
           let wasCached = self.applyStoredMenuBarLayoutIfNeeded(
               provider: provider,
               snapshot: snapshot,
               icon: ProviderBrandIcon.image(for: provider),
               warningFlash: warningFlash,
               statusItem: statusItem)
        {
            self.noteIconPerfRender(skipped: wasCached)
            return wasCached
        }
        return self.renderProviderIcon(
            ProviderIconRenderInput(
                provider: provider,
                button: button,
                snapshot: snapshot,
                stale: self.store.isStale(provider: provider),
                statusIndicator: self.store.statusIndicator(for: provider),
                phase: phase,
                shouldAnimate: true,
                accountScoped: false),
            shouldSkip: { self.shouldSkipProviderIconRender(provider: provider, signature: $0) })
    }

    @discardableResult
    func applyIcon(
        for key: AccountStatusItemKey,
        context: AccountStatusItemContext,
        phase: Double?) -> Bool
    {
        guard let statusItem = self.accountStatusItems[key],
              let button = statusItem.button
        else { return false }
        if !self.settings.menuBarShowsBrandIconWithPercent {
            statusItem.length = NSStatusItem.variableLength
        }
        let accountSnapshot: (snapshot: UsageSnapshot?, error: String?)? = switch context {
        case let .token(provider, account):
            self.store.accountSnapshots[provider.instanceID]?
                .first(where: { $0.account.id == account.id })
                .map { ($0.snapshot, $0.error) }
        case let .codex(account):
            self.store.codexAccountSnapshots
                .first(where: { $0.id == account.id })
                .map { ($0.snapshot, $0.error) }
        }
        return self.renderProviderIcon(
            ProviderIconRenderInput(
                provider: context.provider,
                button: button,
                snapshot: accountSnapshot?.snapshot,
                stale: accountSnapshot?.error != nil,
                statusIndicator: accountSnapshot?.error == nil ? .none : .major,
                phase: phase,
                shouldAnimate: false,
                accountScoped: true),
            shouldSkip: {
                if self.lastAppliedAccountIconRenderSignatures[key] == $0 { return true }
                self.lastAppliedAccountIconRenderSignatures[key] = $0
                return false
            })
    }

    private func renderBrandPercentIcon(
        _ input: ProviderIconRenderInput,
        style: IconStyle,
        warningFlash: Bool,
        shouldSkip: (String) -> Bool) -> Bool?
    {
        guard self.settings.menuBarShowsBrandIconWithPercent,
              let brand = ProviderBrandIcon.image(for: input.provider)
        else { return nil }
        let displayText = input.accountScoped && input.snapshot == nil
            ? nil
            : self.menuBarDisplayText(
                for: input.provider,
                snapshot: input.snapshot,
                accountScoped: input.accountScoped)
        let displayedImage = warningFlash ? Self.quotaWarningFlashImage(base: brand) : brand
        let signature = [
            "mode=brandPercent",
            "provider=\(input.provider.rawValue)",
            "style=\(String(describing: style))",
            "text=\(displayText ?? "nil")",
            "warningFlash=\(warningFlash ? "1" : "0")",
            "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
        ].joined(separator: "|")
        if shouldSkip(signature) {
            self.setButtonContent(image: displayedImage, title: displayText, for: input.button)
            self.noteIconPerfRender(skipped: true)
            return true
        }
        self.setButtonContent(image: displayedImage, title: displayText, for: input.button)
        self.noteIconPerfRender(skipped: false)
        return false
    }

    private func renderProviderIcon(
        _ input: ProviderIconRenderInput,
        shouldSkip: (String) -> Bool) -> Bool
    {
        let provider = input.provider
        let button = input.button
        let snapshot = input.snapshot
        let initialStale = input.stale
        let statusIndicator = input.statusIndicator
        let phase = input.phase
        let shouldAnimate = input.shouldAnimate
        let accountScoped = input.accountScoped
        // IconRenderer treats these values as a left-to-right "progress fill" percentage; depending on the
        // user setting we pass either "percent left" or "percent used".
        let showUsed = self.settings.usageBarsShowUsed
        let style: IconStyle = self.store.style(for: provider)
        let warningFlash = accountScoped ? false : self.quotaWarningFlashActive(provider: provider)
        if let result = self.renderBrandPercentIcon(
            input,
            style: style,
            warningFlash: warningFlash,
            shouldSkip: shouldSkip)
        {
            return result
        }

        // OpenRouter always gets a meter here — the brand-logo fallback was removed on purpose.
        let resolved = self.resolvedMenuBarIconPercents(
            provider: provider,
            snapshot: snapshot,
            style: style,
            showUsed: showUsed)
        var primary = resolved?.primary
        var weekly = resolved?.secondary
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: accountScoped ? .overrideCard : .menuBar,
            snapshotOverride: snapshot,
            now: snapshot?.updatedAt ?? Date())
        var credits: Double? = if accountScoped {
            codexProjection?.menuBarFallback == .creditsBalance
                ? codexProjection?.credits?.remaining
                : nil
        } else {
            self.menuBarCreditsRemainingForIcon(provider: provider, snapshot: snapshot)
        }
        var stale = initialStale
        var morphProgress: Double?

        if shouldAnimate, let phase, self.shouldAnimate(provider: provider) {
            var pattern = self.animationPattern
            // Provider-specific by design: Claude's star glyph cannot render the icon-only unbraid transition.
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

        let isLoading = shouldAnimate && phase != nil && self.shouldAnimate(provider: provider)
        let blink: CGFloat = {
            guard isLoading, style == .warp, let phase else {
                return self.blinkAmount(for: provider)
            }
            let normalized = (sin(phase * 3) + 1) / 2
            return CGFloat(max(0, min(normalized, 1)))
        }()
        let wiggle = self.wiggleAmount(for: provider)
        let tilt = self.tiltAmount(for: provider) * .pi / 28 // limit to ~6.4°
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
            if shouldSkip(signature), canSkipCachedRender {
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
            if shouldSkip(signature), canSkipCachedRender {
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
                hideCritters: self.settings.menuBarHidesCritters,
                quotaLayoutPolicy: .provider(provider))
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
        showUsed: Bool)
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
        // Provider-specific by design: Mistral's balance/spend text replaces percentage lanes in its icon.
        if provider == .mistral {
            return (primary: nil, secondary: nil)
        }
        return IconRemainingResolver.resolvedPercents(
            snapshot: snapshot,
            style: style,
            showUsed: showUsed,
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
        // Provider-specific by design: only Codex projects credits into the menu-bar icon fallback.
        guard provider == .codex else { return nil }
        return self.store.codexMenuBarCreditsRemaining(
            snapshotOverride: snapshot,
            now: now)
    }

    func quotaWarningFlashActive(provider: UsageProvider, now: Date = Date()) -> Bool {
        guard let until = self.quotaWarningFlashUntil[provider.instanceID] else { return false }
        if until > now {
            return true
        }
        self.quotaWarningFlashUntil.removeValue(forKey: provider.instanceID)
        self.quotaWarningFlashTasks[provider.instanceID]?.cancel()
        self.quotaWarningFlashTasks.removeValue(forKey: provider.instanceID)
        return false
    }

    func startQuotaWarningFlash(provider: UsageProvider, postedAt: Date = Date()) {
        let until = postedAt.addingTimeInterval(Self.quotaWarningFlashDuration)
        self.quotaWarningFlashUntil[provider.instanceID] = until
        self.quotaWarningFlashTasks[provider.instanceID]?.cancel()
        self.updateIcons()
        self.applyQuotaWarningIconDuringMergedMenuTrackingIfNeeded()
        self.quotaWarningFlashTasks[provider.instanceID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.quotaWarningFlashDuration))
            await MainActor.run { [weak self] in
                self?.clearExpiredQuotaWarningFlash(provider: provider)
            }
        }
    }

    func clearExpiredQuotaWarningFlash(provider: UsageProvider, now: Date = Date()) {
        guard let currentUntil = self.quotaWarningFlashUntil[provider.instanceID],
              currentUntil <= now
        else {
            return
        }
        self.quotaWarningFlashUntil.removeValue(forKey: provider.instanceID)
        self.quotaWarningFlashTasks.removeValue(forKey: provider.instanceID)
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

    var shouldUseHighContrastStatusItemContent: Bool {
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

    func primaryProviderForUnifiedIcon() -> UsageProvider {
        // When "show highest usage" is enabled, rank the existing Overview subset by proximity to its limit.
        if self.settings.menuBarShowsHighestUsage, self.shouldMergeIcons {
            let activeProviders = self.store.enabledFirstPartyProvidersForDisplay()
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
            let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
            let overviewProviders = self.settings.resolvedMergedOverviewProviders(
                activeProviders: enabledProviders,
                maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
            if let provider = overviewProviders.first(where: { self.store.isEnabled($0) }) {
                return provider
            }
        }
        if self.shouldMergeIcons,
           let selected = self.selectedMenuProvider?.firstPartyProvider,
           self.store.isEnabled(selected)
        {
            return selected
        }
        for provider in self.store.enabledFirstPartyProviders() {
            if self.store.isEnabled(provider), self.store.menuBarSnapshot(for: provider.instanceID) != nil {
                return provider
            }
        }
        // Use availability-filtered list: fallback must pick a provider that can
        // actually animate, otherwise shouldAnimate() fails on credential-less providers.
        if let enabled = self.store.enabledFirstPartyProviders().first {
            return enabled
        }
        // Provider-specific by design: Codex remains the placeholder icon when no provider can animate.
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
                    .blinkStates[provider.instanceID]
                    ?? BlinkState(nextBlink: now.addingTimeInterval(BlinkState.randomDelay()))
            state.blinkStart = now
            state.pendingSecondStart = nil
            state.effect = self.randomEffect(for: provider)
            state.nextBlink = now.addingTimeInterval(BlinkState.randomDelay())
            self.blinkStates[provider.instanceID] = state
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
        if self.store.debugForceAnimation {
            return true
        }

        let isMerged = mergeIcons ?? self.shouldMergeIcons
        let isVisible = isMerged ? self.isEnabled(provider) : self.isVisible(provider)
        guard isVisible else { return false }

        // Don't animate for fallback provider - it's only shown as a placeholder when nothing is enabled.
        // Animating the fallback causes unnecessary CPU usage (battery drain). See #269, #139.
        let isEnabled = self.isEnabled(provider)
        let isFallbackOnly = !isEnabled && self.fallbackProvider == provider
        if isFallbackOnly {
            return false
        }

        let isStale = self.store.isStale(provider: provider)
        let hasSatisfiedUsageFetch = self.store.hasSatisfiedUsageFetch(for: provider)
        // Provider-specific by design: Warp animates while its first remote refresh is still in flight.
        if provider == .warp, !hasSatisfiedUsageFetch, self.store.refreshingProviders.contains(provider.instanceID) {
            return true
        }
        return !hasSatisfiedUsageFetch && !isStale
    }

    func updateAnimationState() {
        let needsAnimation = self.needsMenuBarIconAnimation()
        let stillLoading = self.anyEnabledProviderNeedsLoadingAnimation()
        if self.animationStartedAt == .distantPast {
            if !stillLoading {
                self.animationStartedAt = nil
            }
            if !needsAnimation {
                self.stopLoadingAnimation(resetStart: false)
            }
            return
        }
        if !needsAnimation {
            self.animationStartedAt = nil
            self.stopLoadingAnimation()
            return
        }
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
    }

    private func stopLoadingAnimation(resetStart: Bool = true) {
        self.animationDriver?.stop()
        self.animationDriver = nil
        self.animationPhase = 0
        if resetStart {
            self.animationStartedAt = nil
        }
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
        if Self.loadingAnimationHasExceededContinuousCap(startedAt: self.animationStartedAt, now: Date()) {
            self.animationStartedAt = .distantPast
            self.stopLoadingAnimation(resetStart: false)
            return
        }
        self.animationPhase += Self.loadingAnimationPhaseIncrement
        if self.shouldMergeIcons {
            self.applyIcon(phase: self.animationPhase)
        } else {
            UsageProvider.allCases.forEach { self.applyIcon(for: $0, phase: self.animationPhase) }
        }
    }

    nonisolated static func loadingAnimationHasExceededContinuousCap(
        startedAt: Date?,
        now: Date) -> Bool
    {
        guard let startedAt, startedAt != .distantPast else { return false }
        return now.timeIntervalSince(startedAt) > Self.loadingAnimationMaxContinuousDuration
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
