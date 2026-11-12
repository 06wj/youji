import SwiftData
import SwiftUI
import UIKit

private enum ExportPlatform: String, CaseIterable {
    case all = "全部"
    case playStation = "PlayStation"
    case switchConsole = "Switch"

    var platform: GamePlatform? {
        switch self {
        case .all: nil
        case .playStation: .playStation
        case .switchConsole: .switchConsole
        }
    }
}

struct AIAnalysisView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AIProfileResult.generatedAt, order: .reverse) private var allProfiles: [AIProfileResult]
    @Query private var allConversations: [AIConversation]
    let games: [GameRecord]
    let accountScopeKey: String

    @State private var platform: ExportPlatform = .all
    @State private var minimumHours = 1
    @State private var copied = false
	@State private var showSettings = false
	@State private var showChat = false
	@State private var hasAIConfiguration = AISettingsStore.isConfigured
	@State private var isAnalyzing = false
	@State private var chatDraft: String?
	@State private var analysisError: String?
	@State private var copiedAnalysis = false
    @State private var showProfileHistory = false
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisRequestID: UUID?
    @State private var restoredProfileScope: String?

    private let hourPresets = [1, 2, 10, 50]

    private var currentProfile: AIProfileResult? {
        AIProfileSelection.latest(in: allProfiles, accountScope: accountScopeKey,
                                  platform: platform.rawValue, minimumHours: minimumHours)
    }
    private var analysisText: String { currentProfile?.text ?? "" }
    private var profileDataHasChanged: Bool {
        guard let currentProfile else { return false }
        if !currentProfile.inputFingerprint.isEmpty {
            return currentProfile.inputFingerprint != AIGameContext.fingerprint(analysisGames)
        }
        return currentProfile.gameCount != filteredGames.count || currentProfile.totalMinutes != filteredMinutes
    }

    private var filteredGames: [GameRecord] {
        games
            .filter { game in
                let matchesPlatform = platform.platform.map { game.platform == $0 } ?? true
                let matchesTime = game.totalMinutes > minimumHours * 60
                return matchesPlatform && matchesTime
            }
            .sorted {
                if $0.totalMinutes == $1.totalMinutes {
                    return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                }
                return $0.totalMinutes > $1.totalMinutes
            }
    }

    private var filteredMinutes: Int { filteredGames.reduce(0) { $0 + $1.totalMinutes } }
	private var analysisGames: [AIAnalysisGame] {
		filteredGames.map { game in
			AIAnalysisGame(
				platform: game.platform.shortName,
				title: game.title,
				totalMinutes: game.totalMinutes,
				trophyRatio: game.platform == .playStation && game.trophiesDefined > 0
					? trophyText(game)
					: nil
			)
		}
	}

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 24) {
					headerSection
					aiAnalysisCard
                    preview
                }
                .padding(.horizontal, 18)
				.padding(.top, 10)
				.padding(.bottom, 38)
            }
            .background(exportBackground)
			.navigationTitle("游戏大脑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
				ToolbarItem(placement: .topBarTrailing) {
					Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
				}
            }
			.sheet(isPresented: $showSettings, onDismiss: {
				hasAIConfiguration = AISettingsStore.isConfigured
			}) {
				SettingsView(prioritizesAIConfiguration: true)
			}
			.sheet(isPresented: $showChat) {
				AIChatListView(games: games, accountScopeKey: accountScopeKey, initialDraft: chatDraft)
			}
            .sheet(isPresented: $showProfileHistory) {
                AIProfileHistoryView(accountScopeKey: accountScopeKey)
            }
			.alert("AI 分析失败", isPresented: Binding(
				get: { analysisError != nil },
				set: { if !$0 { analysisError = nil } }
			)) {
				Button("知道了", role: .cancel) {}
			} message: {
				Text(analysisError ?? "未知错误")
			}
			.onChange(of: platform) { _, _ in resetAnalysis() }
			.onChange(of: minimumHours) { _, _ in resetAnalysis() }
            .onChange(of: accountScopeKey) { _, _ in resetAnalysis() }
            .task(id: accountScopeKey) {
                // Returning to Game Brain restores the latest saved result and its
                // original scope. Reading local history never triggers a request.
                guard restoredProfileScope != accountScopeKey else { return }
                restoredProfileScope = accountScopeKey
                if let latest = AIProfileSelection.latest(in: allProfiles, accountScope: accountScopeKey),
                   let savedPlatform = ExportPlatform(rawValue: latest.platformFilter),
                   hourPresets.contains(latest.minimumHours) {
                    platform = savedPlatform
                    minimumHours = latest.minimumHours
                }
            }
            .onDisappear { cancelAnalysis() }
        }
    }

	private var hasChatGames: Bool {
		games.contains { $0.totalMinutes > AIPrompts.chatMinimumMinutes }
	}

    private var hasChatHistory: Bool {
        allConversations.contains { $0.accountScopeKey == accountScopeKey }
    }

    private var headerSection: some View {
        VStack(spacing: 13) {
            if profileCount > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(YJColor.lime)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("继续认识你的游戏偏好").font(.headline)
                        Text("上次的分析已保存，也可以从今天的心情开始聊。")
                            .font(.caption).foregroundStyle(YJColor.muted)
                    }
                    Spacer(minLength: 0)
                }.padding(18).background(YJArtwork(name: "MemoryCrystal", shade: 0.65)).youjiCard()
            } else {
            YJFeatureHeading(
                eyebrow: "YOUR GAME DNA",
                title: "每次选择，\n都藏着一个你。",
                subtitle: "从游戏足迹，发现你的玩家人格。",
                artwork: "MemoryCrystal"
            )

            }

            HStack(spacing: 10) {
                Button { chatDraft = nil; showChat = true } label: {
                    brainShortcut(
                        title: "游戏聊天",
                        detail: hasChatGames ? "选下一款游戏" : hasChatHistory ? "查看历史对话" : "暂无可用游戏",
                        icon: "bubble.left.and.bubble.right.fill",
                        foreground: YJColor.paper,
                        background: YJColor.lime,
                        showsBorder: false
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasChatGames && !hasChatHistory)
                .opacity(hasChatGames || hasChatHistory ? 1 : 0.45)

                Button { showProfileHistory = true } label: {
                    brainShortcut(
                        title: "人格历史",
                        detail: "已保存 \(profileCount) 次",
                        icon: "clock.arrow.circlepath",
                        foreground: YJColor.ink,
                        background: YJColor.card,
                        showsBorder: true
                    )
                }
                .buttonStyle(.plain)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { scenarioButtons }
                VStack(alignment: .leading, spacing: 10) { scenarioButtons }
            }
            .font(.caption.bold()).buttonStyle(.bordered).tint(YJColor.lime)
            .disabled(!hasChatGames)
        }
    }

    @ViewBuilder
    private var scenarioButtons: some View {
        Button { openChat(draft: AIPrompts.shortSessionDraft) } label: {
            Label("今晚只有 30 分钟", systemImage: "moon.stars")
        }
        Button { openChat(draft: AIPrompts.replayDraft) } label: {
            Label("从已有游戏选一款重温", systemImage: "arrow.counterclockwise")
        }
    }

    private func openChat(draft: String) {
        chatDraft = draft
        showChat = true
    }

    private var profileCount: Int {
        allProfiles.filter { $0.accountScopeKey == accountScopeKey }.count
    }

    private func brainShortcut(
        title: String,
        detail: String,
        icon: String,
        foreground: Color,
        background: Color,
        showsBorder: Bool
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.bold())
                Text(detail).font(.caption2).opacity(0.65).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 15)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if showsBorder {
                RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(YJColor.line)
            }
        }
    }

	private var aiAnalysisCard: some View {
		VStack(alignment: .leading, spacing: 18) {
			HStack(spacing: 12) {
				Image(systemName: "sparkles")
					.font(.headline.bold()).foregroundStyle(YJColor.lime)
					.frame(width: 42, height: 42)
					.background(YJColor.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
				VStack(alignment: .leading, spacing: 3) {
					Text(currentProfile == nil ? "生成游戏人格" : "最近的人格分析").font(.headline)
					Text("偏好、投入深度与挑战倾向")
						.font(.caption).foregroundStyle(YJColor.muted)
				}
				Spacer(minLength: 0)
				VStack(alignment: .trailing, spacing: 2) {
					Text("\(filteredGames.count) 款").font(.subheadline.bold())
					Text(format(minutes: filteredMinutes))
						.font(.caption2).foregroundStyle(YJColor.muted)
				}
			}

			filterControls

			if analysisText.isEmpty {
				Button {
					if hasAIConfiguration { generateAnalysis() } else { showSettings = true }
				} label: {
					HStack(spacing: 8) {
						if isAnalyzing { ProgressView().tint(YJColor.paper) }
						Image(systemName: hasAIConfiguration ? "sparkles" : "key.fill")
						Text(isAnalyzing ? "正在分析游戏足迹…" : hasAIConfiguration ? "生成游戏人格" : "先配置 AI 服务")
					}
					.font(.headline)
					.frame(maxWidth: .infinity).padding(.vertical, 14)
				}
                .buttonStyle(YJPrimaryButtonStyle())
				.disabled(filteredGames.isEmpty || isAnalyzing)
			} else {
				VStack(alignment: .leading, spacing: 13) {
					HStack(spacing: 7) {
						Image(systemName: "person.crop.circle.badge.checkmark")
						Text("你的游戏人格")
					}
					.font(.caption.bold()).foregroundStyle(YJColor.purple)

                    if let profile = currentProfile {
                        Text("\(profile.generatedAt.formatted(.dateTime.year().month().day())) · \(profile.platformFilter) · > \(profile.minimumHours)h · \(profile.gameCount) 款")
                            .font(.caption2).foregroundStyle(YJColor.muted)
                        if profileDataHasChanged {
                            Label("游戏记录有变化，可以主动更新人格。", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption).foregroundStyle(YJColor.lime)
                        }
                    }
					Text(renderedAnalysis)
						.font(.body)
						.foregroundStyle(YJColor.ink)
						.lineSpacing(7)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.padding(16)
				.background(
					LinearGradient(
						colors: [YJColor.elevated, YJColor.card],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					),
					in: RoundedRectangle(cornerRadius: 17, style: .continuous)
				)
				.overlay(
					RoundedRectangle(cornerRadius: 17, style: .continuous)
						.stroke(YJColor.purple.opacity(0.14), lineWidth: 1)
				)

				HStack(spacing: 9) {
					Button {
						UIPasteboard.general.string = analysisText
						copiedAnalysis = true
						DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copiedAnalysis = false }
					} label: {
						Label(copiedAnalysis ? "已复制" : "复制分析", systemImage: copiedAnalysis ? "checkmark" : "doc.on.doc")
					}
					Button(action: generateAnalysis) {
						Label(isAnalyzing ? "分析中" : "更新人格", systemImage: "arrow.clockwise")
					}
					.disabled(isAnalyzing || filteredGames.isEmpty)
                    ShareLink(item: analysisText) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
				}
				.font(.caption.bold()).buttonStyle(.bordered).tint(YJColor.lime)
                if let profile = currentProfile {
                    AIProfileImageSection(profile: profile).id(profile.id)
                        .padding(.vertical, 10)
                }
                Button { openChat(draft: AIPrompts.profileFollowUpDraft(analysisText)) } label: {
                    Label("围绕这份分析继续聊", systemImage: "bubble.left.and.bubble.right")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(YJPrimaryButtonStyle()).disabled(!hasChatGames)
                Text("新对话使用当前账号全部游玩超过 1 小时的游戏；分析会放入草稿，点发送才交给 AI。")
                    .font(.caption2).foregroundStyle(YJColor.muted)
			}

			Label("仅发送以上游戏的名称、平台、时长与奖杯比例", systemImage: "lock.shield")
				.font(.caption2).foregroundStyle(YJColor.muted)
		}
		.padding(18)
		.youjiCard()
	}

	private var filterControls: some View {
		HStack(spacing: 10) {
			Menu {
				ForEach(ExportPlatform.allCases, id: \.self) { item in
					Button {
						platform = item
					} label: {
						if platform == item {
							Label(item.rawValue, systemImage: "checkmark")
						} else {
							Text(item.rawValue)
						}
					}
				}
			} label: {
				filterMenuLabel(icon: "gamecontroller.fill", title: "平台", value: platform.rawValue)
			}
			.frame(maxWidth: .infinity)

			Menu {
				ForEach(hourPresets, id: \.self) { hours in
					Button {
						minimumHours = hours
					} label: {
						if minimumHours == hours {
							Label("超过 \(hours) 小时", systemImage: "checkmark")
						} else {
							Text("超过 \(hours) 小时")
						}
					}
				}
			} label: {
				filterMenuLabel(icon: "clock.fill", title: "时长", value: "> \(minimumHours)h")
			}
			.frame(maxWidth: .infinity)
		}
	}

	private func filterMenuLabel(icon: String, title: String, value: String) -> some View {
		HStack(spacing: 9) {
			Image(systemName: icon)
				.font(.caption.bold())
				.foregroundStyle(YJColor.purple)
			VStack(alignment: .leading, spacing: 1) {
				Text(title).font(.caption2).foregroundStyle(YJColor.muted)
				Text(value).font(.subheadline.bold()).lineLimit(1)
			}
			Spacer(minLength: 0)
			Image(systemName: "chevron.up.chevron.down")
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(YJColor.muted)
		}
		.foregroundStyle(YJColor.ink)
		.frame(maxWidth: .infinity)
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(YJColor.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.contentShape(Rectangle())
	}

	private var renderedAnalysis: AttributedString {
		YJText.markdown(analysisText)
	}

    private func generateAnalysis() {
        let apiKey = AISettingsStore.apiKey
        let model = AISettingsStore.modelName
        guard AISettingsStore.isConfigured else {
            hasAIConfiguration = false
            showSettings = true
            return
        }
        cancelAnalysis()
        let requestID = UUID()
        analysisRequestID = requestID
        let revision = LocalDataRevision.current
        let request = AIProfileRequest(accountScopeKey: accountScopeKey, platformFilter: platform.rawValue,
                                       minimumHours: minimumHours, games: analysisGames)
        isAnalyzing = true
        analysisError = nil
        analysisTask = Task {
            defer {
                if analysisRequestID == requestID { cancelAnalysis() }
            }
            do {
                let result = try await AIAnalysisClient.shared.analyze(games: request.games, apiKey: apiKey, model: model)
                try LocalDataRevision.check(revision)
                guard analysisRequestID == requestID else { return }
                let profile = request.result(text: result)
                try LocalPersistence.transaction(modelContext) { $0.insert(profile) }
            } catch {
                guard analysisRequestID == requestID, revision == LocalDataRevision.current,
                      !Task.isCancelled, !(error is CancellationError) else { return }
                analysisError = error.localizedDescription
            }
        }
    }

    private func cancelAnalysis() {
        analysisTask?.cancel()
        analysisTask = nil
        analysisRequestID = nil
        isAnalyzing = false
    }

    private func resetAnalysis() {
        cancelAnalysis()
        analysisError = nil
        copiedAnalysis = false
    }

    private var preview: some View {
        let previewGames = filteredGames
        let previewMinutes = previewGames.reduce(0) { $0 + $1.totalMinutes }
        let lastGameID = previewGames.last?.applicationID

        return VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
					Text("分析依据").font(.title3.bold())
					Text("\(previewGames.count) 款 · \(format(minutes: previewMinutes)) · 按时长排序")
						.font(.caption).foregroundStyle(YJColor.muted)
                }
                Spacer(minLength: 0)
				Button(action: copySourceData) {
					Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
						.font(.caption.bold())
				}
				.buttonStyle(.bordered)
				.tint(YJColor.lime)
				.controlSize(.small)
				.disabled(previewGames.isEmpty)
            }

            if previewGames.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(YJColor.purple)
                    Text("没有符合条件的游戏").font(.headline)
                    Text("调整上方的平台或时长范围。 ").font(.caption).foregroundStyle(YJColor.muted)
                }
                .frame(maxWidth: .infinity)
				.padding(.vertical, 36)
				.background(YJColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 20).stroke(YJColor.line))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(previewGames.enumerated()), id: \.element.applicationID) { index, game in
                        exportRow(index: index, game: game)
                        if game.applicationID != lastGameID { Divider() }
                    }
                }
				.padding(.horizontal, 16)
				.background(YJColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
				.overlay(RoundedRectangle(cornerRadius: 20).stroke(YJColor.line))
            }
        }
    }

    private func exportRow(index: Int, game: GameRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            CachedCoverImage(urlString: game.imageURL)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    Text("\(index + 1)")
                        .font(.system(size: 8, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: Capsule())
                        .offset(x: -4, y: 4)
                }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(game.platform.shortName)
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(game.platform == .playStation ? Color.blue : Color.red, in: Capsule())
                    Text(game.title).font(.subheadline.bold()).lineLimit(2)
                    if game.platform == .playStation, game.platinumTrophiesEarned > 0 {
                        PlatinumBadge()
                    }
                }
                HStack(spacing: 12) {
                    Label(format(minutes: game.totalMinutes), systemImage: "clock.fill")
					if game.platform == .playStation {
						Label(trophyText(game), systemImage: "trophy.fill")
					}
                }
                .font(.caption2).foregroundStyle(YJColor.muted)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 11)
    }

	private func copySourceData() {
		guard !filteredGames.isEmpty else { return }
		UIPasteboard.general.string = exportText
		copied = true
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
    }

    private var exportText: String {
        var lines = [
            "游迹游戏记录",
            "筛选：平台=\(platform.rawValue)，最低时长=>\(minimumHours)h",
            "排序：游戏时长从高到低",
            "字段：游戏名称 | 游戏时长 | 奖杯数占比",
        ]
        lines.append(contentsOf: filteredGames.enumerated().map { index, game in
            "\(index + 1). \(game.title) | \(format(minutes: game.totalMinutes)) | \(trophyText(game))"
        })
        return lines.joined(separator: "\n")
    }

    private func trophyText(_ game: GameRecord) -> String {
		guard game.platform == .playStation else { return "不适用" }
		guard game.trophiesDefined > 0 else { return "暂无数据" }
        let percent = Int((Double(game.trophiesEarned) / Double(game.trophiesDefined) * 100).rounded())
        let platinum = game.platinumTrophiesEarned > 0 ? " · 已白金" : ""
        return "\(game.trophiesEarned)/\(game.trophiesDefined)（\(percent)%）\(platinum)"
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var exportBackground: some View {
		LinearGradient(
			colors: [YJColor.paper, YJColor.card.opacity(0.72), YJColor.paper],
			startPoint: .top,
			endPoint: .bottom
		)
		.ignoresSafeArea()
    }
}
