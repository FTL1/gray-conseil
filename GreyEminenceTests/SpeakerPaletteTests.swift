import XCTest
import SwiftUI
@testable import Grey_Eminence

final class SpeakerPaletteTests: XCTestCase {
    func testLockedPersonKeepsColorWhenANewcomerClashes() {
        let established = UUID()
        let newcomer = UUID()
        var claims = [
            SpeakerPalette.Claim(
                id: established,
                name: "Jordan Hale",
                meetingCount: 12,
                createdAt: Date(timeIntervalSince1970: 1),
                slot: 2,
                locked: true
            ),
            SpeakerPalette.Claim(
                id: newcomer,
                name: "Guest Star",
                meetingCount: 1,
                createdAt: Date(timeIntervalSince1970: 9_999),
                slot: 2,
                locked: false
            )
        ]
        SpeakerPalette.resolve(&claims)
        XCTAssertEqual(claims.first { $0.id == established }?.slot, 2)
        XCTAssertNotEqual(claims.first { $0.id == newcomer }?.slot, 2)
    }

    func testMoreCommonSpeakerKeepsHashWhenUnlocked() {
        let alex = UUID()
        let rare = UUID()
        let slot = SpeakerPalette.hashSlot(for: "Alex")
        var claims = [
            SpeakerPalette.Claim(
                id: alex,
                name: "Alex",
                meetingCount: 40,
                createdAt: Date(timeIntervalSince1970: 1),
                slot: slot,
                locked: false
            ),
            SpeakerPalette.Claim(
                id: rare,
                name: "Rare Person",
                meetingCount: 1,
                createdAt: Date(timeIntervalSince1970: 50),
                slot: slot,
                locked: false
            )
        ]
        SpeakerPalette.resolve(&claims)
        XCTAssertEqual(claims.first { $0.id == alex }?.slot, slot)
        XCTAssertNotEqual(claims.first { $0.id == rare }?.slot, slot)
    }

    func testHashSlotIsStable() {
        XCTAssertEqual(SpeakerPalette.hashSlot(for: "Jordan Hale"), SpeakerPalette.hashSlot(for: "jordan hale"))
    }

    func testColorFollowsContactIDNotDisplayName() {
        let jane = Contact(name: "JD Jane")
        jane.colorSlot = 1
        let color = SpeakerPalette.color(
            for: .meNamed("Jane"),
            contactID: jane.id,
            contacts: [jane]
        )
        XCTAssertEqual(color, SpeakerPalette.color(slot: 1))
        XCTAssertEqual(
            SpeakerPalette.contact(for: .meNamed("Jane"), contactID: jane.id, in: [jane])?.id,
            jane.id
        )
    }

    func testMeMatchesCalendarInitialsContact() {
        let jane = Contact(name: "JD Jane")
        jane.colorSlot = 1
        let found = SpeakerPalette.contact(for: .meNamed("Jane"), in: [jane])
        XCTAssertEqual(found?.id, jane.id)
        XCTAssertEqual(
            SpeakerPalette.color(for: .meNamed("Jane"), contacts: [jane]),
            SpeakerPalette.color(slot: 1)
        )
    }
}
