# SiliconScout

A macOS utility that scans your installed applications and reports whether each one is **Apple Silicon** (arm64), **Intel** (x86_64, runs via Rosetta 2), or **Universal** (both).

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-green)

## Features

- Scans `/Applications`, `/System/Applications`, and `~/Applications`
- Detects Apple Silicon, Intel, Universal, and Unknown app binaries
- Handles shell-script launcher apps (e.g. JetBrains, .NET tools) by following the script to the real binary
- Filter by architecture with one click
- Search by app name
- Right-click any app for:
  - **Show in Finder** — reveals the app in Finder
  - **Get Info** — shows Kind, Version, Bundle ID, Size, Location, and dates (mirrors Finder's Get Info panel)
  - **Copy Name / Copy Path**
  - **Export All as CSV** — saves results to a `.csv` file (opens in Numbers or Excel)
- Refresh button to re-scan at any time
- Version number shown per app in the list

## How it works

For every `.app` bundle, SiliconScout reads the Mach-O CPU slices via Foundation's `Bundle.executableArchitectures`. For apps that use a shell-script launcher (common in JetBrains and .NET tools), it parses the script, resolves the real binary, and inspects it via `lipo`.

## Requirements

- macOS 13 Ventura or later
- Xcode 15 / Swift 5.9

## Running

### SwiftUI app

```sh
swift build --target SiliconScoutApp
open .build/debug/SiliconScoutApp.app
```

Or open the package in Xcode (`xed .`) and run the `SiliconScoutApp` target.

### Command-line

```sh
swift run siliconscout
```

## Running tests

```sh
swift test
```

36 unit tests covering architecture classification, lipo fallback, script-launcher resolution, CSV formatting, and app scanning.

## License

MIT — see [LICENSE](LICENSE).
