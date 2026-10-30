import Testing
@testable import TrackpadCore

@Test func provisionalRumbleStaysSilentWithoutEvidence() {
    var feedback = GestureConfidenceFeedback()
    for index in 0...60 {
        #expect(feedback.update(0, at: Double(index) / 120) == nil)
    }
    #expect(feedback.confidence == 0)
}

@Test func provisionalRumbleStrengthensThenFadesAsEvidenceBecomesAmbiguous() {
    var feedback = GestureConfidenceFeedback()
    var strengths: [AdjustmentDetents.Strength] = []
    var pulseTimes: [Double] = []
    for index in 0...60 {
        let time = Double(index) / 120
        if let pulse = feedback.update(1, at: time) { strengths.append(pulse); pulseTimes.append(time) }
    }
    #expect(strengths.first == .tiny && strengths.last == .medium)
    #expect(feedback.confidence > 0.99)
    #expect(pulseTimes.count > 10 && pulseTimes.count < 20)
    for (first, second) in zip(pulseTimes, pulseTimes.dropFirst()) { #expect(second - first >= 0.03) }
    var finalPulses = 0
    for index in 61...100 {
        let pulse = feedback.update(0, at: Double(index) / 120)
        if index > 85 && pulse != nil { finalPulses += 1 }
    }
    #expect(feedback.confidence < 0.001 && finalPulses == 0)
}

@Test func invalidOrRepeatedConfidenceTimesCannotGenerateRumble() {
    var feedback = GestureConfidenceFeedback()
    #expect(feedback.update(.nan, at: 0) == nil)
    #expect(feedback.update(1, at: .infinity) == nil)
    _ = feedback.update(0.7, at: 1)
    let previous = feedback.confidence
    #expect(feedback.update(1, at: 1) == nil)
    #expect(feedback.update(1, at: 0.9) == nil)
    #expect(feedback.confidence == previous)
}
