import Darwin

enum MemoryPressureRelief {
    static func releaseFreeMallocPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
