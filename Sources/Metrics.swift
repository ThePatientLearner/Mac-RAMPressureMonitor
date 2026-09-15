import Foundation

// MARK: - Niveles con histéresis

enum Level {
    case ok, warn, critical
}

/// Clasifica un valor 0...1 en verde/naranja/rojo, exigiendo cruzar el umbral
/// con un margen para volver atrás. Así el color no parpadea en el borde.
struct LevelTracker {
    let warnAt: Double
    let critAt: Double
    let margin: Double
    private(set) var level: Level = .ok

    mutating func update(_ value: Double, floor: Level = .ok) -> Level {
        switch level {
        case .ok:
            if value >= critAt { level = .critical }
            else if value >= warnAt { level = .warn }
        case .warn:
            if value >= critAt { level = .critical }
            else if value < warnAt - margin { level = .ok }
        case .critical:
            if value < critAt - margin { level = value >= warnAt ? .warn : .ok }
        }
        // El kernel puede forzar un nivel mínimo aunque el porcentaje no llegue.
        if floor == .critical { level = .critical }
        else if floor == .warn && level == .ok { level = .warn }
        return level
    }
}

// MARK: - Memoria

struct MemorySample {
    var pressure: Double      // 0...1, réplica del gráfico de Monitor de Actividad
    var usedBytes: UInt64     // app + wired + comprimida
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64
    var totalBytes: UInt64
    var swapUsedBytes: UInt64
    var freeFraction: Double  // 0...1, el mismo dato que reporta `memory_pressure`
    var kernelLevel: Int32    // 1 normal, 2 warn, 4 critical

    var kernelFloor: Level {
        if kernelLevel >= 4 { return .critical }
        if kernelLevel >= 2 { return .warn }
        return .ok
    }
}

enum MemoryReader {
    static let pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    static let totalBytes: UInt64 = {
        var value: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &len, nil, 0)
        return value
    }()

    static func read() -> MemorySample? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = pageSize
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let internalBytes = UInt64(stats.internal_page_count) * page
        let external = UInt64(stats.external_page_count) * page

        let app = internalBytes > purgeable ? internalBytes - purgeable : 0
        let total = totalBytes

        // Monitor de Actividad calcula la presión sobre la memoria que no se
        // puede liberar sin más: la wired y la comprimida.
        let pressure = total > 0 ? Double(wired + compressed) / Double(total) : 0

        return MemorySample(
            pressure: min(pressure, 1.0),
            usedBytes: app + wired + compressed,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            cachedBytes: external + purgeable,
            totalBytes: total,
            swapUsedBytes: swapUsed(),
            freeFraction: freeFraction(),
            kernelLevel: kernelPressureLevel())
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// macOS mantiene el porcentaje de memoria libre en un sysctl propio: es el
    /// mismo valor que imprime `memory_pressure`, así que no hay que derivarlo.
    private static func freeFraction() -> Double {
        var value: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &value, &len, nil, 0) == 0
        else { return 0 }
        return min(max(Double(value) / 100.0, 0), 1)
    }

    private static func kernelPressureLevel() -> Int32 {
        var value: Int32 = 1
        var len = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &len, nil, 0) == 0
        else { return 1 }
        return value
    }
}

// MARK: - CPU

struct CPUSample {
    var total: Double   // 0...1
    var user: Double
    var system: Double
}

/// Lee los ticks acumulados del kernel y devuelve el uso del intervalo
/// transcurrido desde la lectura anterior.
final class CPUReader {
    private var previous: host_cpu_load_info?

    func read() -> CPUSample? {
        guard let now = ticks() else { return nil }
        defer { previous = now }
        guard let before = previous else { return nil }

        let user = Double(now.cpu_ticks.0 &- before.cpu_ticks.0)
        let nice = Double(now.cpu_ticks.3 &- before.cpu_ticks.3)
        let system = Double(now.cpu_ticks.1 &- before.cpu_ticks.1)
        let idle = Double(now.cpu_ticks.2 &- before.cpu_ticks.2)

        let total = user + nice + system + idle
        guard total > 0 else { return nil }

        return CPUSample(
            total: min((user + nice + system) / total, 1.0),
            user: (user + nice) / total,
            system: system / total)
    }

    private func ticks() -> host_cpu_load_info? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}
