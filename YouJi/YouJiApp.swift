import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@main
struct YouJiApp: App {
    @StateObject private var database = LocalDatabaseState()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if DesignPreviewData.isEnabled {
                DesignPreviewRoot().preferredColorScheme(.dark).tint(YJColor.lime)
            } else {
                persistentContent
            }
            #else
            persistentContent
            #endif
        }
    }

    @ViewBuilder
    private var persistentContent: some View {
        if let container = database.container {
            appContent.modelContainer(container).tint(YJColor.lime)
        } else {
            DatabaseRecoveryView(database: database)
                .preferredColorScheme(.dark).tint(YJColor.lime)
        }
    }

    @ViewBuilder
    private var appContent: some View {
        #if DEBUG
        if let screenshotRoute = ScreenshotRoute.launchRoute {
            ScreenshotRouteView(route: screenshotRoute).preferredColorScheme(.dark)
        } else {
            DashboardView().preferredColorScheme(.dark)
        }
        #else
        DashboardView().preferredColorScheme(.dark)
        #endif
    }
}

@MainActor
final class LocalDatabaseState: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var failure: String?
    private(set) var storeURL: URL
    private let rootDirectory: URL
    private var expectsExistingStore = false
    private var hasInvalidManifest = false
    private var manifestURL: URL { rootDirectory.appendingPathComponent("youji-active-store.json") }

    static var schema: Schema {
        Schema([GameRecord.self, PlaySnapshot.self, DailyPlayActivity.self,
                AIConversation.self, AIProfileResult.self, SavedGamePlan.self])
    }

    init(storeURL: URL? = nil) {
        let originalURL = storeURL ?? ModelConfiguration(schema: Self.schema).url
        rootDirectory = originalURL.deletingLastPathComponent()
        self.storeURL = originalURL
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                let directory = try JSONDecoder().decode(String.self, from: Data(contentsOf: manifestURL))
                guard directory.hasPrefix("YouJi-Recovered-"),
                      UUID(uuidString: String(directory.dropFirst("YouJi-Recovered-".count))) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                self.storeURL = rootDirectory.appendingPathComponent(directory, isDirectory: true)
                    .appendingPathComponent("default.store")
                expectsExistingStore = true
            } catch {
                hasInvalidManifest = true
                failure = "档案位置暂时无法读取。原始文件仍然保留，请先导出副本。"
                return
            }
        }
        expectsExistingStore = expectsExistingStore || FileManager.default.fileExists(atPath: self.storeURL.path)
        retry()
    }

    func retry() {
        guard !hasInvalidManifest else { return }
        guard !expectsExistingStore || FileManager.default.fileExists(atPath: storeURL.path) else {
            failure = "原有档案文件暂时不可用，已停止新建空档案。请保留备份后重试。"
            return
        }
        do {
            container = try ModelContainer(for: Self.schema, configurations: ModelConfiguration(url: storeURL))
            failure = nil
            expectsExistingStore = true
        } catch {
            failure = error.localizedDescription
        }
    }

    func rawArchive() throws -> RawArchiveDocument {
        try RawArchiveDocument(storeURL: storeURL)
    }

    /// Restore into a new store and switch only after every record is committed.
    /// The unreadable original (including its WAL) is never removed or replaced.
    func recover(from data: Data) throws {
        guard container == nil else { return }
        let directory = rootDirectory.appendingPathComponent("YouJi-Recovered-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let newURL = directory.appendingPathComponent("default.store")
        do {
            let restored = try ModelContainer(for: Self.schema, configurations: ModelConfiguration(url: newURL))
            try ProductDataService.restore(data: data, modelContext: restored.mainContext)
            try JSONEncoder().encode(directory.lastPathComponent).write(to: manifestURL, options: .atomic)
            SyncCoordinator.clearStoredNonCredentialState()
            storeURL = newURL
            hasInvalidManifest = false
            expectsExistingStore = true
            container = restored
            failure = nil
        } catch {
            // Do not unlink a store while an older SwiftData runtime may still
            // have SQLite handles open. No manifest points at this failed attempt.
            throw error
        }
    }
}

struct RawArchiveDocument: FileDocument {
    static let contentType = UTType(exportedAs: "com.youji.playlog.recovery", conformingTo: .package)
    static var readableContentTypes: [UTType] { [contentType] }
    private let serializedArchive: Data

    init(storeURL: URL) throws {
        let folder = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let supportName = ".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT"
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == name || $0.lastPathComponent == name + "-wal"
                || $0.lastPathComponent == name + "-shm" || $0.lastPathComponent == supportName }
        guard files.contains(where: { $0.lastPathComponent == name }) else { throw CocoaError(.fileNoSuchFile) }
        var children: [String: FileWrapper] = [:]
        for file in files { children[file.lastPathComponent] = try FileWrapper(url: file, options: .immediate) }
        guard let data = FileWrapper(directoryWithFileWrappers: children).serializedRepresentation else {
            throw CocoaError(.fileReadUnknown)
        }
        serializedArchive = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.serializedRepresentation else { throw CocoaError(.fileReadUnknown) }
        serializedArchive = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let wrapper = FileWrapper(serializedRepresentation: serializedArchive) else { throw CocoaError(.fileReadCorruptFile) }
        return wrapper
    }
}

private struct DatabaseRecoveryView: View {
    @ObservedObject var database: LocalDatabaseState
    @State private var document: RawArchiveDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.largeTitle).foregroundStyle(YJColor.purple)
                Text("本地档案暂时无法打开").font(.title2.bold())
                Text("原始档案仍然保留。你可以先导出一份副本，也可以从已有的完整备份恢复。恢复会使用新的档案文件，保留原文件。")
                    .foregroundStyle(.secondary)
                Button("导出原始档案") {
                    do {
                        document = try database.rawArchive()
                        exporting = true
                    } catch { message = "导出未完成：\(error.localizedDescription)" }
                }.buttonStyle(.borderedProminent)
                Button("从完整备份恢复") { importing = true }.buttonStyle(.bordered)
                Button("重新尝试打开") { database.retry() }
                DisclosureGroup("查看详情") {
                    Text(database.failure ?? "").font(.caption).textSelection(.enabled)
                    Text("原始档案副本用于保留数据；恢复功能需要此前导出的 JSON 完整备份。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)
            .navigationTitle("档案恢复")
            .fileExporter(isPresented: $exporting, document: document,
                          contentType: RawArchiveDocument.contentType,
                          defaultFilename: "游迹原始档案.youjirecovery") { result in
                if case .failure(let error) = result { message = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try database.recover(from: Data(contentsOf: url))
                } catch { message = error.localizedDescription }
            }
            .alert("档案恢复", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }
}
