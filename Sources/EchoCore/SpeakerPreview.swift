import Foundation

public struct SpeakerPreview: Sendable, Equatable {
    public var speakerID: String
    public var track: AudioTrack
    public var start: Double
    public var end: Double
    public var overlapsAnotherSpeaker: Bool
    public var shortSample: Bool { end - start < 2 }

    public init(speakerID: String, track: AudioTrack, start: Double, end: Double,
                overlapsAnotherSpeaker: Bool) {
        self.speakerID = speakerID; self.track = track; self.start = start; self.end = end
        self.overlapsAnotherSpeaker = overlapsAnotherSpeaker
    }
}

public enum SpeakerPreviewSelector {
    /// Samples come only from durable source-track coverage. Excluded ranges
    /// include intentional gaps and deleted audio intervals.
    public static func previews(for run: SpeakerGroupingRun, coverage: [CapturedChunk],
                                redactions: [Range<Double>] = []) -> [String: [SpeakerPreview]] {
        var candidates: [String: [SpeakerPreview]] = [:]
        let source = coverage.filter { $0.track == run.track }
        for turn in run.turns where turn.start.isFinite && turn.end.isFinite && turn.end > turn.start {
            let otherTurns = run.turns.filter { $0.speakerID != turn.speakerID && $0.start < turn.end && $0.end > turn.start }
            for chunk in source where chunk.startTime < turn.end && chunk.startTime + chunk.duration > turn.start {
                var intervals = [max(turn.start, chunk.startTime)..<min(turn.end, chunk.startTime + chunk.duration)]
                for excluded in redactions {
                    intervals = intervals.flatMap { interval -> [Range<Double>] in
                        guard excluded.lowerBound < interval.upperBound && excluded.upperBound > interval.lowerBound else { return [interval] }
                        var retained: [Range<Double>] = []
                        if excluded.lowerBound > interval.lowerBound { retained.append(interval.lowerBound..<min(excluded.lowerBound, interval.upperBound)) }
                        if excluded.upperBound < interval.upperBound { retained.append(max(excluded.upperBound, interval.lowerBound)..<interval.upperBound) }
                        return retained
                    }
                }
                for interval in intervals where interval.upperBound > interval.lowerBound {
                    let clean = otherTurns.reduce([interval]) { portions, other in
                        portions.flatMap { portion -> [Range<Double>] in
                            guard other.start < portion.upperBound && other.end > portion.lowerBound else { return [portion] }
                            var retained: [Range<Double>] = []
                            if other.start > portion.lowerBound { retained.append(portion.lowerBound..<min(other.start, portion.upperBound)) }
                            if other.end < portion.upperBound { retained.append(max(other.end, portion.lowerBound)..<portion.upperBound) }
                            return retained
                        }
                    }
                    for portion in clean where portion.upperBound > portion.lowerBound {
                        candidates[turn.speakerID, default: []].append(.init(speakerID: turn.speakerID, track: run.track,
                                                                              start: portion.lowerBound,
                                                                              end: min(portion.upperBound, portion.lowerBound + 8),
                                                                              overlapsAnotherSpeaker: false))
                    }
                    if clean.isEmpty {
                        candidates[turn.speakerID, default: []].append(.init(speakerID: turn.speakerID, track: run.track,
                                                                              start: interval.lowerBound,
                                                                              end: min(interval.upperBound, interval.lowerBound + 8),
                                                                              overlapsAnotherSpeaker: true))
                    }
                }
            }
        }
        return candidates.mapValues { items in
            Array(items.sorted {
                if $0.overlapsAnotherSpeaker != $1.overlapsAnotherSpeaker { return !$0.overlapsAnotherSpeaker }
                if $0.shortSample != $1.shortSample { return !$0.shortSample }
                if $0.end - $0.start != $1.end - $1.start { return $0.end - $0.start > $1.end - $1.start }
                return $0.start < $1.start
            }.prefix(3))
        }
    }
}
