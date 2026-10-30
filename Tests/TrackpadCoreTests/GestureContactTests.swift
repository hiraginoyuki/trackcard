import Foundation
import CoreGraphics
import Testing
@testable import TrackpadCore

private func frame(_ sequence: UInt64, _ paths: [Int32], device: UInt64 = 1) -> RecordedContactFrame {
    RecordedContactFrame(deviceID: device, sequence: sequence, time: Double(sequence) / 10,
        contacts: paths.map { RecordedContact(id: $0, stage: 4, position: CGPoint(x: 0.4, y: 0.5), radiiMM: CGSize(width: 6, height: 4), angle: 0) })
}

private func contactAttempt(_ frames: [RecordedContactFrame]) -> GestureAttempt {
    var session = GestureRecordingSession(label: .swipe, devices: [], at: 0)
    for frame in frames { session.receive(frame) }
    return session.finish(at: (frames.last?.time ?? 0) + 0.1)
}

@Test func twoSharedFramesJoinContactsButOneFrameDoesNot() throws {
    let one = contactAttempt([frame(0, [1]), frame(1, [1, 2]), frame(2, [2]), frame(3, [])])
    #expect(one.contactIndex?.automaticGroups.isEmpty == true)
    let two = contactAttempt([frame(0, [1]), frame(1, [1, 2]), frame(2, [1, 2]), frame(3, [])])
    let index = try #require(two.contactIndex)
    #expect(index.automaticGroups.count == 1 && index.automaticGroups[0].count == 2)
    #expect(index.overlaps[0].frames == 2)
}

@Test func overlappingContactGroupsJoinTransitivelyAndKeepSeparateTaps() throws {
    let attempt = contactAttempt([frame(0, [1, 2]), frame(1, [1, 2]), frame(2, [2, 3]), frame(3, [2, 3]),
                                  frame(4, []), frame(5, [4]), frame(6, [])])
    let index = try #require(attempt.contactIndex)
    #expect(index.contacts.count == 4)
    #expect(index.automaticGroups.count == 1 && index.automaticGroups[0].count == 3)
    #expect(!index.automaticGroups[0].contains(index.contacts[3].id))
}

@Test func reusedPathIDsCreateStableSeparateLifetimes() throws {
    let frames = [frame(0, [7]), frame(1, [7]), frame(2, []), frame(3, [7]), frame(4, [])]
    let first = try #require(contactAttempt(frames).contactIndex)
    let reindexed = try #require(contactAttempt(frames).contactIndex)
    #expect(first.contacts == reindexed.contacts)
    #expect(first.contacts.count == 2 && first.contacts[0].id != first.contacts[1].id)
    #expect(first.contacts[0].pathID == 7 && first.contacts[1].pathID == 7)
    #expect(first.contacts[0].samples == 2 && first.contacts[0].end == 0.2)
    #expect(first.contacts[0].isActive(at: 0.199) && !first.contacts[0].isActive(at: 0.2))
    #expect(first.contacts[1].start == 0.3 && first.contacts[1].samples == 1)
}

@Test func duplicateFramesAndIndependentDeviceClocksCannotCreateOverlap() {
    var tracker = GestureContactTracker()
    tracker.receive(frame(0, [1, 2]))
    tracker.receive(frame(0, [1, 2]))
    tracker.receive(frame(0, [1, 2], device: 2))
    #expect(tracker.index.automaticGroups.isEmpty)
    #expect(tracker.index.contacts.count == 4)
    tracker.receive(frame(1, [1, 2]))
    #expect(tracker.index.automaticGroups.count == 1)
    #expect(tracker.index.automaticGroups[0].allSatisfy { $0.hasPrefix("1:") })
}

@Test func contactAnnotationsPersistSharedLabelsAndRespectManualUngrouping() throws {
    let attempt = contactAttempt([frame(0, [1, 2]), frame(1, [1, 2]), frame(2, [])])
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    let initialized = annotations.initializeContactGroups(for: attempt)
    #expect(initialized)
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .swipe, counterexampleTo: .tilt), groupID: group.id)
    #expect(annotations.category(for: contacts[1], in: attempt).counterexampleTo == .tilt)
    let encoded = try JSONEncoder().encode(annotations)
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: encoded)
    #expect(restored.contactGroups == annotations.contactGroups)
    restored.ungroupContacts([contacts[0].id], in: attempt)
    #expect(restored.category(for: contacts[0], in: attempt) == GestureCategory(label: .swipe, counterexampleTo: .tilt))
    let reinitialized = restored.initializeContactGroups(for: attempt)
    #expect(!reinitialized)
    #expect(restored.contactGroup(containing: contacts[0].id, attemptID: attempt.id) == nil)
    let id = restored.groupContacts(Set(contacts.map(\.id)), in: attempt, into: group.id)
    #expect(id == group.id && restored.contactGroups[0].hue == group.hue)
}

@Test func oldRecordingSummariesAndAnnotationsRemainReadable() throws {
    let attempt = contactAttempt([frame(0, [1]), frame(1, [])])
    var summary = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
    summary.removeValue(forKey: "contactIndex")
    let decoded = try JSONDecoder().decode(GestureAttempt.self, from: JSONSerialization.data(withJSONObject: summary))
    #expect(decoded.contactIndex == nil && decoded.id == attempt.id)
    let old = Data(#"{"schemaVersion":1,"groups":[],"categories":{},"showsCounterexamples":true}"#.utf8)
    let annotations = try JSONDecoder().decode(GestureAnnotations.self, from: old)
    #expect(annotations.contactGroups.isEmpty && annotations.showsCounterexamples)
}

@Test func replayUsesTheRecordedClockWithoutRepeatingOrLeakingBeyondTheClip() {
    var cursor = GestureReplayCursor(frames: [frame(0, [1]), frame(1, [1]), frame(2, []), frame(3, [2])], start: 0.1, end: 0.2)
    let initial = cursor.advance(to: 0)
    #expect(initial.map(\.sequence) == [1])
    let middle = cursor.advance(to: 0.05)
    #expect(middle.isEmpty && abs(cursor.position - 0.15) < 0.000001)
    let ending = cursor.advance(to: 0.1)
    #expect(ending.map(\.sequence) == [2])
    let backwards = cursor.advance(to: 0), beyond = cursor.advance(to: 10)
    #expect(backwards.isEmpty && beyond.isEmpty)
    #expect(cursor.position == 0.2 && cursor.duration == 0.1)
}

@Test func replayPreservesEqualTimeFrameOrderingAcrossDevices() {
    var cursor = GestureReplayCursor(frames: [frame(0, [1], device: 2), frame(0, [1], device: 1)], end: 1)
    let initial = cursor.advance(to: 0)
    #expect(initial.map(\.deviceID) == [2, 1])
    let invalid = cursor.advance(to: .infinity)
    #expect(invalid.isEmpty)
}

@Test func replaySeeksToCurrentDeviceStatesWithoutFlashingPreviousTaps() {
    var cursor = GestureReplayCursor(frames: [
        frame(0, [7]), frame(1, []), frame(2, [8], device: 2),
        frame(3, [7]), frame(4, []), frame(5, [9]), frame(6, [])
    ], start: 0.45, end: 0.6)
    let initial = cursor.advance(to: 0)
    #expect(initial.map(\.deviceID) == [2, 1])
    #expect(initial.map(\.sequence) == [2, 4])
    #expect(initial.flatMap(\.contacts).map(\.id) == [8])
    #expect(cursor.advance(to: 0.1).flatMap(\.contacts).map(\.id) == [9])
    #expect(cursor.advance(to: 0.2).map(\.sequence) == [6])
}

@Test func replayStartingAtAReleaseUsesOnlyThatBoundaryState() {
    var cursor = GestureReplayCursor(frames: [frame(0, [1]), frame(1, [2]), frame(2, []), frame(3, [3])], start: 0.2, end: 0.3)
    let initial = cursor.advance(to: 0)
    #expect(initial.count == 1 && initial[0].sequence == 2 && initial[0].contacts.isEmpty)
    #expect(cursor.advance(to: 0).isEmpty)
}

@Test func shortReferencesAreUniqueAcrossSessionsAndReusedPathsAndSurviveReload() throws {
    let frames = [frame(0, [1, 2]), frame(1, [1, 2]), frame(2, []), frame(3, [1]), frame(4, [])]
    let first = contactAttempt(frames), second = contactAttempt(frames)
    var annotations = GestureAnnotations()
    for attempt in [first, second] {
        annotations.initializeContactGroups(for: attempt)
        annotations.initializeReferenceIDs(for: attempt)
    }
    let contactIDs = [first, second].flatMap { attempt in
        attempt.contactIndex!.contacts.compactMap { annotations.referenceID(for: $0, in: attempt) }
    }
    let groupIDs = annotations.contactGroups.compactMap { annotations.referenceID(for: $0) }
    let sessionIDs = [first, second].compactMap { annotations.referenceID(for: $0) }
    #expect(contactIDs.count == 6 && groupIDs.count == 2)
    #expect(sessionIDs.count == 2 && Set(contactIDs + groupIDs + sessionIDs).count == 10)
    #expect(sessionIDs.allSatisfy { $0.first == "s" && Int($0.dropFirst()) != nil })
    #expect(contactIDs.allSatisfy { $0.first == "c" && Int($0.dropFirst()) != nil })
    #expect(groupIDs.allSatisfy { $0.first == "g" && Int($0.dropFirst()) != nil })
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    for attempt in [first, second] {
        let changed = restored.initializeReferenceIDs(for: attempt)
        #expect(!changed)
        #expect(restored.referenceID(for: attempt) == annotations.referenceID(for: attempt))
        #expect(attempt.contactIndex!.contacts.allSatisfy {
            restored.referenceID(for: $0, in: attempt) == annotations.referenceID(for: $0, in: attempt)
        })
    }
    #expect(restored.contactGroups.compactMap { restored.referenceID(for: $0) } == groupIDs)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations)) as? [String: Any])
    let numbers = try #require(legacy["referenceNumbers"] as? [String: Int])
    legacy["referenceNumbers"] = numbers.filter { !$0.key.hasPrefix("session/") }
    var migrated = try JSONDecoder().decode(GestureAnnotations.self, from: JSONSerialization.data(withJSONObject: legacy))
    for attempt in [first, second] {
        let initialized = migrated.initializeReferenceIDs(for: attempt)
        #expect(initialized)
        #expect(migrated.referenceID(for: attempt) != nil)
        #expect(attempt.contactIndex!.contacts.allSatisfy {
            migrated.referenceID(for: $0, in: attempt) == annotations.referenceID(for: $0, in: attempt)
        })
    }
    #expect(migrated.contactGroups.compactMap { migrated.referenceID(for: $0) } == groupIDs)
}

@Test func regroupingKeepsContactReferencesAndNeverReusesARetiredGroupReference() throws {
    let attempt = contactAttempt([frame(0, [1, 2]), frame(1, [1, 2]), frame(2, [])])
    let contacts = try #require(attempt.contactIndex?.contacts)
    let ids = Set(contacts.map(\.id))
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    let oldGroup = try #require(annotations.contactGroups.first)
    let oldReference = try #require(annotations.referenceID(for: oldGroup))
    let references = contacts.compactMap { annotations.referenceID(for: $0, in: attempt) }
    annotations.ungroupContacts(ids, in: attempt)
    annotations = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    annotations.groupContacts(ids, in: attempt)
    let newGroup = try #require(annotations.contactGroups.first)
    #expect(annotations.referenceID(for: newGroup) != oldReference)
    #expect(contacts.compactMap { annotations.referenceID(for: $0, in: attempt) } == references)
    annotations.groupContacts(ids, in: attempt, into: newGroup.id)
    #expect(annotations.referenceID(for: annotations.contactGroups[0]) == annotations.referenceID(for: newGroup))
}

@Test func olderAnnotationsGainReferencesWithoutChangingCategoriesOrReviewMarks() throws {
    let attempt = contactAttempt([frame(0, [1, 2]), frame(1, [1, 2]), frame(2, [])])
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    annotations.setSessionState(.ready, for: attempt)
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations)) as? [String: Any])
    old.removeValue(forKey: "referenceNumbers")
    old["schemaVersion"] = 4
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONSerialization.data(withJSONObject: old))
    let changed = restored.initializeReferenceIDs(for: attempt)
    #expect(changed)
    #expect(restored.contactGroups == annotations.contactGroups)
    #expect(restored.category(for: attempt).label == .pinch)
    #expect(restored.sessionState(for: attempt) == .ready)
    #expect(restored.referenceID(for: attempt) != nil)
    #expect(restored.referenceID(for: restored.contactGroups[0]) != nil)
    #expect(attempt.contactIndex!.contacts.allSatisfy { restored.referenceID(for: $0, in: attempt) != nil })
}

private func twoGroupAttempt() -> GestureAttempt {
    contactAttempt([frame(0, [1, 2]), frame(1, [1, 2]), frame(2, []),
                    frame(3, [3, 4]), frame(4, [3, 4]), frame(5, []),
                    frame(6, [5]), frame(7, []), frame(8, [6]), frame(9, [])])
}

@Test func sessionCategoryChangesInheritedGroupsWhileUngroupedContactsStayNone() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    let before = annotations.contactGroups
    let category = GestureCategory(label: .pinch, counterexampleTo: .tilt)
    annotations.setCategory(category, for: attempt)
    #expect(annotations.category(for: attempt) == category)
    #expect(annotations.contactGroups.count == 2)
    #expect(annotations.contactGroups.allSatisfy { $0.category == category && $0.overridesSessionCategory == false })
    #expect(contacts.prefix(4).allSatisfy { annotations.category(for: $0, in: attempt) == category })
    #expect(contacts.suffix(2).allSatisfy { annotations.category(for: $0, in: attempt) == GestureCategory(label: .none) })
    #expect(annotations.contactGroups.map(\.id) == before.map(\.id))
    #expect(annotations.contactGroups.map(\.hue) == before.map(\.hue))
    #expect(attempt.label == .swipe)
}

@Test func manualCategoryOverridesSurviveMatchingSessionLabelsAndReload() throws {
    let attempt = twoGroupAttempt(), unrelated = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    annotations.initializeContactGroups(for: unrelated)
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .pinch), groupID: group.id)
    annotations.setCategory(GestureCategory(label: .swipe), for: contacts[4], in: attempt)
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    restored.setCategory(GestureCategory(label: .tilt), for: attempt)
    #expect(restored.category(for: contacts[0], in: attempt).label == .pinch)
    #expect(restored.category(for: contacts[2], in: attempt).label == .tilt)
    #expect(restored.category(for: contacts[4], in: attempt).label == .swipe)
    #expect(restored.category(for: contacts[5], in: attempt).label == .none)
    #expect(restored.contactGroups.first { $0.id == group.id }?.overridesSessionCategory == true)
    #expect(restored.contactGroups.filter { $0.attemptID == unrelated.id }.allSatisfy { $0.category.label == .swipe })
}

@Test func olderGroupAnnotationsInferOverridesBeforeChangingSessionCategory() throws {
    let attempt = twoGroupAttempt()
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .tilt), groupID: group.id)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(annotations)) as? [String: Any])
    var groups = try #require(json["contactGroups"] as? [[String: Any]])
    for index in groups.indices { groups[index].removeValue(forKey: "overridesSessionCategory") }
    json["contactGroups"] = groups; json["schemaVersion"] = 2
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(restored.contactGroups.allSatisfy { $0.overridesSessionCategory == nil })
    restored.setCategory(GestureCategory(label: .pinch), for: attempt)
    #expect(restored.contactGroups.first { $0.id == group.id }?.category.label == .tilt)
    #expect(restored.contactGroups.first { $0.id != group.id }?.category.label == .pinch)
    #expect(restored.contactGroups.first { $0.id == group.id }?.overridesSessionCategory == true)
    restored.setCategory(GestureCategory(label: .swipe), for: attempt)
    #expect(restored.contactGroups.first { $0.id != group.id }?.category.label == .swipe)
    #expect(restored.schemaVersion == 5)
}

@Test func ungroupedContactsDefaultToNoneAndRegroupingRestoresSessionInheritance() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    annotations.ungroupContacts([contacts[0].id, contacts[1].id], in: attempt)
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    #expect(annotations.category(for: contacts[0], in: attempt).label == .none)
    let grouped = annotations.groupContacts([contacts[0].id, contacts[1].id], in: attempt)
    let id = try #require(grouped)
    #expect(annotations.contactGroups.first { $0.id == id }?.overridesSessionCategory == false)
    annotations.setCategory(GestureCategory(label: .tilt), for: attempt)
    #expect(annotations.category(for: contacts[0], in: attempt).label == .tilt)
}

@Test func groupingOverriddenContactsPreservesTheirCategoryOverride() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.setCategory(GestureCategory(label: .pinch), for: contacts[4], in: attempt)
    let grouped = annotations.groupContacts([contacts[4].id, contacts[5].id], in: attempt)
    let id = try #require(grouped)
    annotations.setCategory(GestureCategory(label: .tilt), for: attempt)
    #expect(annotations.contactGroups.first { $0.id == id }?.overridesSessionCategory == true)
    #expect(annotations.category(for: contacts[5], in: attempt).label == .pinch)
    annotations.ungroupContacts([contacts[4].id, contacts[5].id], in: attempt)
    annotations.setCategory(GestureCategory(label: .swipe), for: attempt)
    #expect(annotations.category(for: contacts[4], in: attempt).label == .pinch)
    #expect(annotations.category(for: contacts[5], in: attempt).label == .pinch)
}

@Test func automaticGroupsUseASessionCategoryEditedBeforeIndexing() throws {
    let attempt = twoGroupAttempt()
    var annotations = GestureAnnotations()
    annotations.setCategory(GestureCategory(label: .tilt), for: attempt)
    annotations.initializeContactGroups(for: attempt)
    #expect(annotations.contactGroups.count == 2)
    #expect(annotations.contactGroups.allSatisfy { $0.category.label == .tilt && $0.overridesSessionCategory == false })
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    #expect(annotations.contactGroups.allSatisfy { $0.category.label == .pinch })
}

@Test func noneCategoryPersistsForSessionsGroupsAndExplicitContacts() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    annotations.setCategory(GestureCategory(label: .none), for: attempt)
    #expect(annotations.contactGroups.allSatisfy { $0.category.label == .none })
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .none), groupID: group.id)
    annotations.setCategory(GestureCategory(label: .none), for: contacts[4], in: attempt)
    let encoded = try JSONEncoder().encode(annotations)
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: encoded)
    #expect(restored.category(for: attempt).label == .none)
    #expect(restored.categories[attempt.id.uuidString + "/" + contacts[4].id] == GestureCategory(label: .none))
    restored.setCategory(GestureCategory(label: .tilt), for: attempt)
    #expect(restored.category(for: contacts[0], in: attempt).label == .none)
    #expect(restored.category(for: contacts[2], in: attempt).label == .tilt)
    #expect(restored.category(for: contacts[4], in: attempt).label == .none)
    #expect(restored.category(for: contacts[5], in: attempt).label == .none)
    #expect(attempt.label == .swipe)
}

@Test func groupingDefaultNoneContactsInheritsButExplicitNoneRemainsAnOverride() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    #expect(annotations.category(for: contacts[4], in: attempt).label == .none)
    annotations.groupContacts([contacts[4].id, contacts[5].id], in: attempt)
    #expect(annotations.category(for: contacts[4], in: attempt).label == .swipe)
    annotations.ungroupContacts([contacts[4].id, contacts[5].id], in: attempt)
    #expect(annotations.category(for: contacts[4], in: attempt).label == .none)
    annotations.setCategory(GestureCategory(label: .none), for: contacts[4], in: attempt)
    annotations.groupContacts([contacts[4].id, contacts[5].id], in: attempt)
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    #expect(annotations.category(for: contacts[4], in: attempt).label == .none)
    #expect(annotations.category(for: contacts[5], in: attempt).label == .none)
}

@Test func inheritingAgainClearsAGroupOverrideAndResumesSessionUpdates() throws {
    let attempt = twoGroupAttempt()
    let contacts = try #require(attempt.contactIndex?.contacts)
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .none), groupID: group.id)
    #expect(!annotations.inheritsCategory(for: contacts[0], in: attempt))
    annotations.setCategory(GestureCategory(label: .tilt, counterexampleTo: .pinch), for: attempt)
    #expect(annotations.inheritedCategory(for: contacts[0], in: attempt) == GestureCategory(label: .tilt, counterexampleTo: .pinch))
    annotations.inheritCategory(for: contacts[0], in: attempt)
    #expect(annotations.inheritsCategory(for: contacts[1], in: attempt))
    #expect(annotations.category(for: contacts[0], in: attempt) == GestureCategory(label: .tilt, counterexampleTo: .pinch))
    let inheritedGroup = try #require(annotations.contactGroups.first { $0.id == group.id })
    #expect(annotations.inheritsCategory(for: inheritedGroup, in: attempt))
    annotations.setCategory(GestureCategory(label: .pinch), for: attempt)
    #expect(annotations.category(for: contacts[0], in: attempt).label == .pinch)
}

@Test func inheritingNoneClearsAnExplicitUngroupedContactLabel() throws {
    let attempt = twoGroupAttempt()
    let contact = try #require(attempt.contactIndex?.contacts.last)
    var annotations = GestureAnnotations()
    #expect(annotations.inheritsCategory(for: contact, in: attempt))
    annotations.setCategory(GestureCategory(label: .none), for: contact, in: attempt)
    #expect(!annotations.inheritsCategory(for: contact, in: attempt))
    annotations.setCategory(GestureCategory(label: .pinch), for: contact, in: attempt)
    annotations.inheritCategory(for: contact, in: attempt)
    let restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    #expect(restored.inheritsCategory(for: contact, in: attempt))
    #expect(restored.category(for: contact, in: attempt).label == .none)
    #expect(restored.inheritedCategory(for: contact, in: attempt).label == .none)
}

@Test func inheritingASessionRestoresItsOriginalLabelWithoutChangingGroupOverrides() throws {
    let attempt = twoGroupAttempt()
    var annotations = GestureAnnotations()
    annotations.initializeContactGroups(for: attempt)
    let group = try #require(annotations.contactGroups.first)
    annotations.setContactCategory(GestureCategory(label: .none), groupID: group.id)
    annotations.setCategory(GestureCategory(label: .tilt, counterexampleTo: .pinch), for: attempt)
    #expect(!annotations.inheritsCategory(for: attempt))
    annotations.inheritCategory(for: attempt)
    #expect(annotations.inheritsCategory(for: attempt))
    #expect(annotations.category(for: attempt) == GestureCategory(label: .swipe))
    #expect(annotations.contactGroups.first { $0.id == group.id }?.category.label == GestureLabel.none)
    #expect(annotations.contactGroups.first { $0.id != group.id }?.category.label == .swipe)
    let restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    #expect(restored.inheritsCategory(for: attempt))
}
