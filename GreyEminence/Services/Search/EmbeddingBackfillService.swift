import Foundation
import SwiftData

/// Heals embedding-store gaps caused by silent skips: meetings whose
/// post-recording indexing pass was killed (crash, force quit) or that
/// predate the indexer entirely. Without this, an un-indexed meeting
/// stays invisible to Ask forever — the only existing recovery was the
/// nuclear "Reindex all" button in Settings, which re-embeds everything.
///
/// Launch scan is offline: a background context, only meetings missing
/// from the embedding store, one at a time, paused while recording or
/// the machine is thermally constrained.
@MainActor
enum EmbeddingBackfillService {
    static func scheduleAtLaunch(
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool = { false },
        delaySeconds: UInt64 = 20
    ) {
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
            await runNow(container: container, isBusy: isBusy)
        }
    }

    /// Run the scan + index now. Surfaces via TransientActivityCoordinator
    /// only when there's actual work to do, so the footer stays quiet on
    /// the common "already covered" path.
    static func runNow(
        container: ModelContainer,
        isBusy: @escaping @MainActor () -> Bool = { false }
    ) async {
        guard let store = EmbeddingStore.shared else { return }
        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider")
            ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else {
            LogManager.send(
                "EmbeddingBackfill: provider \(provider.shortLabel) unavailable, skipping",
                category: .general
            )
            return
        }
        let indexedIDs = store.indexedMeetingIDs(for: service.modelIdentifier)

        let missingIDs: [UUID] = await Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let meetings = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
            return meetings.compactMap { meeting -> UUID? in
                guard meeting.status == .completed else { return nil }
                guard meeting.reProcessingState == nil else { return nil }
                guard !indexedIDs.contains(meeting.id) else { return nil }
                return meeting.id
            }
        }.value

        guard !missingIDs.isEmpty else {
            LogManager.send(
                "EmbeddingBackfill: nothing to do — \(indexedIDs.count) meetings already indexed for \(service.modelIdentifier)",
                category: .general
            )
            return
        }

        LogManager.send(
            "EmbeddingBackfill: indexing \(missingIDs.count) un-covered meeting(s)",
            category: .general
        )
        let label = "Indexing \(missingIDs.count) meeting\(missingIDs.count == 1 ? "" : "s") for search…"
        await TransientActivityCoordinator.shared.runAsync(label) {
            let indexer = EmbeddingIndexer(store: store, service: service)
            for id in missingIDs {
                await BackgroundIdleWork.waitUntilIdle(isBusy: isBusy)
                let payload = await Task.detached(priority: .utility) {
                    EmbeddingIndexPayload.load(id: id, container: container)
                }.value
                guard let payload else { continue }
                await indexer.index(payload)
            }
        }
        LogManager.send("EmbeddingBackfill: complete", category: .general)
    }

    /// Index a single meeting on demand, used by the per-meeting "Index"
    /// button in the header bar. Returns the embedding-record count after
    /// the pass so the caller can refresh its coverage state.
    @discardableResult
    static func indexSingleMeeting(_ meeting: Meeting) async -> Int {
        guard let store = EmbeddingStore.shared else { return 0 }
        let providerRaw = UserDefaults.standard.string(forKey: "embeddingProvider")
            ?? EmbeddingProvider.nlEmbedding.rawValue
        let provider = EmbeddingProvider(rawValue: providerRaw) ?? .nlEmbedding
        let service = provider.makeService()
        guard service.isAvailable else { return store.recordCount(forMeetingID: meeting.id) }
        let indexer = EmbeddingIndexer(store: store, service: service)
        await indexer.indexMeeting(meeting)
        return store.recordCount(forMeetingID: meeting.id)
    }
}
