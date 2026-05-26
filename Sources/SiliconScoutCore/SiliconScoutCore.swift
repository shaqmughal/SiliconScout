import Foundation

/// How a macOS app's binary can run on the current Mac.
public enum AppArchitecture: String, Equatable {
    case appleSilicon = "Apple Silicon"   // arm64 only
    case intel        = "Intel"           // x86_64 only (runs via Rosetta 2 on Apple Silicon)
    case universal    = "Universal"       // arm64 + x86_64
    case unknown      = "Unknown"
}

public struct AppInfo {
    public let name: String
    public let arch: AppArchitecture
    public init(name: String, arch: AppArchitecture) {
        self.name = name
        self.arch = arch
    }
}

/// Map the presence of CPU slices to a classification.
public func classify(hasARM: Bool, hasIntel: Bool) -> AppArchitecture {
    switch (hasARM, hasIntel) {
    case (true, true):   return .universal
    case (true, false):  return .appleSilicon
    case (false, true):  return .intel
    case (false, false): return .unknown
    }
}

/// Classify a `.app` bundle by inspecting the Mach-O slices of its executable.
///
/// Falls back to `lipo` when the main executable is a shell-script launcher
/// (e.g. .NET/JetBrains tools like dotMemory and dotTrace).
///
/// - Parameter makeBundle: Injectable factory for testing; defaults to `Bundle.init(url:)`.
public func architecture(
    of bundleURL: URL,
    makeBundle: (URL) -> Bundle? = Bundle.init(url:)
) -> AppArchitecture {
    guard let bundle = makeBundle(bundleURL) else { return .unknown }

    // executableArchitectures returns nil (never an empty array) when it can't
    // classify the executable, so a nil check is sufficient.
    if let archs = bundle.executableArchitectures {
        let cpuTypes = archs.map(\.intValue)
        return classify(
            hasARM:   cpuTypes.contains(NSBundleExecutableArchitectureARM64),
            hasIntel: cpuTypes.contains(NSBundleExecutableArchitectureX86_64)
        )
    }

    guard let executable = bundle.executableURL else { return .unknown }

    // Shell-script launcher (some .NET/JetBrains apps): follow the binary it
    // exec's and classify that via lipo.
    if let target = resolveLauncherTarget(of: executable) {
        return architectureViaLipo(executable: target)
    }

    return .unknown
}

/// Ask `lipo -archs` for the CPU slices in an executable.
/// Returns `.unknown` if the file is not a Mach-O (e.g. a shell script).
public func architectureViaLipo(executable: URL) -> AppArchitecture {
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

/// If a bundle's main executable is a shell-script launcher, follow the binary
/// it `exec`s and return that URL. Returns `nil` for non-script files or when
/// the exec target can't be found on disk.
public func resolveLauncherTarget(of script: URL) -> URL? {
    guard let text = try? String(contentsOf: script, encoding: .utf8),
          text.hasPrefix("#!") else { return nil }

    let scriptDir = script.deletingLastPathComponent().path

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("exec ") else { continue }

        var command = String(line.dropFirst("exec ".count))
        if let argRange = command.range(of: " \"$@\"") {
            command = String(command[..<argRange.lowerBound])
        }

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

/// Enumerate `.app` bundles in the given directories and return them sorted by name.
public func scanApps(in directories: [URL]) -> [AppInfo] {
    let fm = FileManager.default
    var apps: [AppInfo] = []
    for dir in directories {
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { continue }
        for entry in entries where entry.pathExtension == "app" {
            let name = entry.deletingPathExtension().lastPathComponent
            apps.append(AppInfo(name: name, arch: architecture(of: entry)))
        }
    }
    return apps.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
