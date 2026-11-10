import Foundation

/// One line of a landmark recording: what the camera saw, as landmarks only (never images).
/// Recordings of real gestures are the fixtures every platform's implementation is tested on.
public enum RecordedFrame: Codable, Sendable {
    case hands(HandFrame)
    case face(FaceFrame)

    public var time: Double {
        switch self {
        case .hands(let frame): frame.time
        case .face(let frame): frame.time
        }
    }

    private enum CodingKeys: String, CodingKey {
        case hands, face
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let frame = try values.decodeIfPresent(HandFrame.self, forKey: .hands) {
            self = .hands(frame)
        } else {
            self = .face(try values.decode(FaceFrame.self, forKey: .face))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hands(let frame): try values.encode(frame, forKey: .hands)
        case .face(let frame): try values.encode(frame, forKey: .face)
        }
    }
}

/// A recording is a text file with one JSON object per line, in time order.
public enum Recording {
    public static func encodeLine(_ frame: RecordedFrame) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(frame), as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> [RecordedFrame] {
        let decoder = JSONDecoder()
        return try text.split(whereSeparator: \.isNewline).map { line in
            try decoder.decode(RecordedFrame.self, from: Data(line.utf8))
        }
    }

    public static func load(_ url: URL) throws -> [RecordedFrame] {
        try decode(String(decoding: Data(contentsOf: url), as: UTF8.self))
    }
}
