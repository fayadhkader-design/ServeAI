import Foundation

enum DrillLibrary {
    static let all: [RecommendedDrill] = [
        drill("toss-catch", "Toss-and-catch drill", "Build a calm, repeatable release.", ["Set up without a racket.", "Toss to full extension and catch above eye level without moving your feet."], "2 sets of 10", .beginner, [.ballToss], ["Chasing the ball", "Flicking the wrist"], nil),
        drill("toss-target", "Toss landing-target drill", "Move the toss slightly into the court.", ["Place a racket-length target just inside the baseline.", "Toss without swinging and let the ball land on the target."], "20 tosses", .beginner, [.ballToss, .contactPosition], ["Releasing too low", "Leaning to force placement"], nil),
        drill("trophy-freeze", "Trophy-position freeze", "Feel shoulder tilt, elbow spacing, and balance.", ["Move slowly to trophy position.", "Hold for three seconds, check balance, then reset."], "3 sets of 6", .beginner, [.loading, .trophyPosition], ["Collapsing the tossing arm", "Arching the lower back"], "Stop if the shoulder or lower back feels pinched."),
        drill("shadow-serve", "Shadow serve", "Rehearse sequence without ball-flight pressure.", ["Serve at 50% speed without a ball.", "Finish balanced with eyes up."], "2 sets of 8", .beginner, [.startingStance, .landingFollowThrough], ["Rushing from setup", "Forcing maximum speed"], "Keep ample space around the racket path."),
        drill("knee-drive", "Knee-drive drill", "Connect knee extension to upward reach.", ["Pause at the bottom of the load.", "Drive upward while reaching the hitting hand high."], "3 sets of 6", .intermediate, [.loading, .legDrive, .upwardAcceleration], ["Jumping sideways", "Opening the chest too early"], "Land softly and stop if the knee is painful."),
        drill("serve-knees", "Serve from knees", "Isolate trunk rotation and relaxed arm action.", ["Kneel behind the baseline on a pad.", "Hit gentle service-box serves with a loose arm."], "2 sets of 8", .intermediate, [.trophyPosition, .racketDrop, .pronation], ["Muscling the ball", "Overarching the back"], "Use a thick pad and skip this drill with knee discomfort."),
        drill("half-serve", "Half-serve progression", "Blend a compact load into clean contact.", ["Begin in trophy position.", "Serve at 50%, then gradually add the setup while keeping the same rhythm."], "3 rounds of 5", .intermediate, [.trophyPosition, .contactPosition], ["Adding speed too soon", "Losing the upward swing path"], nil),
        drill("racket-drop-sock", "Racket-drop sock drill", "Encourage a loose, continuous drop and acceleration.", ["Place two tennis balls in a long sock and hold the end.", "Trace a smooth serve loop without letting the sock go slack."], "45 seconds × 3", .intermediate, [.racketDrop, .upwardAcceleration], ["Stopping behind the back", "Snapping abruptly"], "Use a clear area and keep the motion controlled."),
        drill("pronation-shadow", "Pronation shadow drill", "Feel forearm rotation after upward extension.", ["Shadow the swing slowly with the racket edge leading upward.", "Allow the strings to turn outward after the imagined contact."], "2 sets of 10", .intermediate, [.contactPosition, .pronation], ["Turning the wrist before contact", "Forcing a wrist snap"], "Move slowly and pain-free; pronation should not feel forced."),
        drill("contact-height", "Contact-height drill", "Train full arm extension and an upward strike.", ["Hang a safe visual target at comfortable maximum reach.", "Shadow the serve and touch the target with the hand, not the racket."], "3 sets of 8", .beginner, [.upwardAcceleration, .contactPosition], ["Shrugging the shoulder", "Dropping the head early"], "Use a soft target and never jump under a hard overhead object."),
        drill("hold-balance", "Serve-and-hold-balance drill", "Improve landing control and recovery posture.", ["Serve at 60% pace.", "Freeze the finish for three seconds before returning to ready position."], "2 baskets of 8", .beginner, [.landingFollowThrough], ["Falling sideways", "Stepping away immediately"], nil),
        drill("continuous-motion", "Continuous service-motion drill", "Remove pauses and connect the kinetic chain.", ["Make three slow continuous shadow serves without stopping.", "Keep breathing and preserve the same tempo each repetition."], "5 rounds", .advanced, [.loading, .legDrive, .racketDrop, .landingFollowThrough], ["Accelerating too early", "Losing the toss-arm rhythm"], "Leave a full racket-length of clear space in every direction.")
    ]

    static func drill(id: String) -> RecommendedDrill? { all.first { $0.id == id } }

    private static func drill(
        _ id: String,
        _ name: String,
        _ purpose: String,
        _ instructions: [String],
        _ dosage: String,
        _ difficulty: SkillLevel,
        _ phases: [ServePhaseKind],
        _ mistakes: [String],
        _ safety: String?
    ) -> RecommendedDrill {
        RecommendedDrill(id: id, name: name, purpose: purpose, instructions: instructions, dosage: dosage, difficulty: difficulty, relatedPhases: phases, commonMistakes: mistakes, safetyNote: safety)
    }
}
