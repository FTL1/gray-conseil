import SwiftUI
import SwiftData

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    var onSplitMeeting: ((Meeting) -> Void)?
    @Binding var scrollToSegmentID: UUID?
    @State private var meetingFind = MeetingFindController()

    init(
        meeting: Meeting,
        onSplitMeeting: ((Meeting) -> Void)? = nil,
        scrollToSegmentID: Binding<UUID?> = .constant(nil)
    ) {
        self._meeting = Bindable(wrappedValue: meeting)
        self.onSplitMeeting = onSplitMeeting
        self._scrollToSegmentID = scrollToSegmentID
    }

    var body: some View {
        VStack(spacing: 0) {
            MeetingHeaderBar(meeting: meeting)
            Divider()

            if meeting.seriesID != nil, let seriesTitle = meeting.seriesTitle {
                SeriesSectionView(meeting: meeting, seriesTitle: seriesTitle)
                    .padding(.horizontal)
                Divider()
            }

            TranscriptPanelView(
                meeting: meeting,
                onSplitMeeting: onSplitMeeting,
                scrollToSegmentID: $scrollToSegmentID
            )
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(meetingFind)
    }
}

struct SeriesSectionView: View {
    let meeting: Meeting
    let seriesTitle: String

    @Query private var seriesMeetings: [Meeting]

    init(meeting: Meeting, seriesTitle: String) {
        self.meeting = meeting
        self.seriesTitle = seriesTitle
        let currentID = meeting.id
        if let seriesID = meeting.seriesID {
            _seriesMeetings = Query(
                filter: #Predicate<Meeting> { other in
                    other.seriesID == seriesID && other.id != currentID
                },
                sort: \Meeting.date,
                order: .reverse
            )
        } else {
            let none = UUID()
            _seriesMeetings = Query(
                filter: #Predicate<Meeting> { other in other.id == none }
            )
        }
    }

    var body: some View {
        if !seriesMeetings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Series: \(seriesTitle)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))

                ForEach(seriesMeetings.prefix(5)) { m in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(m.title)
                            .font(.caption)
                        Spacer()
                        Text(m.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
