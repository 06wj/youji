import SwiftData
import SwiftUI

@MainActor
struct PlayTimeAllocationListView: View {
    @Environment(\.dismiss) private var dismiss
    let game: GameRecord
    @Query private var snapshots: [PlaySnapshot]
    @Query private var allocations: [PlayTimeAllocation]
    @State private var selection: AllocationEditorSelection?

    init(game: GameRecord) {
        self.game = game
        let gameID = game.applicationID
        _snapshots = Query(filter: #Predicate<PlaySnapshot> { $0.gameID == gameID }, sort: \PlaySnapshot.date)
        _allocations = Query(filter: #Predicate<PlayTimeAllocation> { $0.gameID == gameID })
    }

    private var values: [PlayTimeAllocationValue] { PlayTimeResolver.values(allocations) }
    private var intervals: [PlayTimeAllocationValue] {
        PlayTimeResolver.editableIntervals(snapshots: snapshots, allocations: values)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(game.title).font(.headline)
                    Text("选择一段新增时长，按实际游玩日期分配。游戏总时长和平台记录保持不变。")
                        .font(.subheadline).foregroundStyle(YJColor.muted)
                }
                if values.count != allocations.count {
                    Section {
                        Text("部分日期记录暂时无法读取，已保留原内容。请先导出原始档案，或使用完整备份恢复。")
                            .foregroundStyle(YJColor.coral)
                    }
                } else if intervals.isEmpty {
                    ContentUnavailableView("还没有可分配的时长", systemImage: "calendar.badge.clock",
                        description: Text("至少需要两次游玩记录，且期间有新增时长。首次同步的累计时长不会被当成当天游玩。"))
                        .listRowBackground(Color.clear)
                } else {
                    Section("时长变化") {
                        ForEach(intervals) { interval in
                            Button {
                                selection = AllocationEditorSelection(value: interval,
                                    expectedUpdatedAt: values.first { $0.id == interval.id }?.updatedAt,
                                    canReset: values.contains { $0.id == interval.id && !$0.isDeleted })
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text("+\(allocationDuration(interval.totalMinutes))").font(.headline)
                                        .foregroundStyle(YJColor.ink)
                                    Text("\(interval.startDayKey) — \(interval.endDayKey)")
                                        .font(.caption).foregroundStyle(YJColor.muted)
                                    if let existing = values.first(where: { $0.id == interval.id && !$0.isDeleted }) {
                                        Text(existing.days.sorted { $0.dayKey < $1.dayKey }.prefix(3).map {
                                            "\($0.dayKey.suffix(5))  \(allocationDuration($0.minutes))"
                                        }.joined(separator: " · ") + (existing.days.count > 3 ? " …" : ""))
                                        .font(.caption2).foregroundStyle(YJColor.muted)
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(YJBackground())
            .navigationTitle("调整游玩日期").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .sheet(item: $selection) { selected in
                PlayTimeAllocationEditor(selection: selected, snapshots: snapshots)
            }
        }
        .tint(YJColor.playStation)
    }
}

private struct AllocationEditorSelection: Identifiable {
    var id: String { value.id }
    let value: PlayTimeAllocationValue
    let expectedUpdatedAt: Date?
    let canReset: Bool
}

private struct AllocationDayDraft: Identifiable, Equatable {
    let id = UUID()
    var dayKey: String
    var hours: String
    var minutes: String

    init(_ value: AllocatedPlayDay) {
        dayKey = value.dayKey
        hours = String(value.minutes / 60)
        minutes = String(value.minutes % 60)
    }

    var value: AllocatedPlayDay? {
        guard let hours = Int(hours), let minutes = Int(minutes), (0...24).contains(hours), (0...59).contains(minutes) else { return nil }
        let total = hours * 60 + minutes
        guard (1...1_440).contains(total) else { return nil }
        return AllocatedPlayDay(dayKey: dayKey, minutes: total)
    }
}

@MainActor
private struct PlayTimeAllocationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: AllocationEditorSelection
    let snapshots: [PlaySnapshot]
    @State private var rows: [AllocationDayDraft]
    @State private var initialRows: [AllocationDayDraft]
    @State private var rangeStart: Date
    @State private var rangeEnd: Date
    @State private var errorMessage: String?
    @State private var confirmingReset = false
    @State private var confirmingDiscard = false
    @State private var revision = LocalDataRevision.current
    @FocusState private var editingNumber: Bool

    init(selection: AllocationEditorSelection, snapshots: [PlaySnapshot]) {
        self.selection = selection
        self.snapshots = snapshots
        let rows = selection.value.days.sorted { $0.dayKey < $1.dayKey }.map(AllocationDayDraft.init)
        _rows = State(initialValue: rows)
        _initialRows = State(initialValue: rows)
        let start = DailyPlayActivity.date(fromDayKey: selection.value.startDayKey) ?? .now
        let end = DailyPlayActivity.date(fromDayKey: selection.value.endDayKey) ?? .now
        _rangeStart = State(initialValue: max(start, Calendar.current.date(byAdding: .day, value: -2, to: end) ?? start))
        _rangeEnd = State(initialValue: end)
    }

    private var dateBounds: ClosedRange<Date> {
        let start = DailyPlayActivity.date(fromDayKey: selection.value.startDayKey) ?? .now
        let end = DailyPlayActivity.date(fromDayKey: selection.value.endDayKey) ?? start
        return start...max(start, end)
    }
    private var total: Int { rows.compactMap(\.value).reduce(0) { $0 + $1.minutes } }
    private var hasChanges: Bool { rows != initialRows }
    private var draft: PlayTimeAllocationValue {
        var value = selection.value
        value.days = rows.compactMap(\.value)
        value.isDeleted = false
        return value
    }
    private var validationMessage: String? {
        guard rows.allSatisfy({ $0.value != nil }) else { return "每天需填写 1 分钟到 24 小时，分钟填写 0—59。" }
        do { _ = try PlayTimeResolver.coveredIDs(draft, snapshots: snapshots); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("本次新增", value: allocationDuration(selection.value.totalMinutes))
                    LabeledContent("已分配", value: allocationDuration(total))
                    if total < selection.value.totalMinutes {
                        LabeledContent("还需分配", value: allocationDuration(selection.value.totalMinutes - total))
                            .foregroundStyle(YJColor.playStation)
                    } else if total > selection.value.totalMinutes {
                        Text("多分配了 \(allocationDuration(total - selection.value.totalMinutes))")
                            .foregroundStyle(YJColor.coral)
                    }
                } footer: {
                    Text("可分配 \(selection.value.startDayKey) 至 \(selection.value.endDayKey) 的日期，合计保持不变。奖杯仍按原记录日期显示。")
                }
                Section("每日时长") {
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 10) {
                            dayPicker("游玩日期", selection: Binding(
                                get: { DailyPlayActivity.date(fromDayKey: row.dayKey) ?? dateBounds.upperBound },
                                set: { row.dayKey = DailyPlayActivity.dayKey(for: $0) }
                            ))
                            inputLayout {
                                HStack {
                                    TextField("0", text: $row.hours).keyboardType(.numberPad)
                                        .focused($editingNumber).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("\(row.dayKey) 小时")
                                    Text("小时").font(.subheadline).fixedSize()
                                }
                                HStack {
                                    TextField("0", text: $row.minutes).keyboardType(.numberPad)
                                        .focused($editingNumber).textFieldStyle(.roundedBorder)
                                        .accessibilityLabel("\(row.dayKey) 分钟")
                                    Text("分钟").font(.subheadline).fixedSize()
                                }
                                Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle")
                                }.buttonStyle(.borderless).accessibilityLabel("移除 \(row.dayKey)")
                            }
                        }.padding(.vertical, 5)
                    }
                    Button("添加日期", systemImage: "plus") { addDay() }
                        .disabled(rows.count >= 3_660)
                }
                Section {
                    DisclosureGroup("按日期均分") {
                        dayPicker("开始日期", selection: $rangeStart)
                        dayPicker("结束日期", selection: $rangeEnd)
                        Button("均分这段时长") { distributeEvenly() }
                            .disabled(rangeStart > rangeEnd)
                    }
                } footer: {
                    if let validationMessage { Text(validationMessage).foregroundStyle(YJColor.coral) }
                }
                if selection.canReset {
                    Section {
                        Button("恢复原来的日期分布", role: .destructive) { confirmingReset = true }
                    } footer: {
                        Text("恢复后，这段新增时长重新显示在原来的记录日期。")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(YJBackground())
            .navigationTitle("分配游玩日期").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { persist(draft) }.disabled(validationMessage != nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成输入") { editingNumber = false }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("恢复原来的日期分布？", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("恢复原分布", role: .destructive) {
                    var value = selection.value
                    value.days = []
                    value.isDeleted = true
                    persist(value)
                }
            } message: { Text("仅撤销这一段的日期分配，原始时长和其他记录不变。") }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
            }
            .alert("暂时无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(errorMessage ?? "请稍后重试") }
        }
        .tint(YJColor.playStation)
    }

    private var inputLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 8))
    }

    private func dayPicker(_ title: String, selection: Binding<Date>) -> some View {
        LabeledContent {
            DatePicker(title, selection: selection, in: dateBounds, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.compact)
                // UIKit's compact date button cannot wrap at accessibility sizes.
                // Keep its control usable while the separate label scales normally.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        } label: { Text(title) }
    }

    private func addDay() {
        var day = dateBounds.upperBound
        let used = Set(rows.map(\.dayKey))
        while day >= dateBounds.lowerBound {
            let key = DailyPlayActivity.dayKey(for: day)
            if !used.contains(key) {
                rows.append(AllocationDayDraft(AllocatedPlayDay(dayKey: key,
                    minutes: min(1_440, max(0, selection.value.totalMinutes - total)))))
                return
            }
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        errorMessage = "这段范围内的日期都已添加，可以直接修改现有时长。"
    }

    private func distributeEvenly() {
        let count = (Calendar.current.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? -1) + 1
        let minutes = selection.value.totalMinutes
        guard (1...3_660).contains(count), minutes >= count, minutes <= count * 1_440 else {
            errorMessage = "请选择合适的日期范围，让每天至少 1 分钟、最多 24 小时。"
            return
        }
        rows = (0..<count).compactMap { index in
            guard let day = Calendar.current.date(byAdding: .day, value: index, to: rangeStart) else { return nil }
            return AllocationDayDraft(AllocatedPlayDay(dayKey: DailyPlayActivity.dayKey(for: day),
                minutes: minutes / count + (index < minutes % count ? 1 : 0)))
        }
    }

    private func persist(_ value: PlayTimeAllocationValue) {
        editingNumber = false
        do {
            try PlayTimeAllocationService.save(value, expectedUpdatedAt: selection.expectedUpdatedAt,
                revision: revision, modelContext: modelContext)
            dismiss()
        } catch is CancellationError { errorMessage = PlayTimeAllocationError.changed.localizedDescription }
        catch { errorMessage = error.localizedDescription }
    }
}

private func allocationDuration(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) 小时\(minutes % 60 == 0 ? "" : " \(minutes % 60) 分钟")" : "\(minutes) 分钟"
}
