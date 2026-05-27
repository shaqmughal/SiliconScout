import SwiftUI
import Foundation
import SiliconScoutCore

// MARK: - ViewModel

final class AppStore: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var isLoading = true

    func load() {
        isLoading = true
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
    @State private var selectedApp: AppInfo?

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
            .toolbar { toolbarItems }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { store.load() }
        .sheet(item: $selectedApp) { app in
            GetInfoSheet(app: app)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                exportToFile()
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .help("Save results as a CSV file")
            .disabled(store.isLoading)

            Button {
                store.load()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-scan applications")
            .disabled(store.isLoading)
        }
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
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([app.url])
                    }
                    Button("Get Info") {
                        selectedApp = app
                    }
                    Divider()
                    Button("Copy Name") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.name, forType: .string)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(app.url.path, forType: .string)
                    }
                    Divider()
                    Button("Export All as CSV…") {
                        exportToFile()
                    }
                }
                .onTapGesture(count: 2) {
                    NSWorkspace.shared.activateFileViewerSelecting([app.url])
                }
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

    // MARK: Export

    private func exportToFile() {
        let csv = formatCSV(displayed)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SiliconScout Export.csv"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }


}

// MARK: - Get Info Sheet

struct GetInfoSheet: View {
    let app: AppInfo
    @Environment(\.dismiss) private var dismiss
    @State private var kind: String = "Application"
    @State private var created: Date?
    @State private var modified: Date?
    @State private var byteSize: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                AppIconView(url: app.url)
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                    ArchBadge(arch: app.arch)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Fields
            Form {
                infoRow(label: "Kind",       value: kind)
                if let v = app.version   { infoRow(label: "Version",   value: v) }
                if let b = app.bundleID  { infoRow(label: "Bundle ID", value: b) }
                if let s = byteSize      { infoRow(label: "Size",      value: formatSize(s)) }
                infoRow(label: "Location", value: app.url.deletingLastPathComponent().path)
                if let c = created  { infoRow(label: "Created",  value: formatDate(c)) }
                if let m = modified { infoRow(label: "Modified", value: formatDate(m)) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .task { loadFileAttributes() }
    }

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadFileAttributes() {
        let url = app.url
        Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [
                .localizedTypeDescriptionKey,
                .creationDateKey,
                .contentModificationDateKey,
                .totalFileSizeKey,
            ])
            let kindResult  = values?.localizedTypeDescription ?? "Application"
            let createdAt   = values?.creationDate
            let modifiedAt  = values?.contentModificationDate
            let size        = values?.totalFileSize
            await MainActor.run {
                kind     = kindResult
                created  = createdAt
                modified = modifiedAt
                byteSize = size
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    private func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - App Row

struct AppRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(url: app.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                if let version = app.version {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
