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

    private var memory: MemorySample?
    private var cpu: CPUSample?

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
        if let sample = cpuReader.read() { cpu = sample }
        render()
    }

    // MARK: - Barra

    private func render() {
        guard let button = statusItem.button else { return }

        let text = NSMutableAttributedString()
        text.append(label("RAM "))
        if let memory {
            let level = ramLevel.update(memory.pressure, floor: memory.kernelFloor)
            text.append(value(memory.pressure, level: level))
        } else {
            text.append(label("--%"))
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

    private func label(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: barFont,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    private func value(_ fraction: Double, level: Level) -> NSAttributedString {
        NSAttributedString(string: percent(fraction), attributes: [
            .font: barFont,
            .foregroundColor: color(for: level),
        ])
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
