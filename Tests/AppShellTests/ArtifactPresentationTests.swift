import Foundation
import PersistKit
import Testing

@testable import AppShell

struct ArtifactPresentationTests {
    @Test func blankOptionalCorrectionsStayUnstatedRatherThanInventingValues() {
        #expect(ArtifactPresentation.edit(.actionItem, text: "Send the brief", owner: " \n", deadline: "")
            == .actionItem(title: "Send the brief", owner: nil, deadline: nil))
        #expect(ArtifactPresentation.edit(.actionItem, text: "Send the brief", owner: " Alex ", deadline: " next Thursday ")
            == .actionItem(title: "Send the brief", owner: "Alex", deadline: "next Thursday"))
        #expect(ArtifactPresentation.edit(nil, text: "Unknown output", owner: "", deadline: "") == nil)
    }

    @Test func reviewedActionCopyRemainsOpenUntilTaskIsCompleted() throws {
        let draft = try DraftArtifact(kind: .actionItem, encoding: ActionItemPayload(
            title: "Share the mockups", owner: nil, deadline: nil))
        let reviewed = ArtifactRecord(
            id: UUID(), meetingID: UUID(), kind: draft.kind.rawValue,
            payload: draft.payload, status: ArtifactStatus.approved.rawValue, createdAt: .now)
        let copy = ArtifactPresentation.copyText(reviewed)
        #expect(copy.contains("Status · Open"))
        #expect(copy.contains("No owner stated"))
        #expect(copy.contains("No deadline stated"))
        #expect(!copy.contains("Complete"))
        let completed = ArtifactRecord(
            id: reviewed.id, meetingID: reviewed.meetingID, kind: reviewed.kind,
            payload: reviewed.payload, status: reviewed.status, createdAt: reviewed.createdAt,
            completedAt: .now)
        #expect(ArtifactPresentation.copyText(completed).contains("Status · Complete"))
    }
}
