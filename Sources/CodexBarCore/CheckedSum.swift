package enum CheckedSum {
    /// Empty input sums to zero. Missing-value policy belongs to the caller; any overflow
    /// invalidates the entire sum, even if later values would bring it back into range.
    package static func integers(_ values: some Sequence<Int>) -> Int? {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total
    }
}
