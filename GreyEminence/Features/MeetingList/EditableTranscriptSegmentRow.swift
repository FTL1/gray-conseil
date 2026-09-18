import SwiftUI
import SwiftData

struct EditableTranscriptSegmentRow: View {
    @Bindable var segment: TranscriptSegment
    var hasNext: Bool
    var isSelected: Bool = false
    var onDelete: (() -> Void)?
    var onMergeWithNext: (() -> Void)?
    var onSplit: ((String, String) -> Void)?
    var onSplitMeeting: (() -> Void)?
    var onChangeSpeakerForAll: ((Speaker) -> Void)?
    var onToggleSelection: (() -> Void)?
    /// When set (meeting has captured screen frames), the timestamp becomes
    /// a click target that seeks the screen-share player to this moment.
    var onSeekToTime: ((TimeInterval) -> Void)?
    var onPlayLine: (() -> Void)?
    var isPlayingLine: Bool = false
    var speakerActions: SpeakerBadgeActions = SpeakerBadgeActions()
    var highlightQuery: String = ""
    /// Click the speaker badge to show only that voice's lines.
    var onFilterSpeaker: ((Speaker) -> Void)?
    /// Play (or stop) the recorded audio behind this segment. Only offered
    /// for completed meetings whose audio is on disk to be read.
    var onPlayAudio: (() -> Void)?
    var isPlayingAudio: Bool = false
    /// Why the last play attempt for this segment failed, shown in the
    /// button's tooltip so a missing file explains itself.
    var playbackFailure: String?

    @State private var isEditingText = false
    @State private var editedText: String = ""
    @State private var showContactPicker = false
    @State private var showSpeakerRename = false
    @State private var speakerName: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Selection checkbox (visible when multi-select is active)
            if onToggleSelection != nil {
                Button {
                    onToggleSelection?()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }

            // Play the audio behind this line — the way to tell a bad
            // recording from a bad transcription of a good one.
            if let onPlayAudio {
                Button {
                    onPlayAudio()
                } label: {
                    Image(systemName: isPlayingAudio ? "stop.circle.fill" : "play.circle")
                        .font(.caption)
                        .foregroundStyle(
                            isPlayingAudio ? Color.accentColor
                                : playbackFailure != nil ? Color.orange : Color.secondary
                        )
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
                .help(playbackFailure ?? (isPlayingAudio ? "Stop" : "Play this segment's audio"))
                .contextMenu { playbackTrackMenu }
            }

            // Timestamp — clickable when a screen-share player is present
            if let onSeekToTime {
                Button {
                    onSeekToTime(segment.startTime)
                } label: {
                    Text(segment.formattedTimestamp)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .help("Show the shared screen at this moment")
            } else {
                Text(segment.formattedTimestamp)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Speaker badge
            speakerBadgeView

            if onPlayLine != nil {
                Button {
                    onPlayLine?()
                } label: {
                    Image(systemName: isPlayingLine ? "stop.fill" : "play.fill")
                        .font(.caption2)
                        .foregroundStyle(isPlayingLine ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isPlayingLine ? "Stop this line" : "Play the audio for this line")
            } else if segment.isEdited {
                Image(systemName: "pencil")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Edited")
            }

            // A mis-hearing the correction pass fixed. The original is one
            // hover away, which is what makes an automatic change acceptable.
            if !segment.isEdited, let original = segment.originalText, original != segment.text {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                    .help("Corrected by AI. Recogniser heard: \u{201C}\(original)\u{201D}")
            }

            // The recogniser itself was unsure — worth pressing play.
            if segment.confidence < TranscriptCorrectionService.lowConfidenceThreshold {
                Circle()
                    .fill(segment.confidence < 0.3 ? Color.red : Color.yellow)
                    .frame(width: 6, height: 6)
                    .help(String(format: "Transcriber confidence %.0f%% — worth a listen", segment.confidence * 100))
            }

            // Text content
            textContentView

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    isSelected ? Color.accentColor.opacity(0.08)
                        : isPlayingAudio ? Color.accentColor.opacity(0.05) : .clear
                )
        )
        .contextMenu { contextMenuItems }
        .confirmationDialog(
            "Delete this segment?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
        } message: {
            Text("\"\(segment.text.prefix(80))...\"")
        }
    }

    // MARK: - Playback track

    /// Which recording to play. Lives on the play button rather than in a
    /// toolbar because it is only meaningful next to the thing it changes.
    @ViewBuilder
    private var playbackTrackMenu: some View {
        let player = SegmentAudioPlayer.shared
        Picker("Play from", selection: Binding(
            get: { player.track },
            set: { player.track = $0 }
        )) {
            ForEach(SegmentAudioPlayer.Track.allCases) { track in
                Text(track.label).tag(track)
            }
        }
    }

    // MARK: - Speaker Badge

    @ViewBuilder
    private var speakerBadgeView: some View {
        SpeakerBadge(
            speaker: segment.speaker,
            actions: mergedSpeakerActions
        )
        .popover(isPresented: $showContactPicker) {
            ContactPicker(excludedContacts: []) { contact in
                changeSpeakerForAll(to: .other(contact.name))
                showContactPicker = false
            }
        }
        .popover(isPresented: $showSpeakerRename) {
            speakerRenamePopover
        }
    }

    /// Editor-specific items (this-one vs all) sit behind the shared speaker menu.
    private var mergedSpeakerActions: SpeakerBadgeActions {
        var merged = speakerActions
        if merged.onRename == nil {
            merged.onRename = { name, _ in
                speakerName = name
                commitSpeakerRename(applyToAll: true)
            }
        }
        if merged.onAddToContacts == nil {
            merged.onAddToContacts = { showContactPicker = true }
        }
        if merged.onSetAsMe == nil, !segment.speaker.isMe {
            merged.onSetAsMe = { changeSpeakerForAll(to: Speaker.resolvedMe()) }
        }
        return merged
    }

    /// The badge itself. A plain button when filtering is available, so the
    /// right-click menu (change / rename speaker) keeps working either way.
    @ViewBuilder
    private var badgeButton: some View {
        if let onFilterSpeaker {
            Button {
                onFilterSpeaker(segment.speaker)
            } label: {
                SpeakerBadge(speaker: segment.speaker)
            }
            .buttonStyle(.plain)
            .help("Show only \(segment.speaker.displayName)\u{2019}s lines")
        } else {
            SpeakerBadge(speaker: segment.speaker)
        }
    }

    // MARK: - Speaker Rename Popover

    private var speakerRenamePopover: some View {
        VStack(spacing: 8) {
            Text("Rename Speaker")
                .font(.headline)

            TextField("Speaker name", text: $speakerName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitSpeakerRename(applyToAll: false) }

            HStack {
                Button("Cancel") {
                    showSpeakerRename = false
                }
                Spacer()
                Button("This One") {
                    commitSpeakerRename(applyToAll: false)
                }
                Button("All From This Speaker") {
                    commitSpeakerRename(applyToAll: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Text Content

    @ViewBuilder
    private var textContentView: some View {
        if isEditingText {
            TextField("", text: $editedText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitEdit() }
                .onExitCommand { cancelEdit() }
                .onAppear {
                    // Auto-focus handled by SwiftUI
                }
        } else {
            Text(TranscriptTextHighlight.attributed(segment.text, query: highlightQuery))
                .font(.body)
                .textSelection(.enabled)
                .onTapGesture(count: 2) {
                    startEditing()
                }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Edit Text") {
            startEditing()
        }
        .keyboardShortcut(.return, modifiers: [])

        Divider()

        if hasNext {
            Button("Merge with Next Segment") {
                onMergeWithNext?()
            }
        }

        Button("Split Segment...") {
            startEditing()
        }

        Divider()

        Button("Split Into New Meeting") {
            onSplitMeeting?()
        }

        Divider()

        Button("Delete Segment", role: .destructive) {
            showDeleteConfirmation = true
        }

        if segment.isEdited {
            Divider()
            Button("Revert to Original") {
                revertToOriginal()
            }
        }
    }

    // MARK: - Text Editing

    private func startEditing() {
        editedText = segment.text
        isEditingText = true
    }

    private func commitEdit() {
        let trimmed = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != segment.text else {
            isEditingText = false
            return
        }

        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.text = trimmed
        segment.isEdited = true
        isEditingText = false
    }

    private func cancelEdit() {
        isEditingText = false
    }

    // MARK: - Revert

    private func revertToOriginal() {
        guard segment.isEdited else { return }
        if let originalText = segment.originalText {
            segment.text = originalText
        }
        if let originalSpeakerData = segment.originalSpeakerData {
            segment.speakerData = originalSpeakerData
        }
        segment.originalText = nil
        segment.originalSpeakerData = nil
        segment.isEdited = false
    }

    // MARK: - Speaker Changes

    private func changeSpeaker(to newSpeaker: Speaker) {
        if !segment.isEdited {
            segment.originalText = segment.text
            segment.originalSpeakerData = segment.speakerData
        }
        segment.speaker = newSpeaker
        segment.isEdited = true
    }

    private func changeSpeakerForAll(to newSpeaker: Speaker) {
        onChangeSpeakerForAll?(newSpeaker)
    }

    private func commitSpeakerRename(applyToAll: Bool) {
        let trimmed = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showSpeakerRename = false
            return
        }

        let newSpeaker = Speaker.renamed(from: segment.speaker, displayName: trimmed)

        if applyToAll {
            changeSpeakerForAll(to: newSpeaker)
        } else {
            changeSpeaker(to: newSpeaker)
        }
        showSpeakerRename = false
    }
}
