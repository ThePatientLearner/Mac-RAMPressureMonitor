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
            kernelLevel: kernelPressureLevel())
    }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &len, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
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

// MARK: - Disco

struct DiskSample {
    var freeBytes: UInt64      // libre de verdad: lo que cuentan `df` y el Finder
    var totalBytes: UInt64
    var usedBytes: UInt64
    var purgeableBytes: UInt64 // caché que el sistema soltaría, no es espacio libre

    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

/// Lee el volumen de arranque.
///
/// La cifra base sale de `statfs`, que sobre `/` informa del contenedor APFS
/// entero — System, Preboot, Recovery, Data, VM y los snapshots locales, si los
/// hay — y no sólo del volumen montado. Coincide con "Capacity Not Allocated"
/// de `diskutil apfs list`. En APFS no hay reserva para root, así que `f_bavail`
/// y `f_bfree` son el mismo número.
///
/// Aparte está el espacio *purgable*: caché que macOS tiraría si hiciera falta.
/// No es espacio libre, así que no entra en la cifra principal, pero se enseña
/// en el menú. Obtenerlo cuesta unos 20 ms frente a los 0,001 ms de `statfs`,
/// de modo que se refresca como mucho cada `purgeableInterval`.
final class DiskReader {
    private let path: String
    private let purgeableInterval: TimeInterval
    private var purgeable: UInt64 = 0
    private var lastPurgeableRead: Date?

    init(path: String = "/", purgeableInterval: TimeInterval = 30) {
        self.path = path
        self.purgeableInterval = purgeableInterval
    }

    func read(force: Bool = false) -> DiskSample? {
        guard var sample = measure() else { return nil }
        refreshPurgeable(freeBytes: sample.freeBytes, force: force)
        sample.purgeableBytes = purgeable
        return sample
    }

    private func measure() -> DiskSample? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_blocks > 0 else { return nil }

        let block = UInt64(fs.f_bsize)
        let total = UInt64(fs.f_blocks) * block
        let free = min(UInt64(fs.f_bavail) * block, total)

        return DiskSample(
            freeBytes: free,
            totalBytes: total,
            usedBytes: total - free,
            purgeableBytes: 0)
    }

    private func refreshPurgeable(freeBytes: UInt64, force: Bool) {
        if !force, let last = lastPurgeableRead,
           Date().timeIntervalSince(last) < purgeableInterval { return }

        // Instancia nueva a propósito: NSURL cachea los valores de recurso, así
        // que reutilizar la misma URL devolvería siempre la primera lectura.
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let important = values.volumeAvailableCapacityForImportantUsage
        else { return }

        let withPurgeable = UInt64(max(0, important))
        purgeable = withPurgeable > freeBytes ? withPurgeable - freeBytes : 0
        lastPurgeableRead = Date()
    }
}
