import Foundation

/// How a macOS app's binary can run on the current Mac.
enum AppArchitecture: String {
    case appleSilicon = "Apple Silicon"   // arm64 only
    case intel        = "Intel"           // x86_64 only (needs Rosetta 2 on Apple Silicon)
    case universal    = "Universal"       // both arm64 and x86_64
    case unknown      = "Unknown"
}

/// Classify a `.app` bundle by inspecting the Mach-O slices in its executable.
///
/// `Bundle.executableArchitectures` reads the executable's Mach-O header and
/// returns the CPU types it contains — no need to shell out to `lipo`/`file`.
func architecture(of bundleURL: URL) -> AppArchitecture {
    guard let bundle = Bundle(url: bundleURL),
          let archs = bundle.executableArchitectures, !archs.isEmpty else {
        return .unknown
    }
    let cpuTypes = archs.map(\.intValue)
    let hasARM   = cpuTypes.contains(NSBundleExecutableArchitectureARM64)
    let hasIntel = cpuTypes.contains(NSBundleExecutableArchitectureX86_64)

    switch (hasARM, hasIntel) {
    case (true, true):   return .universal
    case (true, false):  return .appleSilicon
    case (false, true):  return .intel
    case (false, false): return .unknown
    }
}

struct AppInfo {
    let name: String
    let arch: AppArchitecture
}

// Standard locations where macOS applications live.
let fileManager = FileManager.default
let home = fileManager.homeDirectoryForCurrentUser
let searchDirs: [URL] = [
    URL(fileURLWithPath: "/Applications"),
    URL(fileURLWithPath: "/System/Applications"),
    home.appendingPathComponent("Applications"),
]

var apps: [AppInfo] = []
for dir in searchDirs {
    guard let entries = try? fileManager.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil
    ) else { continue }

    for entry in entries where entry.pathExtension == "app" {
        let name = entry.deletingPathExtension().lastPathComponent
        apps.append(AppInfo(name: name, arch: architecture(of: entry)))
    }
}

apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

// --- Print a table ---
let nameWidth = max("APP".count, apps.map(\.name.count).max() ?? 0)
func pad(_ s: String) -> String {
    s.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
}

print(pad("APP") + "  ARCHITECTURE")
print(String(repeating: "─", count: nameWidth) + "  ────────────")
for app in apps {
    print(pad(app.name) + "  " + app.arch.rawValue)
}

// --- Summary ---
let counts = Dictionary(grouping: apps, by: \.arch).mapValues(\.count)
print("\nScanned \(apps.count) apps:")
for arch in [AppArchitecture.appleSilicon, .universal, .intel, .unknown] {
    if let count = counts[arch], count > 0 {
        print("  \(arch.rawValue): \(count)")
    }
}
