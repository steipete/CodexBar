enum MistralTokenMath {
    static func total(input: Int, cached: Int, output: Int) -> Int? {
        let lanes = [input, cached, output].sorted()
        // Opposite-sign extremes cancel safely; same-sign overflow cannot be canceled by the middle lane.
        return CheckedSum.integers([lanes[0], lanes[2], lanes[1]])
    }
}
