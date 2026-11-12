import CoreTransferable
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct AIGeneratedImageTile: View {
    let image: AIGeneratedImage
    @State private var thumbnail: UIImage?
    @State private var showsPreview = false

    var body: some View {
        Button { showsPreview = true } label: {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else {
                    Label("图片暂时无法读取", systemImage: "photo")
                        .frame(maxWidth: .infinity).padding(30)
                }
            }
            .frame(maxWidth: .infinity).frame(maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).accessibilityLabel("查看生成的图片，可保存或分享")
        .task(id: image.id) { thumbnail = AIImageValidation.thumbnail(image.pngData) }
        .sheet(isPresented: $showsPreview) {
            AIImagePreviewView(data: image.pngData)
        }
    }
}

private struct ShareableAIImage: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}

private struct AIImagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let data: Data
    @State private var preview: UIImage?
    @State private var isSaving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                        Button {
                            isSaving = true
                            Task {
                                defer { isSaving = false }
                                do { try await AIImageService.saveToPhotos(data); message = "图片已保存到相册。" }
                                catch { message = error.localizedDescription }
                            }
                        } label: {
                            Label(isSaving ? "正在保存…" : "保存到相册", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity).padding(14)
                        }.buttonStyle(YJPrimaryButtonStyle()).disabled(isSaving)
                        ShareLink(item: ShareableAIImage(data: data), preview: SharePreview("游迹 · 游戏画像", image: Image(uiImage: preview))) {
                            Label("分享图片", systemImage: "square.and.arrow.up")
                        }.buttonStyle(.bordered)
                    } else {
                        ContentUnavailableView("图片暂时无法读取", systemImage: "photo")
                    }
                }.padding(18)
            }
            .background(YJBackground()).navigationTitle("游戏画像").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .task { preview = AIImageValidation.thumbnail(data, maximumSize: 1_536) }
            .alert("保存图片", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(message ?? "") }
        }
    }
}

struct AIProfileImageSection: View {
    @Environment(\.modelContext) private var modelContext
    let profile: AIProfileResult
    @Query private var images: [AIGeneratedImage]
    @State private var style = ""
    @State private var task: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showsSettings = false
    @State private var configured = AISettingsStore.isConfigured

    init(profile: AIProfileResult) {
        self.profile = profile
        let id = profile.id
        let scope = profile.accountScopeKey
        _images = Query(filter: #Predicate<AIGeneratedImage> {
            $0.ownerID == id && $0.originRaw == "profile" && $0.accountScopeKey == scope
        }, sort: \AIGeneratedImage.createdAt, order: .reverse)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("把分析变成游戏画像", systemImage: "photo.artframe").font(.headline)
            if let latest = images.first { AIGeneratedImageTile(image: latest) }
            if images.count > 1 {
                DisclosureGroup("此前的画像（\(images.count - 1)）") {
                    ForEach(Array(images.dropFirst())) { AIGeneratedImageTile(image: $0) }
                }
            }
            DisclosureGroup("画面偏好（可选）") {
                TextField("例如：像素冒险、手绘水彩、宇宙探索", text: $style, axis: .vertical)
                    .lineLimit(2...5).font(.body).padding(12)
                    .background(YJColor.paper, in: RoundedRectangle(cornerRadius: 12))
            }.font(.caption.bold()).disabled(isGenerating)
            Button {
                if configured { generate() } else { showsSettings = true }
            } label: {
                HStack {
                    if isGenerating { ProgressView().controlSize(.small) }
                    Text(isGenerating ? "正在创作画像…" : configured ? (images.isEmpty ? "生成游戏画像" : "再生成一张") : "配置 OpenAI 后生成画像")
                }.frame(maxWidth: .infinity).padding(12)
            }.buttonStyle(.bordered).tint(YJColor.lime).disabled(isGenerating)
            if isGenerating { Button("停止生成", role: .destructive) { cancel() }.font(.caption.bold()) }
            Text("仅使用这份分析和你的画面偏好。生成图片会消耗 OpenAI API 额度，完成后保存在本机。")
                .font(.caption2).foregroundStyle(YJColor.muted)
        }
        .sheet(isPresented: $showsSettings, onDismiss: { configured = AISettingsStore.isConfigured }) {
            SettingsView(prioritizesAIConfiguration: true)
        }
        .alert("画像未能生成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
        .onDisappear { cancel() }
        .onChange(of: profile.text) { _, _ in cancel() }
    }

    private func generate() {
        guard !isGenerating else { return }
        guard AISettingsStore.isConfigured else { configured = false; showsSettings = true; return }
        let key = AISettingsStore.apiKey
        let model = AISettingsStore.imageModelName
        let text = profile.text
        let profileID = profile.id
        let scope = profile.accountScopeKey
        let revision = LocalDataRevision.current
        let prompt = AIPrompts.profileImagePrompt(analysis: text, style: style.trimmingCharacters(in: .whitespacesAndNewlines))
        let id = UUID()
        requestID = id
        isGenerating = true
        errorMessage = nil
        task = Task {
            defer { if requestID == id { task = nil; requestID = nil; isGenerating = false } }
            do {
                try LocalDataRevision.check(revision)
                let data = try await AIAnalysisClient.shared.generateImage(prompt: prompt, apiKey: key, model: model, portrait: true)
                guard requestID == id else { return }
                try AIImageService.saveProfileImage(data: data, prompt: prompt, model: model, profileID: profileID,
                    accountScope: scope, expectedText: text, revision: revision, in: modelContext)
            } catch is CancellationError { }
            catch {
                guard requestID == id, revision == LocalDataRevision.current else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        requestID = nil
        isGenerating = false
    }
}
