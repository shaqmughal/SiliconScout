import Foundation

/// How a macOS app's binary can run on the current Mac.
public enum AppArchitecture: String, Equatable {
    case appleSilicon = "Apple Silicon"   // arm64 only
    case intel        = "Intel"           // x86_64 only (runs via Rosetta 2 on Apple Silicon)
    case universal    = "Universal"       // arm64 + x86_64
    case unknown      = "Unknown"
}

public struct AppInfo: Identifiable {
    public var id: String { url.path }
    public let name: String
    public let arch: AppArchitecture
    public let url: URL
    public let version: String?
    public let bundleID: String?

    public init(
        name: String,
        arch: AppArchitecture,
        url: URL,
        version: String? = nil,
        bundleID: String? = nil
    ) {
        self.name     = name
        self.arch     = arch
        self.url      = url
        self.version  = version
        self.bundleID = bundleID
    }
}

/// Build a CSV string from an array of AppInfo.
/// Fields: Name, Architecture, Bundle ID, Version, Path
/// Values containing commas or double-quotes are quoted and internal quotes doubled.
public func formatCSV(_ apps: [AppInfo]) -> String {
    let header = "Name,Architecture,Bundle ID,Version,Path"
    let rows = apps.map { app in
        [
            csvEscape(app.name),
            csvEscape(app.arch.rawValue),
            csvEscape(app.bundleID ?? ""),
            csvEscape(app.version ?? ""),
            csvEscape(app.url.path),
        ].joined(separator: ",")
    }
    return ([header] + rows).joined(separator: "\n")
}

private func csvEscape(_ value: String) -> String {
    guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
        return value
    }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
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
/// Returns `.unknown` if the file is not a Mach-O (e.g. a shell script) or if
/// lipo can't be launched.
///
/// - Parameter lipoPath: Injectable for testing; defaults to `/usr/bin/lipo`.
public func architectureViaLipo(executable: URL, lipoPath: String = "/usr/bin/lipo") -> AppArchitecture {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lipoPath)
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

/// Expand `$VAR` and `${VAR}` references in `text` using the provided dictionary.
/// Keys are processed longest-first to prevent a shorter key from partially consuming a longer one.
func expandShellVars(_ text: String, vars: [String: String]) -> String {
    var result = text
    let keys = vars.keys.sorted { $0.count > $1.count }
    for key in keys { result = result.replacingOccurrences(of: "${\(key)}", with: vars[key]!) }
    for key in keys { result = result.replacingOccurrences(of: "$\(key)",   with: vars[key]!) }
    return result
}

/// Build a variable dictionary from simple scalar shell assignments (`VAR="value"`).
/// Skips lines with command substitutions. Does not overwrite a non-empty value
/// with an empty one (handles `VAR=""` inside loops that run after a real assignment).
func buildVarDict(from lines: [String], homeDir: String = NSHomeDirectory()) -> [String: String] {
    var vars: [String: String] = ["HOME": homeDir]
    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eqIdx = line.firstIndex(of: "=") else { continue }
        let name = String(line[..<eqIdx])
        guard !name.isEmpty, !name.contains(" "),
              name.first.map({ $0.isLetter || $0 == "_" }) == true,
              name.unicodeScalars.dropFirst().allSatisfy({
                  CharacterSet.alphanumerics.union(.init(charactersIn: "_")).contains($0)
              }) else { continue }
        var raw = String(line[line.index(after: eqIdx)...])
        guard !raw.contains("`"), !raw.contains("$(") else { continue }
        if raw.count >= 2,
           (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
           (raw.hasPrefix("'")  && raw.hasSuffix("'")) {
            raw = String(raw.dropFirst().dropLast())
        }
        let expanded = expandShellVars(raw, vars: vars)
        if !expanded.isEmpty || vars[name] == nil { vars[name] = expanded }
    }
    return vars
}

/// Resolve a path containing one `${...}` wildcard component by enumerating
/// the parent directory and returning the first entry whose suffixed path exists.
private func resolveWildcardPath(_ pattern: String, fm: FileManager) -> URL? {
    guard let varStart = pattern.range(of: "${"),
          let varEnd   = pattern[varStart.upperBound...].firstIndex(of: "}") else { return nil }
    let prefix    = String(pattern[..<varStart.lowerBound])
    let suffix    = String(pattern[pattern.index(after: varEnd)...])
    let parentURL = URL(fileURLWithPath: prefix).standardizedFileURL
    guard let entries = try? fm.contentsOfDirectory(at: parentURL, includingPropertiesForKeys: nil)
    else { return nil }
    for entry in entries.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
        let candidate = URL(fileURLWithPath: entry.path + suffix).standardizedFileURL
        if fm.fileExists(atPath: candidate.path) { return candidate }
    }
    return nil
}

/// If a bundle's main executable is a shell-script launcher, follow the binary
/// it launches and return that URL. Returns `nil` for non-script files or when
/// the target can't be found on disk.
///
/// Handles three launch patterns:
///   1. `exec "path"` — including shell-variable–built paths and dirname idioms
///   2. `open "App.app"` — resolves the bundle's own executable
///   3. `"$VAR" args` — direct invocation without exec keyword
public func resolveLauncherTarget(of script: URL) -> URL? {
    guard let text = try? String(contentsOf: script, encoding: .utf8),
          text.hasPrefix("#!") else { return nil }

    let scriptDir = script.deletingLastPathComponent().path
    let fm        = FileManager.default
    let lines     = text.components(separatedBy: .newlines)
    let vars      = buildVarDict(from: lines)

    for rawLine in lines {
        let line = rawLine.trimmingCharacters(in: .whitespaces)

        // --- Pattern: open "App.app" [args] ---
        if line.hasPrefix("open ") {
            let payload = expandShellVars(String(line.dropFirst("open ".count)), vars: vars)
            if let appPath = extractFirstQuotedOrUnquotedArg(from: payload),
               appPath.hasSuffix(".app"),
               let bundle = Bundle(url: URL(fileURLWithPath: appPath)),
               let exe = bundle.executableURL,
               fm.fileExists(atPath: exe.path) {
                return exe.standardizedFileURL
            }
            continue
        }

        // --- Pattern: exec "path" [args] ---
        if line.hasPrefix("exec ") {
            var command = expandShellVars(String(line.dropFirst("exec ".count)), vars: vars)
            // Strip argument-forwarding suffixes
            for suffix in [" \"$@\"", " $*", " $@"] {
                if let r = command.range(of: suffix) { command = String(command[..<r.lowerBound]) }
            }
            // Variable-expanded path: extract the first quoted token (handles spaces in paths)
            if command.hasPrefix("\""), !command.contains("$(") {
                if let close = command.dropFirst().firstIndex(of: "\"") {
                    let path = String(command[command.index(after: command.startIndex)..<close])
                    if !path.isEmpty { return resolveOrWildcard(path, fm: fm) }
                }
                continue
            }
            // Legacy: apply dirname/trim idioms, then strip all quotes
            for idiom in ["$(dirname \"$0\")", "$(dirname $0)", "${0%/*}"] {
                command = command.replacingOccurrences(of: idiom, with: scriptDir)
            }
            command = command.replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let url = resolveOrWildcard(command, fm: fm) { return url }
            continue
        }

        // --- Pattern: "$VAR" args  (direct invocation, no exec keyword) ---
        if line.hasPrefix("\"$") {
            var command = expandShellVars(line, vars: vars)
            if command.hasPrefix("\""),
               let close = command.dropFirst().firstIndex(of: "\"") {
                let path = String(command[command.index(after: command.startIndex)..<close])
                if !path.isEmpty, let url = resolveOrWildcard(path, fm: fm) { return url }
            }
        }
    }
    return nil
}

/// Resolve `path` to an existing URL, falling back to wildcard enumeration if
/// the path contains an unresolved `${...}` component.
private func resolveOrWildcard(_ path: String, fm: FileManager) -> URL? {
    if path.contains("${") { return resolveWildcardPath(path, fm: fm) }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return fm.fileExists(atPath: url.path) ? url : nil
}

/// Extract the first argument from a shell command string, respecting double-quotes.
private func extractFirstQuotedOrUnquotedArg(from command: String) -> String? {
    let s = command.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("\""), let close = s.dropFirst().firstIndex(of: "\"") {
        return String(s[s.index(after: s.startIndex)..<close])
    }
    let token = s.components(separatedBy: " ").first ?? ""
    return token.isEmpty ? nil : token
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
            let resolved = (try? URL(resolvingAliasFileAt: entry, options: [])) ?? entry
            let name = entry.deletingPathExtension().lastPathComponent
            let bundle = Bundle(url: resolved)
            let version  = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
            let bundleID = bundle?.bundleIdentifier
            apps.append(AppInfo(
                name: name,
                arch: architecture(of: resolved),
                url: resolved,
                version: version,
                bundleID: bundleID
            ))
        }
    }
    return apps.sorted {
        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}
