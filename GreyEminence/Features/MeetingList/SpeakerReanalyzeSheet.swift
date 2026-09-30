import SwiftData
import SwiftUI

enum MashupAttachDirection: Sendable {
    case previous
    case next
}

/// Pick who was actually on the call, re-analyze from saved audio using
/// their voice stamps, then assign leftover Talk-over and speaker-N snippets.
struct SpeakerReanalyzeSheet: View {
    let meeting: Meeting
    let contacts: [Contact]
    var isWorking: Bool
    var result: MeetingSpeakerRecovery.Result?
    var onRun: ([MeetingSpeakerRecovery.ExpectedSpeaker]) -> Void
    var onAssign: ([UUID], Speaker, Contact?) -> Void
    var onAttach: ((UUID, MashupAttachDirection) -> Void)?
    var onDismiss: () -> Void

    @State private var selectedIDs: Set<String> = []
    @State private var unknownSelected: Set<UUID> = []
    @State private var typedName = ""
    @State private var showContactPicker = false
    @State private var didSeedSelection = false

    private var candidates: [MeetingSpeakerRecovery.ExpectedSpeaker] {
        MeetingSpeakerRecovery.candidates(meeting: meeting, contacts: contacts)
    }

    private var selectedPeople: [MeetingSpeakerRecovery.ExpectedSpeaker] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    private var unknownSnippets: [TranscriptSegment] {
        guard let result else { return [] }
        let keys = Set(result.unknownSpeakers.map(\.identityKey))
        return meeting.segments
            .sorted { $0.startTime < $1.startTime }
            .filter { keys.contains($0.speaker.identityKey) }
    }

    private var sortedMeetingSegments: [TranscriptSegment] {
        meeting.segments.sorted { $0.startTime < $1.startTime }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if result == nil {
                        peopleSection
                    } else {
                        resultSection
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 620)
        .onAppear {
            guard !didSeedSelection else { return }
            didSeedSelection = true
            selectedIDs = Set(candidates.filter(\.isPreselected).map(\.id))
        }
        .popover(isPresented: $showContactPicker) {
            ContactPicker(
                excludedContacts: [],
                prioritizedContacts: meeting.attendees,
                includeAppleDirectory: true
            ) { contact in
                assignSelectedSnippets(to: .other(contact.name), contact: contact)
                showContactPicker = false
            }
            .frame(width: 280, height: 320)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Re-analyze speakers")
                .font(.headline)
            Text(result == nil
                 ? "Pick who was actually on this call. If a remote voice was stamped as you, use Set as / Speakers to name them, then Save voice print from this meeting, then re-analyze. Every stamp in each person’s collection is used, including room/mic character when that box was on. Overlapping talk lands on Talk-over instead of a third person. Lines currently labeled as you are re-checked."
                 : "Every unmatched snippet is listed. Play it, assign it (Me is first), or append it onto the previous or next line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("People on this call")
                .font(.subheadline.weight(.semibold))
            ForEach(candidates) { person in
                Toggle(isOn: binding(for: person)) {
                    HStack(spacing: 8) {
                        Text(person.name)
                        if person.isMe {
                            Text("you")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if person.hasVoicePrint {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help("Voice stamp on file")
                        } else {
                            Text("no stamp")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .disabled(person.isMe || isWorking)
            }
            Text("A waveform means this person already has a voice stamp. Unchecked people are not used as matches, so leftover clusters stay Talk-over or speaker-N instead of being named as someone who was not on the call.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result {
                Text(result.changed == 0
                     ? "Audio did not change any remote labels."
                     : "Relabeled \(result.changed) remote line\(result.changed == 1 ? "" : "s").")
                    .font(.subheadline)
                if !result.matchedSpeakers.isEmpty {
                    Text("Matched: \(result.matchedSpeakers.map(\.displayName).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if unknownSnippets.isEmpty {
                Label("No unmatched voices. Every remote cluster matched a selected voice stamp.", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Unmatched voices")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(unknownSelected.count == unknownSnippets.count ? "Clear" : "Select all") {
                        if unknownSelected.count == unknownSnippets.count {
                            unknownSelected = []
                        } else {
                            unknownSelected = Set(unknownSnippets.map(\.id))
                        }
                    }
                    .controlSize(.small)
                }
                ForEach(unknownSnippets, id: \.id) { snippet in
                    unmatchedRow(snippet)
                }

                Text("Assign selected to")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)

                FlowLayout(spacing: 6, rowAlignment: .center) {
                    Button("Me") {
                        assignSelectedSnippets(to: Speaker.resolvedMe(), contact: nil)
                    }
                    .controlSize(.small)
                    .disabled(unknownSelected.isEmpty)
                    .help("This snippet is you (the local microphone).")

                    ForEach(selectedPeople.filter { !$0.isMe }) { person in
                        Button(person.name) {
                            assignSelectedSnippets(to: person.speaker, contact: contact(for: person))
                        }
                        .controlSize(.small)
                        .disabled(unknownSelected.isEmpty)
                    }
                }

                HStack {
                    Button("Choose contact…") {
                        showContactPicker = true
                    }
                    .controlSize(.small)
                    .disabled(unknownSelected.isEmpty)

                    TextField("Or type a name", text: $typedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { assignTypedName() }

                    Button("Name") {
                        assignTypedName()
                    }
                    .controlSize(.small)
                    .disabled(unknownSelected.isEmpty || typedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if result == nil {
                Button {
                    onRun(selectedPeople)
                } label: {
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Re-analyze from audio")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking || selectedPeople.isEmpty)
            }
        }
        .padding(16)
    }

    private func binding(for person: MeetingSpeakerRecovery.ExpectedSpeaker) -> Binding<Bool> {
        Binding(
            get: { person.isMe || selectedIDs.contains(person.id) },
            set: { on in
                if person.isMe { return }
                if on {
                    selectedIDs.insert(person.id)
                } else {
                    selectedIDs.remove(person.id)
                }
            }
        )
    }

    @ViewBuilder
    private func unmatchedRow(_ snippet: TranscriptSegment) -> some View {
        let playing = SegmentAudioPlayer.shared.playingSegmentID == snippet.id
        HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: unknownBinding(snippet.id)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(snippet.formattedTimestamp)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Text(snippet.speaker.displayName)
                            .font(.body.weight(.semibold))
                    }
                    Text(snippet.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            VStack(spacing: 4) {
                Button {
                    playSnippet(snippet)
                } label: {
                    Image(systemName: playing ? "stop.circle.fill" : "play.circle")
                }
                .buttonStyle(.plain)
                .help(playing ? "Stop" : "Play this unmatched snippet")
                Button("← prior") {
                    onAttach?(snippet.id, .previous)
                    unknownSelected.remove(snippet.id)
                }
                .controlSize(.mini)
                .disabled(sortedMeetingSegments.first?.id == snippet.id)
                .help("Append this mashup onto the previous line and its speaker.")
                Button("next →") {
                    onAttach?(snippet.id, .next)
                    unknownSelected.remove(snippet.id)
                }
                .controlSize(.mini)
                .disabled(sortedMeetingSegments.last?.id == snippet.id)
                .help("Append this mashup onto the next line and its speaker.")
            }
        }
        .padding(.vertical, 4)
    }

    private func unknownBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { unknownSelected.contains(id) },
            set: { on in
                if on {
                    unknownSelected.insert(id)
                } else {
                    unknownSelected.remove(id)
                }
            }
        )
    }

    private func playSnippet(_ snippet: TranscriptSegment) {
        let sorted = sortedMeetingSegments
        let index = sorted.firstIndex(where: { $0.id == snippet.id })
        let nextStart = index.flatMap { idx -> TimeInterval? in
            let next = idx + 1
            return next < sorted.count ? sorted[next].startTime : nil
        }
        let previousEnd = index.flatMap { idx -> TimeInterval? in
            idx > 0 ? sorted[idx - 1].endTime : nil
        }
        SegmentAudioPlayer.shared.toggle(
            snippet,
            in: meeting,
            until: nextStart,
            previousEnd: previousEnd
        )
    }

    private func assignTypedName() {
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let contact = contacts.first { $0.matchesSpeakerName(name) }
        assignSelectedSnippets(to: .other(contact?.name ?? name), contact: contact)
        typedName = ""
    }

    private func assignSelectedSnippets(to speaker: Speaker, contact: Contact?) {
        let ids = unknownSnippets.map(\.id).filter { unknownSelected.contains($0) }
        guard !ids.isEmpty else { return }
        onAssign(ids, speaker, contact)
        unknownSelected = []
    }

    private func contact(for person: MeetingSpeakerRecovery.ExpectedSpeaker) -> Contact? {
        guard let id = person.contactID else { return nil }
        return contacts.first { $0.id == id }
    }
}
