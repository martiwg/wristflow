import Foundation

/// What a calibration run measured on one person. Values left nil keep their factory setting.
public struct PersonalCalibration: Codable, Equatable, Sendable {
    /// Thresholds for reading hand shapes, fitted to this person's fingers.
    public var profile: PoseProfile
    /// Palm size, in face heights, from which this person's hand counts as held out.
    public var presentRatio: Double?
    /// Palm size, in face heights, below which this person's hand counts as back by the head.
    public var withdrawRatio: Double?
    /// How far this person's fingertips must travel for a swipe, in palm sizes.
    public var swipeTravel: Double?
    public var createdAt: Date
    /// A few of this person's own hands for each built-in pose, by `Trigger.key`, to compare
    /// newly recorded shapes with.
    public var references: [String: [Hand]]

    public init(
        profile: PoseProfile = .factory, presentRatio: Double? = nil, withdrawRatio: Double? = nil,
        swipeTravel: Double? = nil, createdAt: Date = Date(), references: [String: [Hand]] = [:]
    ) {
        self.profile = profile
        self.presentRatio = presentRatio
        self.withdrawRatio = withdrawRatio
        self.swipeTravel = swipeTravel
        self.createdAt = createdAt
        self.references = references
    }
}
