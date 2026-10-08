import Foundation
import SwiftData

/// Gate for work that can wait until the UI and a live recording are idle.
enum BackgroundIdleWork {
    static var resourcesAreFree: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return false }
        switch info.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    static func waitUntilIdle(isBusy: @escaping @MainActor () -> Bool) async {
        while !Task.isCancelled {
            let busy = await MainActor.run { isBusy() }
            if !busy && resourcesAreFree { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}

/// Read-only projection of the meeting library for Grok (Secretary).
/// SwiftData stays canonical. This writes markdown + `index.json` under
/// Application Support so a local MCP can search the full archive.
///
/// Launch heal is offline: a background context, skipped when the file
/// already exists, paused while recording or the machine is thermally
/// constrained. A finished meeting still upserts that one record live.
enum GrokLibrary {
    static let folderName = "grok-library"

    static var defaultRoot: URL {
        StorageManager.shared.appSupportURL.appendingPathComponent(folderName, isDirectory: true)
    }

    struct Action: Codable, Equatable, Sendable {
        var text: String
        var assignee: String?
        var isCompleted: Bool
        var sourceQuote: String?
    }

    struct Record: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var date: String
        var duration: String
        var series: String?
        var speakers: [String]
        var attendees: [String]
        var purpose: String?
        var hasTranscript: Bool
        var hasIntel: Bool
        var actionCount: Int
        var openActionCount: Int
        var path: String
        var actions: [Action]
    }

    struct Index: Codable, Equatable, Sendable {
        var generatedAt: String
        var bundleID: String
        var meetingCount: Int
        var meetings: [Record]
    }

    static func scheduleAtLaunch(
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool = { false },
        delaySeconds: UInt64 = 10
    ) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
            await syncAll(container: container)
        }
    }

    static func upsert(_ meeting: Meeting, into root: URL = defaultRoot) {
        guard !meeting.isInterviewMeeting else { return }
        let snap = DossierFacts.snapshot(meeting: meeting)
        writeSnapshot(snap, series: meeting.seriesTitle, into: root)
        refreshIndex(into: root)
    }

    @discardableResult
    static func syncAll(container: ModelContainer, into root: URL = defaultRoot) async -> (written: Int, reused: Int) {
        await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return await syncAll(from: context, into: root)
        }.value
    }

    /// Walk the store on whatever context the caller owns. Meetings that
    /// already have `meta.json` keep their transcript files; only title /
    /// date / duration / series are patched. New or missing folders get a
    /// full snapshot.
    @discardableResult
    static func syncAll(from context: ModelContext, into root: URL = defaultRoot) async -> (written: Int, reused: Int) {
        let meetings = ((try? context.fetch(FetchDescriptor<Meeting>())) ?? [])
            .filter { !$0.isInterviewMeeting }
            .sorted { $0.date > $1.date }
        let existing = loadExistingRecords(from: root)
        var keep: Set<String> = []
        var records: [Record] = []
        var written = 0
        var reused = 0
        for meeting in meetings {
            let id = meeting.id.uuidString
            if let current = existing[id], hasMeta(id: id, in: root) {
                var record = current
                record.title = meeting.title
                record.date = isoDate(meeting.date)
                record.duration = meeting.formattedDuration
                record.series = emptyToNil(meeting.seriesTitle)
                writeMeta(record, into: root)
                keep.insert(id)
                records.append(record)
                reused += 1
                continue
            }
            let snap = DossierFacts.snapshot(meeting: meeting)
            let record = writeSnapshot(snap, series: meeting.seriesTitle, into: root)
            keep.insert(record.id)
            records.append(record)
            written += 1
            await Task.yield()
        }
        prune(keeping: keep, into: root)
        writeIndex(records, into: root)
        LogManager.send(
            "Grok library: \(records.count) meeting(s), \(written) written, \(reused) reused",
            category: .general
        )
        return (written, reused)
    }

    @discardableResult
    static func writeSnapshot(
        _ snap: DossierMeetingSnapshot,
        series: String?,
        into root: URL
    ) -> Record {
        let folder = root.appendingPathComponent("meetings/\(snap.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let transcript = transcriptMarkdown(snap)
        let intel = intelMarkdown(snap)
        writeText(transcript, to: folder.appendingPathComponent("transcript.md"))
        writeText(intel, to: folder.appendingPathComponent("intel.md"))

        let record = Record(
            id: snap.id.uuidString,
            title: snap.title,
            date: isoDate(snap.date),
            duration: snap.durationLabel,
            series: emptyToNil(series),
            speakers: snap.speakers,
            attendees: snap.attendees,
            purpose: DossierFacts.purpose(from: snap),
            hasTranscript: !snap.transcript.isEmpty,
            hasIntel: !intel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            actionCount: snap.actionItems.count,
            openActionCount: snap.actionItems.filter { !$0.isCompleted }.count,
            path: "meetings/\(snap.id.uuidString)",
            actions: snap.actionItems.map {
                Action(
                    text: $0.text,
                    assignee: $0.assignee,
                    isCompleted: $0.isCompleted,
                    sourceQuote: $0.sourceQuote
                )
            }
        )
        writeMeta(record, into: root)
        return record
    }

    static func writeIndex(_ records: [Record], into root: URL) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = Index(
            generatedAt: isoDate(Date()),
            bundleID: AppIdentity.greyConseilBundleID,
            meetingCount: records.count,
            meetings: records
        )
        guard let data = try? makeEncoder().encode(index) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }

    static func loadExistingRecords(from root: URL) -> [String: Record] {
        let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: nil
        ) else { return [:] }
        var records: [String: Record] = [:]
        for folder in folders where folder.hasDirectoryPath {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            records[record.id] = record
        }
        return records
    }

    private static func hasMeta(id: String, in root: URL) -> Bool {
        let meta = root
            .appendingPathComponent("meetings/\(id)", isDirectory: true)
            .appendingPathComponent("meta.json")
        return FileManager.default.fileExists(atPath: meta.path)
    }

    private static func writeMeta(_ record: Record, into root: URL) {
        let folder = root.appendingPathComponent("meetings/\(record.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? makeEncoder().encode(record) else { return }
        try? data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
    }

    private static func refreshIndex(into root: URL) {
        let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        var records: [Record] = []
        for folder in folders where folder.hasDirectoryPath {
            let metaURL = folder.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { continue }
            records.append(record)
        }
        records.sort { $0.date > $1.date }
        writeIndex(records, into: root)
    }

    private static func prune(keeping ids: Set<String>, into root: URL) {
        let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: meetingsRoot,
            includingPropertiesForKeys: nil
        ) else { return }
        for folder in folders where folder.hasDirectoryPath {
            if !ids.contains(folder.lastPathComponent) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static func transcriptMarkdown(_ snap: DossierMeetingSnapshot) -> String {
        TranscriptExportService.markdown(
            title: snap.title,
            date: snap.date,
            durationLabel: snap.durationLabel,
            lines: snap.transcript.map {
                TranscriptExportLine(timestamp: $0.timestamp, speaker: $0.speaker, text: $0.text)
            }
        )
    }

    private static func intelMarkdown(_ snap: DossierMeetingSnapshot) -> String {
        DossierRenderer.markdown(
            DossierRenderer.blocks(
                snapshots: [snap],
                audience: .general,
                depth: .detailed,
                includeTranscript: false
            )
        )
    }

    private static func writeText(_ text: String, to url: URL) {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func emptyToNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
