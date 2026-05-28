import XCTest
import Foundation
@testable import SiliconScoutCore

final class SiliconScoutCoreTests: XCTestCase {

    // MARK: - Per-test fixtures

    var tempDir: URL!
    var universalBinaryURL: URL!
    var arm64BinaryURL: URL!
    var x86BinaryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SiliconScoutTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        universalBinaryURL = tempDir.appendingPathComponent("universal_bin")
        arm64BinaryURL     = tempDir.appendingPathComponent("arm64_bin")
        x86BinaryURL       = tempDir.appendingPathComponent("x86_bin")

        // /usr/bin/file is universal on modern macOS; thin it for arch-specific fixtures.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/file"),
                                         to: universalBinaryURL)
        try shell("/usr/bin/lipo", args: [universalBinaryURL.path, "-thin", "arm64",   "-output", arm64BinaryURL.path])
        try shell("/usr/bin/lipo", args: [universalBinaryURL.path, "-thin", "x86_64",  "-output", x86BinaryURL.path])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    func shell(_ executable: String, args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError  = pipe
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)])
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Create a minimal .app bundle. `setup` receives the URL where it should place the executable.
    func makeApp(name: String, withExecutable setup: (URL) throws -> Void) throws -> URL {
        let appURL   = tempDir.appendingPathComponent("\(name).app")
        let macosDir = appURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>CFBundleExecutable</key><string>\(name)</string></dict>
        </plist>
        """
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        try setup(macosDir.appendingPathComponent(name))
        return appURL
    }

    /// Create a .app whose main executable is a shell-script launcher that exec's `realBinary`.
    func makeScriptLauncherApp(name: String, realBinary: URL) throws -> URL {
        return try makeApp(name: name) { exeURL in
            let helpersDir = exeURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers")
            try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: realBinary,
                to: helpersDir.appendingPathComponent(realBinary.lastPathComponent))
            let script = "#!/bin/sh\nexec \"$(dirname \"$0\")\"/../Helpers/\(realBinary.lastPathComponent) \"$@\"\n"
            try script.write(to: exeURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exeURL.path)
        }
    }

    // MARK: - AppInfo

    func testAppInfo_storesAllFields() {
        let url  = URL(fileURLWithPath: "/Applications/Safari.app")
        let info = AppInfo(name: "Safari", arch: .universal, url: url)
        XCTAssertEqual(info.name, "Safari")
        XCTAssertEqual(info.arch, .universal)
        XCTAssertEqual(info.url,  url)
        XCTAssertNil(info.version)
        XCTAssertNil(info.bundleID)
    }

    func testAppInfo_withMetadata() {
        let url  = URL(fileURLWithPath: "/Applications/Foo.app")
        let info = AppInfo(name: "Foo", arch: .appleSilicon, url: url,
                           version: "2.3.4", bundleID: "com.example.foo")
        XCTAssertEqual(info.version,  "2.3.4")
        XCTAssertEqual(info.bundleID, "com.example.foo")
        XCTAssertEqual(info.id, "/Applications/Foo.app")
    }

    // MARK: - formatCSV

    func testFormatCSV_emptyArray() {
        let csv = formatCSV([])
        XCTAssertEqual(csv, "Name,Architecture,Bundle ID,Version,Path")
    }

    func testFormatCSV_basic() {
        let apps = [
            AppInfo(name: "Alpha", arch: .appleSilicon,
                    url: URL(fileURLWithPath: "/Applications/Alpha.app"),
                    version: "1.0", bundleID: "com.a.alpha"),
            AppInfo(name: "Beta",  arch: .intel,
                    url: URL(fileURLWithPath: "/Applications/Beta.app"),
                    version: nil,   bundleID: nil),
        ]
        let lines = formatCSV(apps).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "Name,Architecture,Bundle ID,Version,Path")
        XCTAssertEqual(lines[1], "Alpha,Apple Silicon,com.a.alpha,1.0,/Applications/Alpha.app")
        XCTAssertEqual(lines[2], "Beta,Intel,,,/Applications/Beta.app")
    }

    func testFormatCSV_escapesCommas() {
        let app = AppInfo(name: "App, With Comma", arch: .universal,
                          url: URL(fileURLWithPath: "/Applications/App.app"),
                          version: nil, bundleID: "com.example,weird")
        let csv = formatCSV([app])
        let dataRow = csv.components(separatedBy: "\n")[1]
        XCTAssertTrue(dataRow.hasPrefix("\"App, With Comma\""))
        XCTAssertTrue(dataRow.contains("\"com.example,weird\""))
    }

    func testFormatCSV_escapesDoubleQuotes() {
        let app = AppInfo(name: "App \"Quoted\"", arch: .unknown,
                          url: URL(fileURLWithPath: "/Applications/App.app"))
        let csv = formatCSV([app])
        let dataRow = csv.components(separatedBy: "\n")[1]
        XCTAssertTrue(dataRow.hasPrefix("\"App \"\"Quoted\"\"\""))
    }

    // MARK: - AppArchitecture raw values

    func testAppArchitecture_rawValues() {
        XCTAssertEqual(AppArchitecture.appleSilicon.rawValue, "Apple Silicon")
        XCTAssertEqual(AppArchitecture.intel.rawValue,        "Intel")
        XCTAssertEqual(AppArchitecture.universal.rawValue,    "Universal")
        XCTAssertEqual(AppArchitecture.unknown.rawValue,      "Unknown")
    }

    // MARK: - classify

    func testClassify_appleSilicon() {
        XCTAssertEqual(classify(hasARM: true, hasIntel: false), .appleSilicon)
    }

    func testClassify_intel() {
        XCTAssertEqual(classify(hasARM: false, hasIntel: true), .intel)
    }

    func testClassify_universal() {
        XCTAssertEqual(classify(hasARM: true, hasIntel: true), .universal)
    }

    func testClassify_unknown() {
        XCTAssertEqual(classify(hasARM: false, hasIntel: false), .unknown)
    }

    // MARK: - architectureViaLipo

    func testArchitectureViaLipo_arm64() {
        XCTAssertEqual(architectureViaLipo(executable: arm64BinaryURL), .appleSilicon)
    }

    func testArchitectureViaLipo_x86() {
        XCTAssertEqual(architectureViaLipo(executable: x86BinaryURL), .intel)
    }

    func testArchitectureViaLipo_universal() {
        XCTAssertEqual(architectureViaLipo(executable: universalBinaryURL), .universal)
    }

    func testArchitectureViaLipo_shellScript() throws {
        let scriptURL = tempDir.appendingPathComponent("not_macho.sh")
        try "#!/bin/sh\necho hi".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(architectureViaLipo(executable: scriptURL), .unknown)
    }

    func testArchitectureViaLipo_nonExistentFile() {
        XCTAssertEqual(architectureViaLipo(executable: tempDir.appendingPathComponent("missing")),
                       .unknown)
    }

    func testArchitectureViaLipo_launchFailure() {
        // A bad lipo path makes process.run() throw → covers the catch branch.
        XCTAssertEqual(architectureViaLipo(executable: arm64BinaryURL,
                                           lipoPath: "/nonexistent/lipo"), .unknown)
    }

    // MARK: - expandShellVars

    func testExpandShellVars_braceForm() {
        XCTAssertEqual(expandShellVars("${FOO}/baz", vars: ["FOO": "bar"]), "bar/baz")
    }

    func testExpandShellVars_dollarForm() {
        XCTAssertEqual(expandShellVars("$FOO/baz", vars: ["FOO": "bar"]), "bar/baz")
    }

    func testExpandShellVars_longerKeyTakesPrecedence() {
        // $STREAMERSDIR must not be partially consumed by the shorter $STREAMER key.
        let vars = ["STREAMER": "WRONG", "STREAMERSDIR": "/correct/path"]
        XCTAssertEqual(expandShellVars("$STREAMERSDIR", vars: vars), "/correct/path")
    }

    func testExpandShellVars_unknownVarLeftUnchanged() {
        XCTAssertEqual(expandShellVars("${UNKNOWN}/path", vars: ["FOO": "bar"]), "${UNKNOWN}/path")
    }

    func testExpandShellVars_chainedExpansion() {
        // Already-expanded vars are used when expanding subsequent vars in the dict.
        let vars = ["BASE": "/usr", "DIR": "/usr/local"]
        XCTAssertEqual(expandShellVars("$DIR/bin", vars: vars), "/usr/local/bin")
    }

    // MARK: - buildVarDict

    func testBuildVarDict_doubleQuotedAssignment() {
        let dict = buildVarDict(from: [#"realApp="Autodesk Fusion 360""#])
        XCTAssertEqual(dict["realApp"], "Autodesk Fusion 360")
    }

    func testBuildVarDict_singleQuotedAssignment() {
        let dict = buildVarDict(from: ["NAME='My App'"])
        XCTAssertEqual(dict["NAME"], "My App")
    }

    func testBuildVarDict_chainedAssignment() {
        let dict = buildVarDict(from: [#"BASE="/usr/local""#, #"BINDIR="$BASE/bin""#])
        XCTAssertEqual(dict["BINDIR"], "/usr/local/bin")
    }

    func testBuildVarDict_skipCommandSubstitution() {
        let dict = buildVarDict(from: ["VER=$(git describe)"])
        XCTAssertNil(dict["VER"])
    }

    func testBuildVarDict_doesNotOverwriteWithEmpty() {
        let dict = buildVarDict(from: [#"MYVAR="/useful/path""#, #"MYVAR="""#])
        XCTAssertEqual(dict["MYVAR"], "/useful/path")
    }

    func testBuildVarDict_homeExpansion() {
        let dict = buildVarDict(from: [#"DIR="$HOME/Library""#], homeDir: "/Users/testuser")
        XCTAssertEqual(dict["DIR"], "/Users/testuser/Library")
    }

    // MARK: - resolveLauncherTarget (variable substitution and new patterns)

    func testResolveLauncherTarget_execWithVarSubstitution() throws {
        // Script uses a shell variable to build the executable path, then execs it.
        let binDir = tempDir.appendingPathComponent("VarBin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("real_binary")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)

        let script = "#!/bin/sh\nBINDIR=\"\(binDir.path)\"\nexec \"$BINDIR/real_binary\" \"$@\"\n"
        let scriptURL = tempDir.appendingPathComponent("var_exec_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_openAppPattern() throws {
        // Script launches a .app bundle with `open` — resolve its executable.
        let realApp = try makeApp(name: "OpenTarget") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        let script = "#!/bin/sh\nopen \"\(realApp.path)\" --args \"$@\"\n"
        let scriptURL = tempDir.appendingPathComponent("open_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let target = resolveLauncherTarget(of: scriptURL)
        XCTAssertNotNil(target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target!.path))
    }

    func testResolveLauncherTarget_openWithVarSubstitution() throws {
        // Variables construct the .app path and open launches it.
        let realApp = try makeApp(name: "VarOpenTarget") { exe in
            try FileManager.default.copyItem(at: self.universalBinaryURL, to: exe)
        }
        let appDir  = realApp.deletingLastPathComponent().path
        let appName = realApp.deletingPathExtension().lastPathComponent
        let script = """
        #!/bin/sh
        APPDIR="\(appDir)"
        APPNAME="\(appName)"
        APPPATH="$APPDIR/$APPNAME.app"
        open "$APPPATH" --args "$@"
        """
        let scriptURL = tempDir.appendingPathComponent("var_open_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let target = resolveLauncherTarget(of: scriptURL)
        XCTAssertNotNil(target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target!.path))
    }

    func testResolveLauncherTarget_execWithVarAndQuotedFlag() throws {
        // `exec "$PATH/binary" "-serviceUtil" "$@"` — quoted flag must be stripped.
        let binDir = tempDir.appendingPathComponent("FlagBin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("binary")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)

        let script = "#!/bin/sh\nBINDIR=\"\(binDir.path)\"\nexec \"$BINDIR/binary\" \"-serviceUtil\" \"$@\"\n"
        let scriptURL = tempDir.appendingPathComponent("flag_exec_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_directInvocationWithVar() throws {
        // Script sets a variable and invokes it directly (no `exec` keyword).
        let binDir = tempDir.appendingPathComponent("DirectBin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("direct_binary")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)

        let script = "#!/bin/sh\nBINPATH=\"\(targetURL.path)\"\n\"$BINPATH\" -flag1 -flag2\n"
        let scriptURL = tempDir.appendingPathComponent("direct_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_wildcardPathComponent() throws {
        // Variable has an unresolvable component (e.g. a loop variable ${ver}).
        // The resolver should enumerate the parent directory to find the binary.
        let versionsDir = tempDir.appendingPathComponent("Versions")
        let v1Dir = versionsDir.appendingPathComponent("v1")
        try FileManager.default.createDirectory(at: v1Dir, withIntermediateDirectories: true)
        let binaryURL = v1Dir.appendingPathComponent("binary")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: binaryURL)

        let script = """
        #!/bin/sh
        VERSIONSDIR="\(versionsDir.path)"
        for ver in $(ls "$VERSIONSDIR"); do
            BINPATH="${VERSIONSDIR}/${ver}/binary"
        done
        "$BINPATH" -args
        """
        let scriptURL = tempDir.appendingPathComponent("wildcard_launcher")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       binaryURL.standardizedFileURL)
    }

    func testScanApps_autodeskStyleOpenLauncherResolvesArchitecture() throws {
        // Models the Autodesk Fusion pattern: wrapper .app whose launcher script
        // uses `open` with shell variables to launch the real .app stored elsewhere.
        let scanDir = tempDir.appendingPathComponent("AutodeskStyle")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        let realApp = try makeApp(name: "RealFusion") { exe in
            try FileManager.default.copyItem(at: self.universalBinaryURL, to: exe)
        }
        let wrapperApp = try makeApp(name: "AutodeskFusion") { scriptURL in
            let script = """
            #!/bin/sh
            destfolder="\(realApp.deletingLastPathComponent().path)"
            realApp="RealFusion"
            STREAMERPATH="$destfolder/$realApp.app"
            open "$STREAMERPATH" --args "$@"
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: scriptURL.path)
        }
        try FileManager.default.moveItem(at: wrapperApp,
                                         to: scanDir.appendingPathComponent("AutodeskFusion.app"))

        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].arch, .universal)
    }

    // MARK: - resolveLauncherTarget (existing patterns)

    func testResolveLauncherTarget_nonScriptFile() {
        // A Mach-O binary has no shebang — should return nil immediately.
        XCTAssertNil(resolveLauncherTarget(of: arm64BinaryURL))
    }

    func testResolveLauncherTarget_dirnameWithQuotesIdiom() throws {
        // $(dirname "$0") — most common launcher idiom.
        let scriptDir = tempDir.appendingPathComponent("Scripts1")
        let binDir    = tempDir.appendingPathComponent("Bin1")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir,    withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("real_app1")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)
        let script = "#!/bin/sh\nexec \"$(dirname \"$0\")\"/../Bin1/real_app1 \"$@\"\n"
        let scriptURL = scriptDir.appendingPathComponent("launcher1")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_dirnameWithoutQuotesIdiom() throws {
        // $(dirname $0) — no quotes around $0.
        let scriptDir = tempDir.appendingPathComponent("Scripts2")
        let binDir    = tempDir.appendingPathComponent("Bin2")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir,    withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("real_app2")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)
        let script = "#!/bin/sh\nexec $(dirname $0)/../Bin2/real_app2 \"$@\"\n"
        let scriptURL = scriptDir.appendingPathComponent("launcher2")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_bashDirIdiom() throws {
        // ${0%/*} idiom.
        let scriptDir = tempDir.appendingPathComponent("Scripts3")
        let binDir    = tempDir.appendingPathComponent("Bin3")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir,    withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("real_app3")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)
        let script = "#!/bin/sh\nexec ${0%/*}/../Bin3/real_app3 \"$@\"\n"
        let scriptURL = scriptDir.appendingPathComponent("launcher3")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_noArgForwarding() throws {
        // exec without "$@" — covers the false branch of the argRange trim.
        let scriptDir = tempDir.appendingPathComponent("Scripts4")
        let binDir    = tempDir.appendingPathComponent("Bin4")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir,    withIntermediateDirectories: true)
        let targetURL = binDir.appendingPathComponent("real_app4")
        try FileManager.default.copyItem(at: arm64BinaryURL, to: targetURL)
        let script = "#!/bin/sh\nexec \"$(dirname \"$0\")\"/../Bin4/real_app4\n"
        let scriptURL = scriptDir.appendingPathComponent("launcher4")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(resolveLauncherTarget(of: scriptURL)?.standardizedFileURL,
                       targetURL.standardizedFileURL)
    }

    func testResolveLauncherTarget_noExecLine() throws {
        let scriptURL = tempDir.appendingPathComponent("no_exec.sh")
        try "#!/bin/sh\necho hello\nexit 0".write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertNil(resolveLauncherTarget(of: scriptURL))
    }

    func testResolveLauncherTarget_targetDoesNotExist() throws {
        let scriptDir = tempDir.appendingPathComponent("Scripts5")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nexec \"$(dirname \"$0\")\"/../Helpers/nonexistent \"$@\"\n"
        let scriptURL = scriptDir.appendingPathComponent("launcher5")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertNil(resolveLauncherTarget(of: scriptURL))
    }

    // MARK: - architecture(of:)

    func testArchitecture_nilBundle() {
        // Inject nil bundle factory to cover the first guard path.
        XCTAssertEqual(architecture(of: URL(fileURLWithPath: "/fake.app"),
                                    makeBundle: { _ in nil }), .unknown)
    }

    func testArchitecture_arm64Bundle() throws {
        let appURL = try makeApp(name: "arm64App") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        XCTAssertEqual(architecture(of: appURL), .appleSilicon)
    }

    func testArchitecture_x86Bundle() throws {
        let appURL = try makeApp(name: "x86App") { exe in
            try FileManager.default.copyItem(at: self.x86BinaryURL, to: exe)
        }
        XCTAssertEqual(architecture(of: appURL), .intel)
    }

    func testArchitecture_universalBundle() throws {
        let appURL = try makeApp(name: "universalApp") { exe in
            try FileManager.default.copyItem(at: self.universalBinaryURL, to: exe)
        }
        XCTAssertEqual(architecture(of: appURL), .universal)
    }

    func testArchitecture_scriptLauncherResolvesToArm64() throws {
        let appURL = try makeScriptLauncherApp(name: "scriptApp", realBinary: arm64BinaryURL)
        XCTAssertEqual(architecture(of: appURL), .appleSilicon)
    }

    func testArchitecture_scriptLauncherUnresolvable() throws {
        // Script launcher points at a non-existent binary → .unknown
        let appURL = try makeApp(name: "badScriptApp") { exe in
            let script = "#!/bin/sh\nexec \"$(dirname \"$0\")\"/../Helpers/nonexistent \"$@\"\n"
            try script.write(to: exe, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        }
        XCTAssertEqual(architecture(of: appURL), .unknown)
    }

    func testArchitecture_missingCFBundleExecutable() throws {
        // Bundle exists but Info.plist has no CFBundleExecutable → executableURL nil → .unknown
        let appURL      = tempDir.appendingPathComponent("NoExec.app")
        let contentsDir = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict></dict></plist>
        """
        try plist.write(to: contentsDir.appendingPathComponent("Info.plist"),
                        atomically: true, encoding: .utf8)
        XCTAssertEqual(architecture(of: appURL), .unknown)
    }

    // MARK: - scanApps

    func testScanApps_emptyDirectory() throws {
        let dir = tempDir.appendingPathComponent("EmptyApps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(scanApps(in: [dir]).isEmpty)
    }

    func testScanApps_nonExistentDirectory() {
        XCTAssertTrue(scanApps(in: [tempDir.appendingPathComponent("Missing")]).isEmpty)
    }

    func testScanApps_ignoresNonAppFiles() throws {
        let dir = tempDir.appendingPathComponent("Mixed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not an app".write(to: dir.appendingPathComponent("readme.txt"),
                               atomically: true, encoding: .utf8)
        XCTAssertTrue(scanApps(in: [dir]).isEmpty)
    }

    func testScanApps_returnsSortedResults() throws {
        let dir = tempDir.appendingPathComponent("SortedApps")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Zebra", "Alpha", "Mango"] {
            let appURL   = dir.appendingPathComponent("\(name).app")
            let macosDir = appURL.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: arm64BinaryURL,
                                             to: macosDir.appendingPathComponent(name))
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict><key>CFBundleExecutable</key><string>\(name)</string></dict>
            </plist>
            """
            try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"),
                            atomically: true, encoding: .utf8)
        }
        let results = scanApps(in: [dir])
        XCTAssertEqual(results.map(\.name), ["Alpha", "Mango", "Zebra"])
        XCTAssertTrue(results.allSatisfy { $0.arch == .appleSilicon })
        // Each AppInfo URL should point to its .app bundle.
        XCTAssertTrue(results.allSatisfy { $0.url.pathExtension == "app" })
        XCTAssertEqual(results.map { $0.url.deletingPathExtension().lastPathComponent },
                       ["Alpha", "Mango", "Zebra"])
    }

    // MARK: - scanApps alias resolution

    /// Creates a macOS Finder alias at `aliasURL` pointing to `targetURL`.
    func makeAlias(at aliasURL: URL, targeting targetURL: URL) throws {
        let bookmarkData = try targetURL.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try URL.writeBookmarkData(bookmarkData, to: aliasURL)
    }

    func testScanApps_aliasToArm64AppReportsAppleSilicon() throws {
        let scanDir = tempDir.appendingPathComponent("AliasArm64")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "RealArm64") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("RealArm64.app"), targeting: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].arch, .appleSilicon)
    }

    func testScanApps_aliasToIntelAppReportsIntel() throws {
        let scanDir = tempDir.appendingPathComponent("AliasIntel")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "RealIntel") { exe in
            try FileManager.default.copyItem(at: self.x86BinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("RealIntel.app"), targeting: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].arch, .intel)
    }

    func testScanApps_aliasToUniversalAppReportsUniversal() throws {
        let scanDir = tempDir.appendingPathComponent("AliasUniversal")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "RealUniversal") { exe in
            try FileManager.default.copyItem(at: self.universalBinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("RealUniversal.app"), targeting: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].arch, .universal)
    }

    func testScanApps_aliasPreservesAliasName() throws {
        // The display name must come from the alias filename, not the target bundle.
        let scanDir = tempDir.appendingPathComponent("AliasName")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "OriginalName") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("AliasName.app"), targeting: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "AliasName")
    }

    func testScanApps_aliasURLPointsToTarget() throws {
        // AppInfo.url should be the resolved target path, not the alias file path.
        let scanDir = tempDir.appendingPathComponent("AliasURL")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "URLTarget") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("URLTarget.app"), targeting: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].url.standardizedFileURL, target.standardizedFileURL)
    }

    func testScanApps_aliasPropagatesVersionAndBundleID() throws {
        // Metadata (version, bundleID) must come from the target bundle, not the alias.
        let scanDir = tempDir.appendingPathComponent("AliasMeta")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let appURL   = tempDir.appendingPathComponent("MetaTarget.app")
        let macosDir = appURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleExecutable</key><string>MetaTarget</string>
          <key>CFBundleShortVersionString</key><string>9.8.7</string>
          <key>CFBundleIdentifier</key><string>com.test.metatarget</string>
        </dict>
        </plist>
        """
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: arm64BinaryURL,
                                         to: macosDir.appendingPathComponent("MetaTarget"))
        try makeAlias(at: scanDir.appendingPathComponent("MetaTarget.app"), targeting: appURL)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].version,  "9.8.7")
        XCTAssertEqual(results[0].bundleID, "com.test.metatarget")
    }

    func testScanApps_danglingAliasReturnsUnknown() throws {
        // Alias whose target no longer exists falls back to the alias file → .unknown.
        let scanDir = tempDir.appendingPathComponent("AliasDangling")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)
        let target = try makeApp(name: "ToBeDeleted") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("ToBeDeleted.app"), targeting: target)
        try FileManager.default.removeItem(at: target)
        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].arch, .unknown)
    }

    func testScanApps_mixOfAliasesAndRealAppsAllCorrect() throws {
        // A directory containing both a real .app and an alias to another .app should
        // report the correct architecture for each entry.
        let scanDir = tempDir.appendingPathComponent("MixedAliases")
        try FileManager.default.createDirectory(at: scanDir, withIntermediateDirectories: true)

        // Real arm64 app placed directly in the scan dir.
        let directApp = try makeApp(name: "DirectArm64") { exe in
            try FileManager.default.copyItem(at: self.arm64BinaryURL, to: exe)
        }
        try FileManager.default.moveItem(at: directApp,
                                         to: scanDir.appendingPathComponent("DirectArm64.app"))

        // Alias in scan dir pointing to a universal app stored elsewhere.
        let externalApp = try makeApp(name: "ExternalUniversal") { exe in
            try FileManager.default.copyItem(at: self.universalBinaryURL, to: exe)
        }
        try makeAlias(at: scanDir.appendingPathComponent("ExternalUniversal.app"),
                      targeting: externalApp)

        let results = scanApps(in: [scanDir])
        XCTAssertEqual(results.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0.arch) })
        XCTAssertEqual(byName["DirectArm64"],     .appleSilicon)
        XCTAssertEqual(byName["ExternalUniversal"], .universal)
    }

    func testScanApps_populatesVersionAndBundleID() throws {
        let dir    = tempDir.appendingPathComponent("MetaApps")
        let name   = "MetaApp"
        let appURL = dir.appendingPathComponent("\(name).app")
        let macosDir = appURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: arm64BinaryURL,
                                         to: macosDir.appendingPathComponent(name))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleExecutable</key><string>\(name)</string>
          <key>CFBundleShortVersionString</key><string>3.1.4</string>
          <key>CFBundleIdentifier</key><string>com.test.metaapp</string>
        </dict>
        </plist>
        """
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        let results = scanApps(in: [dir])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].version,  "3.1.4")
        XCTAssertEqual(results[0].bundleID, "com.test.metaapp")
    }
}
