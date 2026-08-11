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

struct ExportDataView: View {
    @Environment(\.dismiss) private var dismiss
    let games: [GameRecord]

    @State private var platform: ExportPlatform = .all
    @State private var minimumHours = 1
    @State private var copied = false

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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    introCard
                    filters
                    preview
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 110)
            }
            .background(exportBackground)
            .navigationTitle("分析导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { copyBar }
        }
    }

    private var introCard: some View {
        HStack(spacing: 15) {
            Image("BrandIcon")
                .resizable().scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("导出给 AI 分析").font(.headline)
                Text("筛选并预览游戏记录，一键复制给 AI 分析。")
                    .font(.caption).foregroundStyle(YJColor.muted).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(17)
        .youjiCard()
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionLabel("FILTERS / 筛选")

            VStack(alignment: .leading, spacing: 9) {
                Text("游戏平台").font(.caption.bold()).foregroundStyle(YJColor.muted)
                HStack(spacing: 7) {
                    ForEach(ExportPlatform.allCases, id: \.self) { item in
                        filterChip(item.rawValue, selected: platform == item) { platform = item }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("最低游戏时长").font(.caption.bold()).foregroundStyle(YJColor.muted)
                HStack(spacing: 7) {
                    ForEach(hourPresets, id: \.self) { hours in
                        filterChip("> \(hours)h", selected: minimumHours == hours) {
                            minimumHours = hours
                        }
                    }
                }
            }
        }
        .padding(17)
        .youjiCard()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("PREVIEW / 数据预览")
                    Text("按游戏时长排序").font(.title2.bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(filteredGames.count) 款").font(.headline)
                    Text(format(minutes: filteredMinutes)).font(.caption).foregroundStyle(YJColor.muted)
                }
            }

            if filteredGames.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(YJColor.purple)
                    Text("没有符合条件的游戏").font(.headline)
                    Text("调整平台或最低时长筛选。 ").font(.caption).foregroundStyle(YJColor.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filteredGames.enumerated()), id: \.element.applicationID) { index, game in
                        exportRow(index: index, game: game)
                        if index < filteredGames.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(17)
        .youjiCard()
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
                    Label(trophyText(game), systemImage: "trophy.fill")
                }
                .font(.caption2).foregroundStyle(YJColor.muted)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 11)
    }

    private var copyBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                UIPasteboard.general.string = exportText
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
            } label: {
                Label(copied ? "已复制到剪贴板" : "复制 \(filteredGames.count) 条数据", systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(filteredGames.isEmpty ? YJColor.muted : YJColor.ink, in: Capsule())
            .disabled(filteredGames.isEmpty)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
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
        guard game.platform == .playStation, game.trophiesDefined > 0 else { return "不适用" }
        let percent = Int((Double(game.trophiesEarned) / Double(game.trophiesDefined) * 100).rounded())
        let platinum = game.platinumTrophiesEarned > 0 ? " · 已白金" : ""
        return "\(game.trophiesEarned)/\(game.trophiesDefined)（\(percent)%）\(platinum)"
    }

    private func filterChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.caption.bold()).lineLimit(1)
                .foregroundStyle(selected ? Color.white : YJColor.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? YJColor.ink : YJColor.paper, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .black, design: .monospaced)).tracking(1.2).foregroundStyle(YJColor.muted)
    }

    private func format(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private var exportBackground: some View {
        ZStack {
            YJColor.paper
            Circle().fill(YJColor.lime.opacity(0.10)).frame(width: 260, height: 260).blur(radius: 14).offset(x: 170, y: -330)
            Circle().fill(YJColor.purple.opacity(0.08)).frame(width: 330, height: 330).blur(radius: 18).offset(x: -180, y: 400)
        }.ignoresSafeArea()
    }
}
