import Foundation

struct CoachRubricBinding: Codable, Hashable, Sendable {
    let identifier: String
    let version: String
    let sha256: String
}

struct CoachRatingAnchor: Identifiable, Hashable, Sendable {
    let rating: Int
    let title: String
    let definition: String

    var id: Int { rating }
}

struct CoachTechniqueRubric: Hashable, Sendable {
    let label: CoachTechniqueLabel
    let observe: String
    let requiredVisibility: String
    let doNotInfer: String
}

enum CoachAnnotationRubric {
    static let identifier = "serveai.single-serve-observational"
    static let version = "1.0.0"
    static let sha256 = "5a28ab5084f931116f4056493df1ba39f78b14c852a9f671cfc393cbb2d61741"

    static let currentBinding = CoachRubricBinding(
        identifier: identifier,
        version: version,
        sha256: sha256
    )

    static let scope = "One side- or rear-view serve. Ratings are ordinal 2D observations, not exact biomechanical measurements or injury assessments."
    static let visibilityRule = "Mark not visible unless every named cue can be followed. Never infer a hidden ball, joint, foot, racket, or contact event."
    static let priorityRule = "Choose a visible technique with the lowest rating. Break ties using the clearest actionable issue."

    static let ratingAnchors: [CoachRatingAnchor] = [
        .init(rating: 1, title: "Clear major breakdown", definition: "Criterion is largely absent or materially disrupts the visible sequence."),
        .init(rating: 2, title: "Material limitation", definition: "Part is present, but a clear visible fault substantially limits the sequence."),
        .init(rating: 3, title: "Mixed or adequate", definition: "Criterion is usable, with an observable limitation that does not dominate the motion."),
        .init(rating: 4, title: "Well organized", definition: "Criterion supports the sequence with only a minor observable limitation."),
        .init(rating: 5, title: "Clearly strong", definition: "Criterion is visibly well organized with no material fault apparent in this repetition.")
    ]

    static let techniques: [CoachTechniqueRubric] = [
        .init(
            label: .tossPlacement,
            observe: "Follow the ball from release toward contact and judge whether its path gives reachable space to extend upward without an obvious chase or collapse.",
            requiredVisibility: "Ball through late ascent, tossing hand, head, hitting shoulder, and court-forward direction.",
            doNotInfer: "Do not rate consistency from one serve, exact release angle, spin, or an unseen contact point."
        ),
        .init(
            label: .loadingSequence,
            observe: "Judge whether lower-body flexion and trunk organization build before the upward drive.",
            requiredVisibility: "Hips, both knees, both ankles, trunk, and the loading-to-drive transition.",
            doNotInfer: "Do not estimate force, power, or exact joint angles from 2D video."
        ),
        .init(
            label: .trophyAlignment,
            observe: "At trophy, judge the coordinated organization of trunk, shoulders, tossing arm, and hitting elbow without requiring one cosmetic pose.",
            requiredVisibility: "Trunk, both shoulders, tossing elbow/wrist, and hitting elbow/wrist around trophy.",
            doNotInfer: "Do not rate shoulder-rotation speed, hidden racket orientation, or impose one style on every player."
        ),
        .init(
            label: .legDriveTiming,
            observe: "Judge whether knee extension follows the load and contributes to upward movement before the visible contact window.",
            requiredVisibility: "Both hips, knees, ankles, feet, trunk, and the load-through-drive interval.",
            doNotInfer: "Do not estimate ground force, jump power, or ball speed."
        ),
        .init(
            label: .contactReach,
            observe: "At visible contact, judge apparent upward reach, hitting-arm extension, head stability, and body organization around the ball.",
            requiredVisibility: "Ball at contact, hitting wrist/elbow/shoulder, head, trunk, and front foot.",
            doNotInfer: "If ball-racket contact is not visible, mark not visible; never substitute a wrist proxy or estimate exact angles."
        ),
        .init(
            label: .landingBalance,
            observe: "Judge whether the player lands under control and organizes momentum toward the court through early recovery.",
            requiredVisibility: "Both feet, ankles, knees, hips, and trunk from takeoff through initial stabilization.",
            doNotInfer: "Do not diagnose injury risk or penalize a safe individual style solely for differing from an exemplar."
        )
    ]

    static func technique(for label: CoachTechniqueLabel) -> CoachTechniqueRubric {
        techniques.first { $0.label == label }!
    }

    static func anchor(for rating: Int) -> CoachRatingAnchor {
        ratingAnchors.first { $0.rating == rating } ?? ratingAnchors[2]
    }
}
