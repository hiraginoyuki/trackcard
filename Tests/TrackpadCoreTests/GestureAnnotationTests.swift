import Foundation
import Testing
@testable import TrackpadCore

private func attempt(_ label: GestureLabel) -> GestureAttempt {
    GestureRecordingSession(label: label, devices: [], at: 0).attempt
}

@Test func groupCategoryOverridesMembersWithoutChangingRecordedLabels() throws {
    let first = attempt(.swipe), second = attempt(.tilt)
    var annotations = GestureAnnotations()
    annotations.setCategory(GestureCategory(label: .pinch, counterexampleTo: .tilt), for: first)
    let groupID = annotations.group([first, second])
    let id = try #require(groupID)
    #expect(annotations.category(for: second) == GestureCategory(label: .pinch, counterexampleTo: .tilt))
    annotations.setCategory(GestureCategory(label: .swipe, counterexampleTo: .tilt), for: second)
    #expect(annotations.category(for: first) == GestureCategory(label: .swipe, counterexampleTo: .tilt))
    #expect(annotations.groups.first?.id == id)
    #expect(first.label == .swipe && second.label == .tilt)
}

@Test func ungroupingRetainsTheLastSharedCategoryAndCounterexample() throws {
    let first = attempt(.swipe), second = attempt(.tilt)
    var annotations = GestureAnnotations()
    let groupID = annotations.group([first, second])
    let id = try #require(groupID)
    let category = GestureCategory(label: .pinch, counterexampleTo: .tilt)
    annotations.setCategory(category, groupID: id)
    annotations.ungroup([first.id])
    #expect(annotations.group(containing: first.id) == nil)
    #expect(annotations.category(for: first) == category)
    #expect(annotations.group(containing: second.id)?.attemptIDs == [second.id])
    annotations.ungroup([second.id])
    #expect(annotations.groups.isEmpty)
    #expect(annotations.category(for: second) == category)
}

@Test func regroupingMovesOnlySelectedMembersAndPreservesTargetColor() throws {
    let first = attempt(.swipe), second = attempt(.pinch), third = attempt(.tilt), fourth = attempt(.tilt)
    var annotations = GestureAnnotations()
    let oldID = annotations.group([first, second])
    let targetID = annotations.group([third, fourth])
    let old = try #require(oldID)
    let target = try #require(targetID)
    let hue = try #require(annotations.groups.first { $0.id == target }?.hue)
    annotations.group([second, third, second], into: target)
    #expect(annotations.group(containing: first.id)?.id == old)
    #expect(annotations.group(containing: second.id)?.id == target)
    #expect(annotations.group(containing: fourth.id)?.id == target)
    let members = try #require(annotations.groups.first { $0.id == target })
    #expect(members.hue == hue && (0..<1).contains(hue))
    #expect(members.attemptIDs.count == 3 && Set(members.attemptIDs).count == 3)
    #expect(annotations.category(for: second).label == .tilt)
}

@Test func categoryCannotBeItsOwnCounterexample() {
    let first = attempt(.swipe)
    var annotations = GestureAnnotations()
    var category = GestureCategory(label: .swipe, counterexampleTo: .tilt)
    category.label = .tilt
    annotations.setCategory(category, for: first)
    #expect(annotations.category(for: first) == GestureCategory(label: .tilt))
    annotations.group([first])
    annotations.setCategory(GestureCategory(label: .pinch, counterexampleTo: .pinch), for: first)
    #expect(annotations.category(for: first) == GestureCategory(label: .pinch))
    annotations.setCategory(GestureCategory(label: .none, counterexampleTo: .pinch), for: first)
    #expect(annotations.category(for: first) == GestureCategory(label: .none, counterexampleTo: .pinch))
    annotations.setCategory(GestureCategory(label: .swipe, counterexampleTo: GestureLabel.none), for: first)
    #expect(annotations.category(for: first).counterexampleTo == nil)
}

@Test func annotationsRoundTripWithStableGroupIDsColorsAndOptionalColumn() throws {
    let first = attempt(.swipe), second = attempt(.tilt), third = attempt(.pinch)
    var annotations = GestureAnnotations()
    annotations.group([first, second])
    annotations.setCategory(GestureCategory(label: .swipe, counterexampleTo: .tilt), for: first)
    annotations.setCategory(GestureCategory(label: .pinch, counterexampleTo: .swipe), for: third)
    annotations.showsCounterexamples = true
    let decoded = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    #expect(decoded.groups == annotations.groups)
    #expect(decoded.categories == annotations.categories)
    #expect(decoded.showsCounterexamples)
    #expect(decoded.category(for: second) == GestureCategory(label: .swipe, counterexampleTo: .tilt))
    #expect(GestureAnnotations().category(for: third) == GestureCategory(label: .pinch))
}

@Test func sessionStatesDefaultToUnmarkedForOlderAnnotations() throws {
    let session = attempt(.pinch)
    let old = Data(#"{"schemaVersion":3,"groups":[],"categories":{},"showsCounterexamples":false}"#.utf8)
    let restored = try JSONDecoder().decode(GestureAnnotations.self, from: old)
    #expect(restored.sessionState(for: session) == .unmarked)
    #expect(restored.sessionStates.isEmpty)
}

@Test func sessionStatesAreExclusivePersistentAndIndependentOfCategories() throws {
    let first = attempt(.swipe), second = attempt(.tilt)
    var annotations = GestureAnnotations()
    annotations.setSessionState(.ready, for: first)
    #expect(annotations.sessionState(for: first) == .ready)
    annotations.setSessionState(.exclude, for: first)
    #expect(annotations.sessionState(for: first) == .exclude)
    #expect(annotations.sessionStates.count == 1)
    annotations.setSessionState(.ready, for: second)
    annotations.setCategory(GestureCategory(label: .none), for: first)
    var restored = try JSONDecoder().decode(GestureAnnotations.self, from: JSONEncoder().encode(annotations))
    #expect(restored.sessionState(for: first) == .exclude)
    #expect(restored.sessionState(for: second) == .ready)
    #expect(restored.category(for: first).label == .none)
    restored.inheritCategory(for: first)
    #expect(restored.sessionState(for: first) == .exclude)
    restored.setSessionState(.unmarked, for: first)
    #expect(restored.sessionState(for: first) == .unmarked)
    #expect(restored.sessionState(for: second) == .ready)
    #expect(restored.sessionStates.count == 1)
    #expect(restored.category(for: first).label == .swipe)
}
