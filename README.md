# Mac-RAMPressureMonitor

A tiny macOS menu bar app that shows **memory pressure** and **CPU usage** as live
percentages, colour-coded green → orange → red.

```
RAM  41%  CPU  12%
```

No dependencies, no Xcode, no Dock icon. The whole thing is two Swift files and a
build script.

## Why memory *pressure* and not "RAM used"

"RAM used" is a misleading number on macOS — the OS deliberately fills free memory
with file caches, so a healthy machine often reports 90%+ used. Memory *pressure* is
what Activity Monitor actually graphs, and it is the number that tells you whether
your Mac is struggling:

```
pressure = (wired pages + compressed pages) / total pages
```

Those are the pages the kernel *cannot* hand back to you on demand. This app uses
the same formula, and additionally reads `kern.memorystatus_vm_pressure_level` so it
can go orange or red the moment the kernel itself reports pressure, even if the
percentage has not crossed the threshold yet.

CPU usage is the delta of kernel tick counters (`user + nice + system` over total)
between samples — the same approach Activity Monitor takes.

Everything comes from direct Mach calls (`host_statistics64`, `host_cpu_load_info`)
and `sysctl`. No shelling out to `top` or `vm_stat`, which is why the app idles at
roughly 0% CPU and ~45 MB of memory.

## Colour thresholds

|         | Green  | Orange   | Red                     |
| ------- | ------ | -------- | ----------------------- |
| Memory  | < 60%  | 60–80%   | > 80%, or kernel warn   |
| CPU     | < 60%  | 60–85%   | > 85%                   |

Levels have 3 points of hysteresis, so the colour does not flicker when a value sits
right on a threshold.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`) — **full Xcode is not needed**

## Build and install

```bash
git clone https://github.com/ThePatientLearner/Mac-RAMPressureMonitor.git
cd Mac-RAMPressureMonitor
./build.sh
cp -R build/RAMPressureMonitor.app ~/Applications/
open ~/Applications/RAMPressureMonitor.app
```

`build.sh` compiles the sources with `swiftc`, assembles the `.app` bundle by hand
and ad-hoc signs it. There is no `.xcodeproj` — an app bundle is just a directory
with an `Info.plist` and a binary in `Contents/MacOS/`.

Because the app is ad-hoc signed rather than signed with an Apple Developer
certificate, Gatekeeper may ask you to confirm the first launch. Right-click the app
and choose *Open* if macOS refuses the double-click.

## Menu

Click the menu bar item for a breakdown — app / compressed / wired memory, file cache,
swap, and CPU split between user and system. From the same menu you can set the
refresh interval (1s / 2s / 5s), toggle launch at login, or open Activity Monitor.

## Customising

- **Thresholds** — `ramLevel` / `cpuLevel` at the top of `Sources/main.swift`
- **Menu bar format** — the `render()` function in `Sources/main.swift`
- **Metrics** — `Sources/Metrics.swift`

## Note on language

The user interface is in Spanish. Pull requests adding localisation are welcome.

## License

MIT
