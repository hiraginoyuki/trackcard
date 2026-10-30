import Foundation

public enum GestureSessionState: String, Codable, CaseIterable, Sendable {
    case ready = "Ready", unmarked = "Unmarked", exclude = "Exclude"
}

public struct GestureCategory: Codable, Equatable, Sendable {
    public var label: GestureLabel
    public var counterexampleTo: GestureLabel?

    public init(label: GestureLabel, counterexampleTo: GestureLabel? = nil) {
        self.label = label
        self.counterexampleTo = counterexampleTo == label || counterexampleTo == GestureLabel.none ? nil : counterexampleTo
    }
}

public struct GestureRecordingGroup: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var hue: Double
    public var category: GestureCategory
    public var attemptIDs: [UUID]

    public init(category: GestureCategory, attemptIDs: [UUID], hue: Double = .random(in: 0..<1)) {
        self.category = category
        self.attemptIDs = attemptIDs
        self.hue = hue
    }
}

public struct GestureContactGroup: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var attemptID: UUID
    public var hue: Double = .random(in: 0..<1)
    public var category: GestureCategory
    public var contactIDs: [String]
    /// Older annotations omit this flag. A category that differs from the
    /// session's current category is treated as a manual override.
    public var overridesSessionCategory: Bool?
}

/// Annotations are separate from immutable sensor logs. Group categories take
/// precedence over individual overrides and the label chosen while recording.
public struct GestureAnnotations: Codable, Sendable {
    public var schemaVersion = 5
    public private(set) var groups: [GestureRecordingGroup] = []
    public private(set) var categories: [String: GestureCategory] = [:]
    public var showsCounterexamples = false
    public private(set) var contactGroups: [GestureContactGroup] = []
    public private(set) var sessionStates: [String: GestureSessionState] = [:]
    private var initializedContacts: Set<String> = []
    // Keep retired entries so a deleted group's reference is never reused.
    private var referenceNumbers: [String: Int] = [:]
    private var nextReferenceNumber = 1

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, groups, categories, showsCounterexamples, contactGroups, initializedContacts, sessionStates, referenceNumbers
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groups = try values.decodeIfPresent([GestureRecordingGroup].self, forKey: .groups) ?? []
        categories = try values.decodeIfPresent([String: GestureCategory].self, forKey: .categories) ?? [:]
        showsCounterexamples = try values.decodeIfPresent(Bool.self, forKey: .showsCounterexamples) ?? false
        contactGroups = try values.decodeIfPresent([GestureContactGroup].self, forKey: .contactGroups) ?? []
        sessionStates = try values.decodeIfPresent([String: GestureSessionState].self, forKey: .sessionStates) ?? [:]
        initializedContacts = try values.decodeIfPresent(Set<String>.self, forKey: .initializedContacts) ?? []
        referenceNumbers = try values.decodeIfPresent([String: Int].self, forKey: .referenceNumbers) ?? [:]
        nextReferenceNumber = (referenceNumbers.values.max() ?? 0) + 1
    }

    public func referenceID(for attempt: GestureAttempt) -> String? {
        referenceNumbers["session/\(attempt.id)"].map { "s\($0)" }
    }

    public func referenceID(for contact: GestureContactIdentity, in attempt: GestureAttempt) -> String? {
        referenceNumbers["contact/\(attempt.id)/\(contact.id)"].map { "c\($0)" }
    }

    public func referenceID(for group: GestureContactGroup) -> String? {
        referenceNumbers["group/\(group.id)"].map { "g\($0)" }
    }

    @discardableResult
    public mutating func initializeReferenceIDs(for attempt: GestureAttempt) -> Bool {
        let previousCount = referenceNumbers.count
        assignReferenceNumber(to: "session/\(attempt.id)")
        for contact in attempt.contactIndex?.contacts ?? [] {
            assignReferenceNumber(to: "contact/\(attempt.id)/\(contact.id)")
        }
        for group in contactGroups where group.attemptID == attempt.id {
            assignReferenceNumber(to: "group/\(group.id)")
        }
        return referenceNumbers.count != previousCount
    }

    private mutating func assignReferenceNumber(to key: String) {
        guard referenceNumbers[key] == nil else { return }
        referenceNumbers[key] = nextReferenceNumber
        nextReferenceNumber += 1
    }

    public func sessionState(for attempt: GestureAttempt) -> GestureSessionState {
        sessionStates[attempt.id.uuidString] ?? .unmarked
    }

    public mutating func setSessionState(_ state: GestureSessionState, for attempt: GestureAttempt) {
        if state == .unmarked { sessionStates.removeValue(forKey: attempt.id.uuidString) }
        else { sessionStates[attempt.id.uuidString] = state }
    }

    public func contactGroup(containing id: String, attemptID: UUID) -> GestureContactGroup? {
        contactGroups.first { $0.attemptID == attemptID && $0.contactIDs.contains(id) }
    }

    public func category(for contact: GestureContactIdentity, in attempt: GestureAttempt) -> GestureCategory {
        contactGroup(containing: contact.id, attemptID: attempt.id)?.category
            ?? categories[attempt.id.uuidString + "/" + contact.id] ?? GestureCategory(label: .none)
    }

    public func inheritedCategory(for contact: GestureContactIdentity, in attempt: GestureAttempt) -> GestureCategory {
        contactGroup(containing: contact.id, attemptID: attempt.id) == nil ? GestureCategory(label: .none) : category(for: attempt)
    }

    public func inheritsCategory(for contact: GestureContactIdentity, in attempt: GestureAttempt) -> Bool {
        if let group = contactGroup(containing: contact.id, attemptID: attempt.id) { return inheritsCategory(for: group, in: attempt) }
        return categories[attempt.id.uuidString + "/" + contact.id] == nil
    }

    public func inheritsCategory(for group: GestureContactGroup, in attempt: GestureAttempt) -> Bool {
        !(group.overridesSessionCategory ?? (group.category != category(for: attempt)))
    }

    public mutating func inheritCategory(for contact: GestureContactIdentity, in attempt: GestureAttempt) {
        if let group = contactGroup(containing: contact.id, attemptID: attempt.id) { inheritContactCategory(groupID: group.id, in: attempt) }
        else { categories.removeValue(forKey: attempt.id.uuidString + "/" + contact.id) }
    }

    public mutating func inheritContactCategory(groupID: UUID, in attempt: GestureAttempt) {
        guard let index = contactGroups.firstIndex(where: { $0.id == groupID && $0.attemptID == attempt.id }) else { return }
        contactGroups[index].category = category(for: attempt)
        contactGroups[index].overridesSessionCategory = false
    }

    public mutating func setCategory(_ category: GestureCategory, for contact: GestureContactIdentity, in attempt: GestureAttempt) {
        if let group = contactGroup(containing: contact.id, attemptID: attempt.id) { setContactCategory(category, groupID: group.id) }
        else { categories[attempt.id.uuidString + "/" + contact.id] = normalized(category) }
    }

    public mutating func setContactCategory(_ category: GestureCategory, groupID: UUID) {
        guard let position = contactGroups.firstIndex(where: { $0.id == groupID }) else { return }
        contactGroups[position].category = normalized(category)
        contactGroups[position].overridesSessionCategory = true
    }

    @discardableResult
    public mutating func groupContacts(_ contactIDs: Set<String>, in attempt: GestureAttempt, into groupID: UUID? = nil) -> UUID? {
        let contacts = attempt.contactIndex?.contacts.filter { contactIDs.contains($0.id) } ?? []
        guard let first = contacts.first else { return nil }
        let inherited = category(for: attempt)
        let source = contactGroup(containing: first.id, attemptID: attempt.id)
        let explicit = categories[attempt.id.uuidString + "/" + first.id]
        let overrides = source.map {
            $0.overridesSessionCategory ?? ($0.category != inherited)
        } ?? (explicit != nil)
        var target = contactGroups.first { $0.id == groupID && $0.attemptID == attempt.id }
            ?? GestureContactGroup(attemptID: attempt.id, category: source?.category ?? explicit ?? inherited, contactIDs: [],
                                   overridesSessionCategory: overrides)
        for contact in contacts where !target.contactIDs.contains(contact.id) { target.contactIDs.append(contact.id) }
        contactGroups = contactGroups.compactMap { group in
            guard group.id != target.id else { return nil }
            guard group.attemptID == attempt.id else { return group }
            var remaining = group
            remaining.contactIDs.removeAll { contactIDs.contains($0) }
            return remaining.contactIDs.isEmpty ? nil : remaining
        }
        contactGroups.append(target)
        initializeReferenceIDs(for: attempt)
        initializedContacts.insert(attempt.id.uuidString)
        return target.id
    }

    public mutating func ungroupContacts(_ contactIDs: Set<String>, in attempt: GestureAttempt) {
        let inherited = category(for: attempt)
        contactGroups = contactGroups.compactMap { group in
            guard group.attemptID == attempt.id else { return group }
            var remaining = group
            for id in group.contactIDs where contactIDs.contains(id) {
                let key = attempt.id.uuidString + "/" + id
                if group.overridesSessionCategory ?? (group.category != inherited) { categories[key] = group.category }
                else { categories.removeValue(forKey: key) }
            }
            remaining.contactIDs.removeAll { contactIDs.contains($0) }
            return remaining.contactIDs.isEmpty ? nil : remaining
        }
        initializedContacts.insert(attempt.id.uuidString)
    }

    /// A deliberate ungroup is preserved on reload; automatic grouping only
    /// initializes a session once.
    @discardableResult
    public mutating func initializeContactGroups(for attempt: GestureAttempt) -> Bool {
        guard let index = attempt.contactIndex, !initializedContacts.contains(attempt.id.uuidString) else { return false }
        for contacts in index.automaticGroups { groupContacts(Set(contacts), in: attempt) }
        initializedContacts.insert(attempt.id.uuidString)
        return true
    }

    public func group(containing attemptID: UUID) -> GestureRecordingGroup? {
        groups.first { $0.attemptIDs.contains(attemptID) }
    }

    public func category(for attempt: GestureAttempt) -> GestureCategory {
        group(containing: attempt.id)?.category ?? categories[attempt.id.uuidString]
            ?? inheritedCategory(for: attempt)
    }

    public func inheritedCategory(for attempt: GestureAttempt) -> GestureCategory { GestureCategory(label: attempt.label) }

    public func inheritsCategory(for attempt: GestureAttempt) -> Bool {
        group(containing: attempt.id) == nil && categories[attempt.id.uuidString] == nil
    }

    public mutating func inheritCategory(for attempt: GestureAttempt) {
        let previous = category(for: attempt)
        if group(containing: attempt.id) != nil { ungroup([attempt.id]) }
        categories.removeValue(forKey: attempt.id.uuidString)
        updateInheritedContactGroups(inheritedCategory(for: attempt), in: [attempt.id], previously: previous)
    }

    public mutating func setCategory(_ category: GestureCategory, for attempt: GestureAttempt) {
        if let group = group(containing: attempt.id) { setCategory(category, groupID: group.id) }
        else {
            let previous = self.category(for: attempt)
            let category = normalized(category)
            updateInheritedContactGroups(category, in: [attempt.id], previously: previous)
            categories[attempt.id.uuidString] = category
        }
    }

    public mutating func setCategory(_ category: GestureCategory, groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let category = normalized(category)
        updateInheritedContactGroups(category, in: Set(groups[index].attemptIDs), previously: groups[index].category)
        groups[index].category = category
    }

    @discardableResult
    public mutating func group(_ attempts: [GestureAttempt], into groupID: UUID? = nil) -> UUID? {
        guard let first = attempts.first else { return nil }
        let ids = Set(attempts.map(\.id))
        let previous = attempts.reduce(into: [UUID: GestureCategory]()) { $0[$1.id] = category(for: $1) }
        var target = groups.first { $0.id == groupID }
            ?? GestureRecordingGroup(category: category(for: first), attemptIDs: [])
        for attempt in attempts where !target.attemptIDs.contains(attempt.id) { target.attemptIDs.append(attempt.id) }
        groups = groups.compactMap { group in
            guard group.id != target.id else { return nil }
            var remaining = group
            remaining.attemptIDs.removeAll { ids.contains($0) }
            return remaining.attemptIDs.isEmpty ? nil : remaining
        }
        groups.append(target)
        for (id, category) in previous {
            updateInheritedContactGroups(target.category, in: [id], previously: category)
        }
        return target.id
    }

    public mutating func ungroup(_ attemptIDs: Set<UUID>) {
        groups = groups.compactMap { group in
            var remaining = group
            for id in group.attemptIDs where attemptIDs.contains(id) { categories[id.uuidString] = group.category }
            remaining.attemptIDs.removeAll { attemptIDs.contains($0) }
            return remaining.attemptIDs.isEmpty ? nil : remaining
        }
    }

    private mutating func updateInheritedContactGroups(_ category: GestureCategory, in attemptIDs: Set<UUID>,
                                                       previously previous: GestureCategory) {
        for index in contactGroups.indices where attemptIDs.contains(contactGroups[index].attemptID) {
            let overrides = contactGroups[index].overridesSessionCategory ?? (contactGroups[index].category != previous)
            contactGroups[index].overridesSessionCategory = overrides
            if !overrides { contactGroups[index].category = category }
        }
    }

    private func normalized(_ category: GestureCategory) -> GestureCategory {
        GestureCategory(label: category.label, counterexampleTo: category.counterexampleTo)
    }
}
