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
    let games: [GameRecord]
    let accountScopeKey: String

    @State private var platform: ExportPlatform = .all
    @State private var minimumHours = 1
    @State private var copied = false
	@State private var showSettings = false
	@State private var showChat = false
	@State private var hasAIConfiguration = AISettingsStore.isConfigured
	@State private var isAnalyzing = false
	@State private var analysisText = ""
	@State private var analysisError: String?
	@State private var copiedAnalysis = false
    @State private var showProfileHistory = false

    private let hourPresets = [1, 2, 10, 50]

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
				SettingsView()
			}
			.sheet(isPresented: $showChat) {
				AIChatListView(games: games, accountScopeKey: accountScopeKey)
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
        }
    }

	private var hasChatGames: Bool {
		games.contains { $0.totalMinutes > AIPrompts.chatMinimumMinutes }
	}

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image("BrandIcon")
                .resizable().scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
			VStack(alignment: .leading, spacing: 3) {
                Text("读懂你的游戏习惯")
					.font(.title3.bold())
				Text("从游玩记录生成人格，也可以继续聊游戏。")
					.font(.caption)
					.foregroundStyle(YJColor.muted)
					.lineLimit(2)
            }
            Spacer(minLength: 0)
			Button {
				showChat = true
			} label: {
				VStack(spacing: 4) {
					Image(systemName: "bubble.left.and.bubble.right.fill")
						.font(.subheadline.bold())
					Text("聊天").font(.caption2.bold())
				}
				.foregroundStyle(.white)
				.frame(width: 54, height: 50)
				.background(YJColor.ink, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
			}
			.buttonStyle(.plain)
			.disabled(!hasChatGames)
			.opacity(hasChatGames ? 1 : 0.4)
			.accessibilityLabel(hasChatGames ? "打开游戏聊天" : "没有可用于聊天的游戏")
        }
        .overlay(alignment: .bottomTrailing) {
            if allProfiles.contains(where: { $0.accountScopeKey == accountScopeKey }) {
                Button { showProfileHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption.bold()).foregroundStyle(YJColor.purple)
                        .padding(7).background(.white, in: Circle())
                }
                .offset(y: 15)
                .accessibilityLabel("查看历史人格")
            }
        }
    }

	private var aiAnalysisCard: some View {
		VStack(alignment: .leading, spacing: 18) {
			HStack(spacing: 12) {
				Image(systemName: "sparkles")
					.font(.headline.bold()).foregroundStyle(.white)
					.frame(width: 42, height: 42)
					.background(YJColor.purple, in: RoundedRectangle(cornerRadius: 13))
				VStack(alignment: .leading, spacing: 3) {
					Text("生成游戏人格").font(.headline)
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
						if isAnalyzing { ProgressView().tint(.white) }
						Image(systemName: hasAIConfiguration ? "sparkles" : "key.fill")
						Text(isAnalyzing ? "正在分析游戏足迹…" : hasAIConfiguration ? "生成游戏人格" : "先配置 AI 服务")
					}
					.font(.headline)
					.frame(maxWidth: .infinity).padding(.vertical, 14)
				}
				.buttonStyle(.plain)
				.foregroundStyle(.white)
				.background(
					filteredGames.isEmpty ? YJColor.muted : YJColor.ink,
					in: RoundedRectangle(cornerRadius: 16, style: .continuous)
				)
				.disabled(filteredGames.isEmpty || isAnalyzing)
			} else {
				VStack(alignment: .leading, spacing: 13) {
					HStack(spacing: 7) {
						Image(systemName: "person.crop.circle.badge.checkmark")
						Text("你的游戏人格")
					}
					.font(.caption.bold()).foregroundStyle(YJColor.purple)

					Text(renderedAnalysis)
						.font(.system(size: 15, weight: .regular, design: .rounded))
						.foregroundStyle(YJColor.ink)
						.lineSpacing(7)
						.textSelection(.enabled)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				.padding(16)
				.background(
					LinearGradient(
						colors: [Color.white.opacity(0.92), YJColor.purple.opacity(0.055)],
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
						Label(isAnalyzing ? "分析中" : "重新生成", systemImage: "arrow.clockwise")
					}
					.disabled(isAnalyzing)
                    ShareLink(item: analysisText) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
				}
				.font(.caption.bold()).buttonStyle(.bordered).tint(YJColor.ink)
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
		(try? AttributedString(markdown: analysisText)) ?? AttributedString(analysisText)
	}

	private func generateAnalysis() {
		let apiKey = AISettingsStore.apiKey
		let model = AISettingsStore.modelName
		guard !apiKey.isEmpty, !model.isEmpty else {
			hasAIConfiguration = false
			showSettings = true
			return
		}
		let payload = analysisGames
		isAnalyzing = true
		analysisError = nil
		Task {
			do {
				let result = try await AIAnalysisClient.shared.analyze(games: payload, apiKey: apiKey, model: model)
                analysisText = result
                modelContext.insert(AIProfileResult(
                    accountScopeKey: accountScopeKey,
                    platformFilter: platform.rawValue,
                    minimumHours: minimumHours,
                    text: result,
                    gameCount: payload.count,
                    totalMinutes: payload.reduce(0) { $0 + $1.totalMinutes }
                ))
                try? modelContext.save()
			} catch is CancellationError {
				// Leaving the view cancels work without presenting an error.
			} catch {
				analysisError = error.localizedDescription
			}
			isAnalyzing = false
		}
	}

	private func resetAnalysis() {
		analysisText = ""
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
				.tint(YJColor.ink)
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
                    if game.platinumTrophiesEarned > 0 {
                        Label("已白金", systemImage: "sparkles")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(YJColor.ink)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                LinearGradient(
                                    colors: [Color.white, Color(red: 0.62, green: 0.85, blue: 0.98)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
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
