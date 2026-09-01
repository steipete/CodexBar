/// The trigger and content are separate windows but share one hover interaction.
struct NotchHoverState {
    enum Region: Hashable {
        case trigger
        case content
    }

    enum Transition: Equatable {
        case entered
        case exited
        case unchanged
    }

    private var regions: Set<Region> = []

    var isInside: Bool {
        !self.regions.isEmpty
    }

    @discardableResult
    mutating func update(_ region: Region, isInside: Bool) -> Transition {
        let wasInside = self.isInside
        if isInside {
            self.regions.insert(region)
        } else {
            self.regions.remove(region)
        }
        guard wasInside != self.isInside else { return .unchanged }
        return self.isInside ? .entered : .exited
    }

    mutating func clear() {
        self.regions.removeAll()
    }
}
