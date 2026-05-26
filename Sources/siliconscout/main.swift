import Foundation

/// How a macOS app's binary can run on the current Mac.
enum AppArchitecture: String {
    case appleSilicon = "Apple Silicon"   // arm64 only
    case intel        = "Intel"           // x86_64 only (needs Rosetta 2 on Apple Silicon)
    case universal    = "Universal"       // both arm64 and x86_64
    case unknown      = "Unknown"
}

/// Map the presence of each slice to a classification.
func classify(hasARM: Bool, hasIntel: Bool) -> AppArchitecture {
    switch (hasARM, hasIntel) {
    case (true, true):   return .universal
    case (true, false):  return .appleSilicon
    case (false, true):  return .intel
    case (false, false): return .unknown
    }
}

/// Classify a `.app` bundle by inspecting the Mach-O slices in its executable.
///
/// `Bundle.executableArchitectures` reads the executable's Mach-O header and
/// returns the CPU types it contains — no need to shell out for most apps.
/// Some apps (e.g. .NET-based JetBrains tools like dotMemory/dotTrace) use a
/// launcher that this API can't read; for those we fall back to `lipo`.
func architecture(of bundleURL: URL) -> AppArchitecture {
    guard let bundle = Bundle(url: bundleURL) else { return .unknown }

    if let archs = bundle.executableArchitectures, !archs.isEmpty {
        let cpuTypes = archs.map(\.intValue)
        let result = classify(
            hasARM:   cpuTypes.contains(NSBundleExecutableArchitectureARM64),
            hasIntel: cpuTypes.contains(NSBundleExecutableArchitectureX86_64)
        )
        if result != .unknown { return result }
    }

    guard let executable = bundle.executableURL else { return .unknown }

    // A real Mach-O the API couldn't read: ask lipo directly.
    let viaLipo = architectureViaLipo(executable: executable)
    if viaLipo != .unknown { return viaLipo }

    // A script launcher (some .NET/JetBrains apps): follow what it exec's.
    if let target = resolveLauncherTarget(of: executable) {
        return architectureViaLipo(executable: target)
    }
    return .unknown
}

/// Fallback that asks `lipo -archs` for the slices in an executable. Returns
/// `.unknown` if lipo isn't usable (e.g. the launcher is a plain script).
func architectureViaLipo(executable: URL) -> AppArchitecture {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lipo")
    process.arguments = ["-archs", executable.path]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return .unknown
    }
    guard process.terminationStatus == 0 else { return .unknown }

    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    return classify(hasARM: output.contains("arm64"), hasIntel: output.contains("x86_64"))
}

/// If a bundle's main executable is a shell-script launcher (as used by some
/// .NET/JetBrains apps), follow the binary it `exec`s and return that URL.
func resolveLauncherTarget(of script: URL) -> URL? {
    guard let text = try? String(contentsOf: script, encoding: .utf8),
          text.hasPrefix("#!") else { return nil }

    let scriptDir = script.deletingLastPathComponent().path

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("exec ") else { continue }

        // Isolate the command being run, dropping argument forwarding.
        var command = String(line.dropFirst("exec ".count))
        if let argRange = command.range(of: " \"$@\"") {
            command = String(command[..<argRange.lowerBound])
        }

        // Substitute the common "directory of this script" idioms, then
        // strip quotes so we're left with a resolvable path.
        for idiom in ["$(dirname \"$0\")", "$(dirname $0)", "${0%/*}"] {
            command = command.replacingOccurrences(of: idiom, with: scriptDir)
        }
        command = command.replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)

        let target = URL(fileURLWithPath: command).standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) { return target }
    }
    return nil
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
