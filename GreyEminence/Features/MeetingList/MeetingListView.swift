import SwiftUI
import SwiftData

enum MeetingListGroupBy: String, CaseIterable, Identifiable {
    case date = "Date"
    case series = "Series"
    case related = "Related"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .date: "calendar"
        case .series: "arrow.triangle.2.circlepath"
        case .related: "rectangle.3.group"
        }
    }

    var help: String {
        switch self {
        case .date:
            "Group by when the meeting happened (Today, This Month, July 2026…)"
        case .series:
            "Group each recurring series or same-named meeting together, newest first"
        case .related:
            "Group related names together (for example every Exec series meeting), newest first"
        }
    }
}

/// Recent Meetings vs Archive. Archive is the full library (for extract).
/// The Meetings sidebar loads the last two weeks of unfiled library meetings
/// in SwiftData; Find, Archive, and “Show last 90 days” / “Show all meetings”
/// open older sessions when asked.
enum MeetingLibrary {
    static let recentDays = 14
    static let extendedDays = 90

    enum Horizon: String, Equatable {
        case recent
        case extended
        case allUnarchived

        func cutoff(now: Date = .now, calendar: Calendar = .current) -> Date {
            let startOfToday = calendar.startOfDay(for: now)
            switch self {
            case .recent:
                return calendar.date(byAdding: .day, value: -MeetingLibrary.recentDays, to: startOfToday)
                    ?? .distantPast
            case .extended:
                return calendar.date(byAdding: .day, value: -MeetingLibrary.extendedDays, to: startOfToday)
                    ?? .distantPast
            case .allUnarchived:
                return .distantPast
            }
        }

        var next: Horizon? {
            switch self {
            case .recent: return .extended
            case .extended: return .allUnarchived
            case .allUnarchived: return nil
            }
        }

        /// Label for the control that expands this horizon.
        var loadOlderTitle: String {
            switch self {
            case .recent: return "Show last 90 days"
            case .extended: return "Show all meetings"
            case .allUnarchived: return "Show all meetings"
            }
        }

        var emptyTitle: String {
            switch self {
            case .recent: return "No meetings in the last two weeks"
            case .extended: return "No meetings in the last 90 days"
            case .allUnarchived: return "No Meetings Yet"
            }
        }

        var emptyDescription: String {
            switch self {
            case .recent, .extended:
                return "Find (⇧⌘F) and Archive still open older sessions."
            case .allUnarchived:
                return "Start a recording to create your first meeting"
            }
        }
    }

    static func recentCutoff(now: Date = .now, calendar: Calendar = .current) -> Date {
        Horizon.recent.cutoff(now: now, calendar: calendar)
    }

    static func listPredicate(cutoff: Date, alsoIncluding pinnedID: UUID? = nil) -> Predicate<Meeting> {
        if let pinnedID {
            return #Predicate<Meeting> { meeting in
                meeting.isInterviewMeeting == false && (
                    meeting.id == pinnedID
                    || (meeting.date >= cutoff && meeting.isArchived == false)
                )
            }
        }
        return #Predicate<Meeting> { meeting in
            meeting.date >= cutoff
                && meeting.isArchived == false
                && meeting.isInterviewMeeting == false
        }
    }

    static func isLibrary(_ meeting: Meeting) -> Bool {
        !meeting.isInterviewMeeting
    }

    static func isOnMeetingsList(_ meeting: Meeting, cutoff: Date) -> Bool {
        isLibrary(meeting) && !meeting.isArchived && meeting.date >= cutoff
    }

    @MainActor
    static func setArchived(
        _ meetings: [Meeting],
        _ archived: Bool,
        in context: ModelContext
    ) {
        let targets = meetings.filter { isLibrary($0) }
        guard !targets.isEmpty else { return }
        for meeting in targets {
            meeting.isArchived = archived
        }
        PersistenceGate.save(
            context,
            site: archived ? "MeetingLibrary.archive" : "MeetingLibrary.unarchive",
            meetingID: targets.first?.id
        )
    }
}

struct MeetingListView: View {
    @Binding var selectedMeeting: Meeting?
    @Binding var selectedMeetingIDs: Set<UUID>
    var onShowArchive: (() -> Void)?
    var onExtract: (ArchiveExtractLaunch) -> Void
    @State private var horizon: MeetingLibrary.Horizon = .recent

    /// Kept for tests that still call through the view.
    static func groupSections(
        for meetings: [Meeting],
        now: Date,
        calendar: Calendar = .current
    ) -> [(String, [Meeting])] {
        MeetingListGrouping.dateSections(for: meetings, now: now, calendar: calendar)
    }

    var body: some View {
        MeetingListBody(
            horizon: horizon,
            pinnedID: pinnedID,
            selectedMeeting: $selectedMeeting,
            selectedMeetingIDs: $selectedMeetingIDs,
            onShowArchive: onShowArchive,
            onExtract: onExtract,
            onChangeHorizon: { horizon = $0 }
        )
        .id(listIdentity)
        .navigationTitle("Meetings")
    }

    /// Pin a meeting opened from Find/Archive so it stays on the list without
    /// loading the rest of the library. Selection inside the window does not
    /// change Query identity.
    private var pinnedID: UUID? {
        guard let meeting = selectedMeeting, MeetingLibrary.isLibrary(meeting) else { return nil }
        if MeetingLibrary.isOnMeetingsList(meeting, cutoff: horizon.cutoff()) { return nil }
        return meeting.id
    }

    private var listIdentity: String {
        "\(horizon.rawValue)|\(pinnedID?.uuidString ?? "")"
    }
}

private struct MeetingListBody: View {
    let horizon: MeetingLibrary.Horizon
    @Binding var selectedMeeting: Meeting?
    @Binding var selectedMeetingIDs: Set<UUID>
    var onShowArchive: (() -> Void)?
    var onExtract: (ArchiveExtractLaunch) -> Void
    var onChangeHorizon: (MeetingLibrary.Horizon) -> Void

    @Environment(\.modelContext) private var modelContext
    @Query private var meetings: [Meeting]
    @AppStorage("meetingListGroupBy") private var groupByRaw = MeetingListGroupBy.date.rawValue
    @State private var renamingMeetingID: UUID?

    init(
        horizon: MeetingLibrary.Horizon,
        pinnedID: UUID?,
        selectedMeeting: Binding<Meeting?>,
        selectedMeetingIDs: Binding<Set<UUID>>,
        onShowArchive: (() -> Void)?,
        onExtract: @escaping (ArchiveExtractLaunch) -> Void,
        onChangeHorizon: @escaping (MeetingLibrary.Horizon) -> Void
    ) {
        self.horizon = horizon
        self._selectedMeeting = selectedMeeting
        self._selectedMeetingIDs = selectedMeetingIDs
        self.onShowArchive = onShowArchive
        self.onExtract = onExtract
        self.onChangeHorizon = onChangeHorizon
        let cutoff = horizon.cutoff()
        _meetings = Query(
            filter: MeetingLibrary.listPredicate(cutoff: cutoff, alsoIncluding: pinnedID),
            sort: \Meeting.date,
            order: .reverse
        )
    }

    private var groupBy: MeetingListGroupBy {
        MeetingListGroupBy(rawValue: groupByRaw) ?? .date
    }

    private var groupedMeetings: [(String, [Meeting])] {
        MeetingListGrouping.sections(for: meetings, groupBy: groupBy, now: .now)
    }

    private func deleteMeeting(_ meeting: Meeting) {
        selectedMeetingIDs.remove(meeting.id)
        MeetingDeletion.delete(meeting, in: modelContext)
    }

    private func archiveMeetings(_ targets: [Meeting]) {
        let ids = Set(targets.map(\.id))
        MeetingLibrary.setArchived(targets, true, in: modelContext)
        selectedMeetingIDs.subtract(ids)
        if let selectedMeeting, ids.contains(selectedMeeting.id) {
            self.selectedMeeting = nil
        }
    }

    private func makeLaunch(
        scope: ArchiveExtractScope,
        meeting: Meeting?,
        group: [Meeting] = [],
        seriesLabel: String? = nil
    ) -> ArchiveExtractLaunch {
        ArchiveExtractLaunch(
            initialScope: scope,
            seriesLabel: seriesLabel,
            seedMeetingID: meeting?.id,
            selectedIDs: selectedMeetingIDs,
            visibleIDs: Set(meetings.map(\.id)),
            groupMeetingIDs: Set(group.map(\.id))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            groupPickerBar
            Divider()
            meetingList
        }
    }

    private var groupPickerBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(MeetingListGroupBy.allCases) { option in
                    Button {
                        groupByRaw = option.rawValue
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            if groupBy == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Group: \(groupBy.rawValue)", systemImage: groupBy.systemImage)
            }
            .help(groupBy.help)
            Spacer(minLength: 0)
            Button {
                onExtract(makeLaunch(
                    scope: selectedMeetingIDs.isEmpty ? .allVisible : .selected,
                    meeting: selectedMeeting
                ))
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .help("Export transcripts and intel as a zip or PDF for the selected meetings, a series, or everything currently listed.")
            .disabled(meetings.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
    }

    private var meetingList: some View {
        List(selection: $selectedMeetingIDs) {
            ForEach(groupedMeetings, id: \.0) { section, sectionMeetings in
                Section {
                    ForEach(sectionMeetings) { meeting in
                        MeetingRowView(meeting: meeting, renamingID: $renamingMeetingID)
                            .tag(meeting.id)
                            .contextMenu {
                                Button("Rename") {
                                    renamingMeetingID = meeting.id
                                }
                                MeetingExtractContextButtons(
                                    meeting: meeting,
                                    selectedIDs: selectedMeetingIDs,
                                    visibleIDs: Set(meetings.map(\.id)),
                                    library: meetings,
                                    onExtract: onExtract
                                )
                                Button {
                                    let targets = selectedMeetingIDs.count > 1
                                        ? meetings.filter { selectedMeetingIDs.contains($0.id) }
                                        : [meeting]
                                    archiveMeetings(targets)
                                } label: {
                                    if selectedMeetingIDs.count > 1, selectedMeetingIDs.contains(meeting.id) {
                                        Label("Archive Selected (\(selectedMeetingIDs.count))", systemImage: "archivebox")
                                    } else {
                                        Label("Archive Meeting", systemImage: "archivebox")
                                    }
                                }
                                Divider()
                                MeetingReanalyzeContextButtons(
                                    meeting: meeting,
                                    selectedIDs: selectedMeetingIDs
                                )
                                Divider()
                                Button(role: .destructive) {
                                    deleteMeeting(meeting)
                                } label: {
                                    Label("Delete Meeting", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            deleteMeeting(sectionMeetings[index])
                        }
                    }
                } header: {
                    Text(groupBy == .date ? section : "\(section) (\(sectionMeetings.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .contextMenu {
                            Button {
                                let scope: ArchiveExtractScope = (groupBy == .date) ? .thisGroup : .thisSeries
                                onExtract(makeLaunch(
                                    scope: scope,
                                    meeting: sectionMeetings.first,
                                    group: sectionMeetings,
                                    seriesLabel: section
                                ))
                            } label: {
                                Label("Export \(section)…", systemImage: "square.and.arrow.up")
                            }
                        }
                }
            }

            Section {
                if let next = horizon.next {
                    Button {
                        onChangeHorizon(next)
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(horizon.loadOlderTitle)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("The list loads the last two weeks until you ask for more. Find (⇧⌘F) also opens older sessions.")
                }
                if let onShowArchive {
                    Button {
                        onShowArchive()
                    } label: {
                        HStack {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                            Text("View archive")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Every meeting lives in Archive for extract. File any meeting away from this list. Find (⇧⌘F) searches the whole library.")
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selectedMeetingIDs) { oldIDs, newIDs in
            let next = MeetingListSelection.detailMeeting(
                previousIDs: oldIDs,
                newIDs: newIDs,
                current: selectedMeeting,
                from: meetings
            )
            if selectedMeeting?.id != next?.id {
                selectedMeeting = next
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MeetingSelectionBar(
                selectedIDs: selectedMeetingIDs,
                onExtract: {
                    onExtract(makeLaunch(scope: .selected, meeting: selectedMeeting))
                },
                onArchive: {
                    archiveMeetings(meetings.filter { selectedMeetingIDs.contains($0.id) })
                }
            )
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView {
                    Label(horizon.emptyTitle, systemImage: "waveform")
                } description: {
                    Text(horizon.emptyDescription)
                } actions: {
                    if let next = horizon.next {
                        Button(horizon.loadOlderTitle) { onChangeHorizon(next) }
                    }
                    if let onShowArchive {
                        Button("View archive", action: onShowArchive)
                    }
                }
            }
        }
    }
}

enum MeetingListGrouping {
    static func sections(
        for meetings: [Meeting],
        groupBy: MeetingListGroupBy,
        now: Date,
        calendar: Calendar = .current
    ) -> [(String, [Meeting])] {
        switch groupBy {
        case .date:
            return dateSections(for: meetings, now: now, calendar: calendar)
        case .series:
            return namedSections(for: meetings, related: false)
        case .related:
            return namedSections(for: meetings, related: true)
        }
    }

    /// Buckets meetings into the relative sections ("Today"…"This Month") and
    /// then one section per calendar month. `now` is injected so the bucketing
    /// is testable without depending on the wall clock.
    static func dateSections(
        for meetings: [Meeting],
        now: Date,
        calendar: Calendar = .current
    ) -> [(String, [Meeting])] {
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        monthFormatter.timeZone = calendar.timeZone

        let grouped = Dictionary(grouping: meetings) { meeting -> String in
            if calendar.isDate(meeting.date, inSameDayAs: now) {
                return "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(meeting.date, inSameDayAs: yesterday) {
                return "Yesterday"
            } else if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now),
                      weekInterval.contains(meeting.date) {
                return "This Week"
            } else if let monthInterval = calendar.dateInterval(of: .month, for: now),
                      monthInterval.contains(meeting.date) {
                return "This Month"
            } else {
                return monthFormatter.string(from: meeting.date)
            }
        }
        let order = ["Today", "Yesterday", "This Week", "This Month"]
        return grouped
            .map { key, values in (key, values.sorted { $0.date > $1.date }) }
            .sorted { a, b in
                let aIdx = order.firstIndex(of: a.0) ?? Int.max
                let bIdx = order.firstIndex(of: b.0) ?? Int.max
                if aIdx != bIdx { return aIdx < bIdx }
                let aDate = a.1.first?.date ?? .distantPast
                let bDate = b.1.first?.date ?? .distantPast
                return aDate > bDate
            }
    }

    /// Series: same calendar series, calendar event, or exact title.
    /// Related: if two or more meetings share the first two words
    /// ("Weekly Standup" + "Exec series Priorities…"), they share that bucket.
    static func namedSections(
        for meetings: [Meeting],
        related: Bool
    ) -> [(String, [Meeting])] {
        let labels = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, displayLabel(for: $0)) })
        var familyKey: [UUID: String] = [:]
        if related {
            let prefixCounts = Dictionary(grouping: meetings) {
                leadingPhrase(labels[$0.id] ?? "", wordCount: 2).lowercased()
            }.mapValues(\.count)
            for meeting in meetings {
                let label = labels[meeting.id] ?? meeting.title
                let prefix = leadingPhrase(label, wordCount: 2)
                let key = prefix.lowercased()
                if prefix.split(whereSeparator: \.isWhitespace).count >= 2,
                   (prefixCounts[key] ?? 0) >= 2 {
                    familyKey[meeting.id] = prefix
                } else {
                    familyKey[meeting.id] = label
                }
            }
        } else {
            for meeting in meetings {
                familyKey[meeting.id] = labels[meeting.id] ?? meeting.title
            }
        }

        let grouped = Dictionary(grouping: meetings) { meeting in
            familyKey[meeting.id] ?? displayLabel(for: meeting)
        }
        return grouped
            .map { key, values in (key, values.sorted { $0.date > $1.date }) }
            .sorted { a, b in
                let aDate = a.1.first?.date ?? .distantPast
                let bDate = b.1.first?.date ?? .distantPast
                if aDate != bDate { return aDate > bDate }
                return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending
            }
    }

    static func displayLabel(for meeting: Meeting) -> String {
        let series = meeting.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !series.isEmpty { return series }
        let calendar = meeting.calendarEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !calendar.isEmpty { return calendar }
        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled" : title
    }

    static func leadingPhrase(_ text: String, wordCount: Int) -> String {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { return text }
        return words.prefix(max(wordCount, 1)).joined(separator: " ")
    }
}

enum MeetingListSelection {
    @MainActor
    static func detailMeeting(
        previousIDs: Set<UUID>,
        newIDs: Set<UUID>,
        current: Meeting?,
        from meetings: [Meeting]
    ) -> Meeting? {
        if newIDs.isEmpty { return nil }
        if let added = newIDs.subtracting(previousIDs).first,
           let meeting = meetings.first(where: { $0.id == added }) {
            return meeting
        }
        if let current, newIDs.contains(current.id) { return current }
        return meetings.first(where: { newIDs.contains($0.id) })
    }
}

struct MeetingReanalyzeContextButtons: View {
    let meeting: Meeting
    let selectedIDs: Set<UUID>
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Button {
            MeetingReanalysisQueue.shared.enqueueEligible(
                in: modelContext,
                restrictingTo: [meeting.id]
            )
        } label: {
            Label("Reanalyze Meeting", systemImage: "arrow.clockwise")
        }
        .disabled(meeting.status == .recording || meeting.segments.isEmpty)

        if selectedIDs.count > 1 {
            Button {
                MeetingReanalysisQueue.shared.enqueueEligible(
                    in: modelContext,
                    restrictingTo: selectedIDs
                )
            } label: {
                Label("Reanalyze Selected (\(selectedIDs.count))", systemImage: "arrow.clockwise")
            }
        }
    }
}

struct MeetingExtractContextButtons: View {
    let meeting: Meeting
    let selectedIDs: Set<UUID>
    let visibleIDs: Set<UUID>
    let library: [Meeting]
    var onExtract: (ArchiveExtractLaunch) -> Void

    private var series: [Meeting] {
        DossierFacts.relatedMeetings(to: meeting, library: library)
    }

    var body: some View {
        Button {
            onExtract(launch(scope: .thisMeeting, seed: meeting))
        } label: {
            Label("Export This Meeting…", systemImage: "square.and.arrow.up")
        }

        if series.count > 1 {
            Button {
                onExtract(launch(
                    scope: .thisSeries,
                    seed: meeting,
                    groupIDs: Set(series.map(\.id)),
                    seriesLabel: MeetingListGrouping.displayLabel(for: meeting)
                ))
            } label: {
                Label("Export \(MeetingListGrouping.displayLabel(for: meeting)) (\(series.count))…", systemImage: "square.and.arrow.up.on.square")
            }
        }

        if selectedIDs.count > 1 {
            Button {
                onExtract(launch(scope: .selected, seed: meeting))
            } label: {
                Label("Export Selected (\(selectedIDs.count))…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func launch(
        scope: ArchiveExtractScope,
        seed: Meeting,
        groupIDs: Set<UUID> = [],
        seriesLabel: String? = nil
    ) -> ArchiveExtractLaunch {
        ArchiveExtractLaunch(
            initialScope: scope,
            seriesLabel: seriesLabel,
            seedMeetingID: seed.id,
            selectedIDs: selectedIDs,
            visibleIDs: visibleIDs,
            groupMeetingIDs: groupIDs
        )
    }
}

struct MeetingSelectionBar: View {
    let selectedIDs: Set<UUID>
    var onExtract: (() -> Void)? = nil
    var onArchive: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if selectedIDs.count > 1 {
            HStack(spacing: 8) {
                Text("\(selectedIDs.count) selected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let onExtract {
                    Button("Export…") { onExtract() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if let onArchive {
                    Button("Archive") { onArchive() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Reanalyze") {
                    MeetingReanalysisQueue.shared.enqueueEligible(
                        in: modelContext,
                        restrictingTo: selectedIDs
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
