import Foundation

// Placeholder: the real implementation replaces this file.

public struct ShapeExample: Codable, Hashable, Sendable {
    public var points: [Point2]
}

public struct ShapeTemplate: Codable, Hashable, Sendable {
    public var examples: [ShapeExample]
    public var threshold: Double
}
