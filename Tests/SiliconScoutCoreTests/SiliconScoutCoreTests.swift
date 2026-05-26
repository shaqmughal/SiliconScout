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

    // MARK: - resolveLauncherTarget

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
    }
}
