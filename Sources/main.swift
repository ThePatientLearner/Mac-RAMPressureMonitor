import AppKit
import ServiceManagement

// MARK: - Preferencias

enum Prefs {
    private static let intervalKey = "refreshInterval"

    static var interval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return [1.0, 2.0, 5.0].contains(stored) ? stored : 2.0
        }
        set { UserDefaults.standard.set(newValue, forKey: intervalKey) }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let cpuReader = CPUReader()
    private var timer: Timer?

    // Umbrales del plan, con 3 puntos de histéresis.
    private var ramLevel = LevelTracker(warnAt: 0.60, critAt: 0.80, margin: 0.03)
    private var cpuLevel = LevelTracker(warnAt: 0.60, critAt: 0.85, margin: 0.03)
    // Se alimenta con la fracción ocupada del SSD (1 - libre), así el verde es
    // mucho espacio libre y el rojo quedarse sin sitio.
    private var diskLevel = LevelTracker(warnAt: 0.80, critAt: 0.90, margin: 0.02)

    private var memory: MemorySample?
    private var cpu: CPUSample?
    private var disk: DiskSample?

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.imagePosition = .noImage
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        render()
        _ = cpuReader.read()  // línea base para el primer delta
        startTimer()
        enableLaunchAtLoginOnFirstRun()
    }

    /// Queda registrada como item de inicio la primera vez que arranca, que es lo
    /// que espera quien instala un monitor de barra: tras un reinicio debe seguir
    /// ahí. Solo se hace una vez; si luego se desactiva desde el menú, esa
    /// decisión se respeta y no se vuelve a registrar sola.
    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLoginItem"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Prefs.interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = Prefs.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Primera medida real enseguida, sin esperar al intervalo completo.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.tick() }
    }

    private func tick() {
        memory = MemoryReader.read()
        disk = DiskReader.read()
        if let sample = cpuReader.read() { cpu = sample }
        render()
    }

    // MARK: - Barra

    private func render() {
        guard let button = statusItem.button else { return }

        let text = NSMutableAttributedString()
        text.append(label("RAMp "))
        if let memory {
            let level = ramLevel.update(memory.pressure, floor: memory.kernelFloor)
            text.append(value(memory.pressure, level: level))
        } else {
            text.append(label("--%"))
        }
        text.append(label("  Libre "))
        if let disk {
            let level = diskLevel.update(1 - disk.freeFraction)
            text.append(coloured(gigabytes(disk.availableBytes), level: level))
        } else {
            text.append(label("--"))
        }
        text.append(label("  CPU "))
        if let cpu {
            let level = cpuLevel.update(cpu.total)
            text.append(value(cpu.total, level: level))
        } else {
            text.append(label("--%"))
        }

        button.attributedTitle = text
    }

    private var barFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    }

    private var barLabelFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    }

    private func label(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: barLabelFont,
            .foregroundColor: NSColor.labelColor,
        ])
    }

    private func value(_ fraction: Double, level: Level) -> NSAttributedString {
        coloured(percent(fraction), level: level)
    }

    private func coloured(_ string: String, level: Level) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: barFont,
            .foregroundColor: color(for: level),
        ])
    }

    /// Gigabytes en base decimal, como el Finder. Sin decimales a partir de 10 GB
    /// para que el ancho en la barra no baile; por debajo sí, porque cuando quedan
    /// pocos el decimal importa.
    private func gigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        let format = gb >= 10 ? "%.0f GB" : "%.1f GB"
        return String(format: format, locale: .current, gb)
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%3d%%", Int((fraction * 100).rounded()))
    }

    private func color(for level: Level) -> NSColor {
        switch level {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .critical: return .systemRed
        }
    }

    // MARK: - Menú

    func menuWillOpen(_ menu: NSMenu) {
        tick()
        menu.removeAllItems()

        if let memory {
            menu.addItem(header("Memoria"))
            menu.addItem(detail("Presión \(percent(memory.pressure).trimmingCharacters(in: .whitespaces)) · \(bytes(memory.usedBytes)) de \(bytes(memory.totalBytes)) en uso"))
            menu.addItem(detail("App \(bytes(memory.appBytes)) · Comprimida \(bytes(memory.compressedBytes)) · Wired \(bytes(memory.wiredBytes))"))
            menu.addItem(detail("Caché de archivos \(bytes(memory.cachedBytes)) · Swap \(bytes(memory.swapUsedBytes))"))
            menu.addItem(detail("Memoria libre \(percent(memory.freeFraction).trimmingCharacters(in: .whitespaces)) según el sistema"))
        }
        if let disk {
            menu.addItem(.separator())
            menu.addItem(header("Almacenamiento"))
            menu.addItem(detail("Libres \(gigabytes(disk.availableBytes)) de \(gigabytes(disk.totalBytes)) · \(percent(disk.freeFraction).trimmingCharacters(in: .whitespaces)) del volumen de arranque"))
        }
        if let cpu {
            menu.addItem(.separator())
            menu.addItem(header("Procesador"))
            menu.addItem(detail("Uso \(percent(cpu.total).trimmingCharacters(in: .whitespaces)) · Usuario \(percent(cpu.user).trimmingCharacters(in: .whitespaces)) · Sistema \(percent(cpu.system).trimmingCharacters(in: .whitespaces))"))
        }

        menu.addItem(.separator())

        let intervals = NSMenu()
        for seconds in [1.0, 2.0, 5.0] {
            let item = NSMenuItem(
                title: seconds == 1 ? "1 segundo" : "\(Int(seconds)) segundos",
                action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = Prefs.interval == seconds ? .on : .off
            intervals.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Actualizar cada", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervals
        menu.addItem(intervalItem)

        let loginItem = NSMenuItem(
            title: "Iniciar al arrancar sesión",
            action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let monitorItem = NSMenuItem(
            title: "Abrir Monitor de Actividad",
            action: #selector(openActivityMonitor), keyEquivalent: "")
        monitorItem.target = self
        menu.addItem(monitorItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Salir", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func detail(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        item.isEnabled = false
        return item
    }

    private func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    // MARK: - Acciones

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        Prefs.interval = seconds
        startTimer()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "No se pudo cambiar el inicio automático"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
