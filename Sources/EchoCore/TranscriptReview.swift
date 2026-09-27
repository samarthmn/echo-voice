import Foundation

public enum TimingSource: String, Codable, Sendable { case nativeWord, tokenEmission, passage }
public struct TranscriptWord: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var text: String
    /// UTF-16 offsets into its parent segment's displayed text, matching NSRange.
    public var location: Int
    public var length: Int
    public var start: Double
    public var end: Double?
    public var source: TimingSource
    public var derived: Bool
    public var probability: Double?
    public init(id: String, text: String, location: Int, length: Int, start: Double, end: Double?, source: TimingSource, derived: Bool = false, probability: Double? = nil) {
        self.id=id; self.text=text; self.location=location; self.length=length; self.start=start; self.end=end; self.source=source; self.derived=derived; self.probability=probability
    }
    public var range: NSRange { NSRange(location: location, length: length) }
    public func valid(in text: String, start: Double, end: Double) -> Bool {
        location >= 0 && length > 0 && location <= (text as NSString).length && length <= (text as NSString).length-location && self.start.isFinite && self.start >= start && self.start <= end && (self.end == nil || (self.end!.isFinite && self.end! > self.start && self.end! <= end))
    }
}
public struct RecognitionEvidence: Codable, Sendable, Equatable {
    public var originalText: String
    public var confidence: [String: Double]
    public var vocabularyEntryIDs: [String]
    /// Original audio coverage, before reconciliation changes visible passage bounds.
    /// Legacy records have no reliable provenance bounds.
    public var sourceStart: Double?
    public var sourceEnd: Double?
    public init(originalText: String, confidence: [String: Double] = [:], vocabularyEntryIDs: [String] = [], sourceStart: Double? = nil, sourceEnd: Double? = nil) {
        self.originalText=originalText; self.confidence=confidence; self.vocabularyEntryIDs=vocabularyEntryIDs
        self.sourceStart=sourceStart; self.sourceEnd=sourceEnd
    }
    public func mayContainAudio(start: Double, end: Double) -> Bool {
        guard let sourceStart, let sourceEnd, sourceStart.isFinite, sourceEnd.isFinite,
              sourceStart >= 0, sourceEnd > sourceStart else { return true }
        return sourceStart < end && sourceEnd > start
    }
}
public struct TranscriptVersion: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case building, ready, failed, cancelled }
    public var id: String
    public var meetingID: String
    public var createdAt: Date
    public var status: Status
    public var configuration: ProcessingConfiguration?
    public var audioFingerprint: String
    public init(id: String = UUID().uuidString, meetingID: String, createdAt: Date = Date(), status: Status = .building, configuration: ProcessingConfiguration?, audioFingerprint: String) {
        self.id=id; self.meetingID=meetingID; self.createdAt=createdAt; self.status=status; self.configuration=configuration; self.audioFingerprint=audioFingerprint
    }
}
public struct TranscriptAnnotation: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable { case highlight, bookmark }
    public var id: String
    public var meetingID: String
    public var kind: Kind
    public var transcriptVersionID: String?
    public var segmentID: String?
    public var location: Int?
    public var length: Int?
    public var quote: String?
    public var track: AudioTrack?
    public var startTime: Double
    public var endTime: Double?
    public var label: String?
    public var createdAt: Date
    public init(id: String = UUID().uuidString, meetingID: String, kind: Kind, transcriptVersionID: String? = nil, segmentID: String? = nil, location: Int? = nil, length: Int? = nil, quote: String? = nil, track: AudioTrack? = nil, startTime: Double, endTime: Double? = nil, label: String? = nil, createdAt: Date = Date()) {
        self.id=id; self.meetingID=meetingID; self.kind=kind; self.transcriptVersionID=transcriptVersionID; self.segmentID=segmentID; self.location=location; self.length=length; self.quote=quote; self.track=track; self.startTime=startTime; self.endTime=endTime; self.label=label; self.createdAt=createdAt
    }
}
public enum TranscriptTiming {
    public static func activeWords(in segment: TranscriptSegment, at time: Double) -> [TranscriptWord] {
        guard time >= segment.startTime, time < segment.endTime else { return [] }
        let words=(segment.words ?? []).filter { $0.valid(in: segment.text, start: segment.startTime, end: segment.endTime) }
        return words.enumerated().compactMap { index, word in
            let stop=word.end ?? (index+1 < words.count ? words[index+1].start : min(segment.endTime, word.start+1))
            return time >= word.start && time < stop ? word : nil
        }
    }
    public static func preservingUnchangedWords(_ words: [TranscriptWord], old: String, new: String) -> [TranscriptWord] {
        // Unique lexical correspondence only. Never interpolate edited word timing.
        let expression=try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
        let ns=new as NSString
        let matches=expression.matches(in:new,range:NSRange(location:0,length:ns.length))
        var last = -1
        return words.compactMap { word in
            let lexical=word.text.trimmingCharacters(in:.punctuationCharacters).lowercased()
            let candidates=matches.filter { ns.substring(with:$0.range).lowercased()==lexical }
            guard candidates.count==1, let found=candidates.first, found.range.location > last,
                  words.filter({ $0.text.trimmingCharacters(in:.punctuationCharacters).lowercased()==lexical }).count==1 else { return nil }
            last=found.range.location
            var copy=word; copy.text=ns.substring(with:found.range);copy.location=found.range.location;copy.length=found.range.length;return copy
        }
    }
}

/// Binary search plus a prefix maximum supports overlapping tracks without a full scan.
public struct TranscriptIntervalIndex: Sendable {
    private let segments: [TranscriptSegment]
    private let maximumEnds: [Double]
    public init(_ segments: [TranscriptSegment]) {
        self.segments = segments.sorted { $0.startTime < $1.startTime }
        var end = -Double.infinity
        self.maximumEnds = self.segments.map { end = max(end, $0.endTime); return end }
    }
    public func active(at time: Double) -> [TranscriptSegment] {
        guard time.isFinite else { return [] }
        var low = 0, high = segments.count
        while low < high { let mid = (low + high) / 2; if segments[mid].startTime <= time { low = mid + 1 } else { high = mid } }
        var index = low - 1, result: [TranscriptSegment] = []
        while index >= 0 && maximumEnds[index] > time {
            if segments[index].endTime > time { result.append(segments[index]) }
            index -= 1
        }
        return result.reversed()
    }
}
