# SiliconScout

A macOS utility that scans your installed applications and reports whether each
one is **Apple Silicon** (arm64), **Intel** (x86_64, runs via Rosetta 2), or
**Universal** (both).

## How it works

For every `.app` in `/Applications`, `/System/Applications`, and
`~/Applications`, SiliconScout reads the Mach-O slices of the bundle's
executable via Foundation's `Bundle.executableArchitectures` and classifies it.

## Running the CLI prototype

Requires the Swift toolchain (bundled with the Xcode Command Line Tools):

```sh
swift run siliconscout
```

## Roadmap

- [x] Command-line prototype that classifies installed apps
- [ ] SwiftUI app with a searchable, sortable list
- [ ] Filter by architecture; highlight Intel-only apps
- [ ] Export results
