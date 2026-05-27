import Foundation
import SiliconScoutCore

let home = FileManager.default.homeDirectoryForCurrentUser
let searchDirs: [URL] = [
    URL(fileURLWithPath: "/Applications"),
    URL(fileURLWithPath: "/System/Applications"),
    home.appendingPathComponent("Applications"),
]

let apps = scanApps(in: searchDirs)

let nameWidth = max("APP".count, apps.map(\.name.count).max() ?? 0)
func pad(_ s: String) -> String {
    s.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
}

print(pad("APP") + "  ARCHITECTURE")
print(String(repeating: "─", count: nameWidth) + "  ────────────")
for app in apps {
    print(pad(app.name) + "  " + app.arch.rawValue)
}

let counts = Dictionary(grouping: apps, by: \.arch).mapValues(\.count)
print("\nScanned \(apps.count) apps:")
for arch in [AppArchitecture.appleSilicon, .universal, .intel, .unknown] {
    if let count = counts[arch], count > 0 {
        print("  \(arch.rawValue): \(count)")
    }
}
