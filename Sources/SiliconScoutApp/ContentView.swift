import SwiftUI
import Foundation
import SiliconScoutCore

// MARK: - ViewModel

final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isLoading = true

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let dirs: [URL] = [
                URL(fileURLWithPath: "/Applications"),
                URL(fileURLWithPath: "/System/Applications"),
                home.appendingPathComponent("Applications"),
            ]
            let result = scanApps(in: dirs)
            DispatchQueue.main.async {
                self.apps = result
                self.isLoading = false
            }
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var store = AppStore()
    @State private var searchText = ""
    @State private var filterArch: AppArchitecture?

    var displayed: [AppInfo] {
        store.apps.filter { app in
            let archMatch   = filterArch == nil || app.arch == filterArch
            let searchMatch = searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
            return archMatch && searchMatch
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                if store.isLoading {
                    loadingView
                } else {
                    appList
                    Divider()
                    statusBar
                }
            }
            .navigationTitle("SiliconScout")
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search apps")
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { store.load() }
    }

    // MARK: Filter chips

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isSelected: filterArch == nil) {
                    filterArch = nil
                }
                ForEach(
                    [AppArchitecture.appleSilicon, .universal, .intel, .unknown],
                    id: \.rawValue
                ) { arch in
                    let count = store.apps.filter { $0.arch == arch }.count
                    if count > 0 {
                        FilterChip(
                            label: "\(arch.rawValue) (\(count))",
                            isSelected: filterArch == arch
                        ) {
                            filterArch = filterArch == arch ? nil : arch
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text("Scanning apps…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: App list

    private var appList: some View {
        List(displayed, id: \.name) { app in
            AppRow(app: app)
        }
        .listStyle(.inset)
        .overlay {
            if displayed.isEmpty && !store.isLoading {
                Text("No apps match").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack {
            Text(
                searchText.isEmpty && filterArch == nil
                    ? "\(store.apps.count) apps"
                    : "\(displayed.count) of \(store.apps.count) apps"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - App Row

struct AppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.url)
            Text(app.name)
            Spacer()
            ArchBadge(arch: app.arch)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - App Icon

struct AppIconView: View {
    let url: URL
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.15))
            }
        }
        .frame(width: 32, height: 32)
        .task {
            let path = url.path
            icon = await Task.detached(priority: .utility) {
                NSWorkspace.shared.icon(forFile: path)
            }.value
        }
    }
}

// MARK: - Architecture Badge

struct ArchBadge: View {
    let arch: AppArchitecture

    var body: some View {
        Text(arch.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(archColor.opacity(0.15))
            .foregroundStyle(archColor)
            .clipShape(Capsule())
    }

    private var archColor: Color {
        switch arch {
        case .appleSilicon: return .green
        case .universal:    return .blue
        case .intel:        return .orange
        case .unknown:      return .gray
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
