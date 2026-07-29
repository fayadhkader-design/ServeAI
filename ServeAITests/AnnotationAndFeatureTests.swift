import CryptoKit
import XCTest
@testable import ServeAI

final class AnnotationAndFeatureTests: XCTestCase {
    func testFrozenCoachRubricMatchesNativePinnedDigest() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appending(path: "Training/coach_rubric_v1.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(digest, CoachAnnotationRubric.sha256)
        XCTAssertEqual(CoachAnnotationRubric.currentBinding.identifier, "serveai.single-serve-observational")
        XCTAssertEqual(CoachAnnotationRubric.techniques.map(\.label), CoachTechniqueLabel.allCases)
    }

    func testLegacyTossConsistencyDecodesButExportsSingleServePlacement() throws {
        let legacy = try JSONDecoder().decode(CoachTechniqueLabel.self, from: Data("\"tossConsistency\"".utf8))
        let exported = try JSONEncoder().encode(legacy)

        XCTAssertEqual(legacy, .tossPlacement)
        XCTAssertEqual(String(decoding: exported, as: UTF8.self), "\"tossPlacement\"")
    }

    func testAnnotationDraftDoesNotGrantTrainingConsent() throws {
        let package = CoachServeAnnotationPackage.draft(for: MockData.analysis())
        let data = try CoachAnnotationExporter().data(for: package)
        let decoded = try JSONDecoder.iso8601.decode(CoachServeAnnotationPackage.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, CoachServeAnnotationPackage.currentSchemaVersion)
        XCTAssertEqual(decoded.rubric, CoachAnnotationRubric.currentBinding)
        XCTAssertTrue(decoded.isVideoUsable)
        XCTAssertNil(decoded.unusableReason)
        XCTAssertNil(decoded.participantPseudonym)
        XCTAssertFalse(decoded.consent.allowsResearchAndModelTraining)
        XCTAssertFalse(decoded.consent.isActive)
        XCTAssertNil(decoded.consent.revokedAt)
        XCTAssertTrue(decoded.phaseBoundaries.isEmpty)
        XCTAssertFalse(decoded.modelReport.phaseScores.isEmpty)
    }

    func testConsentRevocationPreservesAnAuditTrailAndDisablesEligibility() {
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let revokedAt = grantedAt.addingTimeInterval(3_600)
        let granted = DatasetConsent.granted(at: grantedAt)
        let revoked = granted.revoked(at: revokedAt)

        XCTAssertTrue(granted.isActive)
        XCTAssertFalse(revoked.isActive)
        XCTAssertEqual(revoked.recordedAt, grantedAt)
        XCTAssertEqual(revoked.revokedAt, revokedAt)
        XCTAssertEqual(revoked.decisionHistory?.map(\.kind), [.granted, .revoked])
    }

    func testLegacyActiveConsentIsUpgradedToAuditableSchema() {
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = DatasetConsent(
            consentVersion: DatasetConsent.currentVersion,
            allowsResearchAndModelTraining: true,
            recordedAt: grantedAt
        )

        let upgraded = legacy.upgradedForCurrentSchema()

        XCTAssertTrue(upgraded.isActive)
        XCTAssertNotNil(upgraded.consentRecordID)
        XCTAssertEqual(upgraded.decisionHistory?.map(\.kind), [.granted])
        XCTAssertEqual(upgraded.recordedAt, grantedAt)
    }

    func testMultipleCoachSessionsRoundTripWithoutOverwritingEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "serveai-annotation-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalCoachAnnotationStore(directoryURL: directory)
        let first = CoachServeAnnotationPackage.draft(for: MockData.analysis())
        let second = packageCopy(
            first,
            annotationID: UUID(),
            createdAt: first.createdAt.addingTimeInterval(60),
            coachID: "coach-b"
        )

        try await store.save(first)
        try await store.save(second)
        let sessions = try await store.listSessions(analysisID: first.analysisID)
        let restoredFirst = try await store.load(
            analysisID: first.analysisID,
            annotationID: first.annotationID
        )
        let restoredSecond = try await store.load(
            analysisID: second.analysisID,
            annotationID: second.annotationID
        )

        XCTAssertEqual(sessions.map(\.annotationID), [second.annotationID, first.annotationID])
        XCTAssertEqual(restoredFirst?.annotationID, first.annotationID)
        XCTAssertEqual(restoredSecond?.annotatorPseudonym, "coach-b")
        XCTAssertEqual(restoredSecond?.schemaVersion, CoachServeAnnotationPackage.currentSchemaVersion)

        try await store.delete(analysisID: first.analysisID, annotationID: first.annotationID)
        let remaining = try await store.listSessions(analysisID: first.analysisID)
        XCTAssertEqual(remaining.map(\.annotationID), [second.annotationID])

        try await store.deleteAll(analysisID: first.analysisID)
        let deleted = try await store.listSessions(analysisID: first.analysisID)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testLegacySingleDraftMigratesIntoAnnotationSessionDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "serveai-legacy-annotation-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LocalCoachAnnotationStore(directoryURL: directory)
        let package = CoachServeAnnotationPackage.draft(for: MockData.analysis())
        let legacyURL = directory
            .appending(path: "analysis-\(package.analysisID.uuidString.lowercased())")
            .appendingPathExtension("json")
        try CoachAnnotationExporter().data(for: package).write(to: legacyURL)

        let sessions = try await store.listSessions(analysisID: package.analysisID)

        XCTAssertEqual(sessions.map(\.annotationID), [package.annotationID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        let migrated = try await store.load(
            analysisID: package.analysisID,
            annotationID: package.annotationID
        )
        XCTAssertEqual(migrated?.analysisID, package.analysisID)
    }

    func testInvisiblePhaseExportsWithoutFabricatedTiming() throws {
        let analysis = MockData.analysis()
        let draft = CoachServeAnnotationPackage.draft(for: analysis)
        let package = CoachServeAnnotationPackage(
            schemaVersion: CoachServeAnnotationPackage.currentSchemaVersion,
            rubric: CoachAnnotationRubric.currentBinding,
            annotationID: draft.annotationID,
            analysisID: draft.analysisID,
            createdAt: draft.createdAt,
            videoFilename: draft.videoFilename,
            cameraAngle: draft.cameraAngle,
            skillLevel: draft.skillLevel,
            collectionMetadata: nil,
            modelFeatureEvidence: nil,
            labelingTask: nil,
            participantPseudonym: "player-03",
            annotatorPseudonym: "coach-07",
            isVideoUsable: true,
            unusableReason: nil,
            modelReport: draft.modelReport,
            phaseBoundaries: [
                .init(phase: .pronation, startTime: nil, endTime: nil, isVisible: false)
            ],
            techniqueRatings: [],
            topPriority: .legDriveTiming,
            coachNotes: nil,
            consent: .notGranted
        )

        let data = try CoachAnnotationExporter().data(for: package)
        let decoded = try JSONDecoder.iso8601.decode(CoachServeAnnotationPackage.self, from: data)
        let exportedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportedPhases = try XCTUnwrap(exportedObject["phaseBoundaries"] as? [[String: Any]])

        XCTAssertEqual(decoded.phaseBoundaries.first?.phase, .pronation)
        XCTAssertFalse(decoded.phaseBoundaries.first?.isVisible ?? true)
        XCTAssertNil(decoded.phaseBoundaries.first?.startTime)
        XCTAssertNil(decoded.phaseBoundaries.first?.endTime)
        XCTAssertEqual(exportedPhases.first?["phase"] as? String, "pronation")
    }

    func testLegacyNumericPhaseBoundaryStillDecodes() throws {
        let data = Data("{\"phase\":9,\"startTime\":0.8,\"endTime\":1.1,\"isVisible\":true}".utf8)
        let decoded = try JSONDecoder().decode(CoachPhaseBoundaryAnnotation.self, from: data)

        XCTAssertEqual(decoded.phase, .landingFollowThrough)
        XCTAssertEqual(decoded.startTime, 0.8)
        XCTAssertEqual(decoded.endTime, 1.1)
        XCTAssertTrue(decoded.isVisible)
    }

    func testFeatureEncoderProducesFixedJointSchema() {
        let frame = PoseFrame(
            timestamp: 0.25,
            joints: [
                .root: .init(x: 0.5, y: 0.4, confidence: 0.9),
                .nose: .init(x: 0.5, y: 0.8, confidence: 0.85)
            ],
            bodyConfidence: 0.88
        )

        let features = ServeModelFeatureEncoder().encode(frames: [frame], duration: 5, cameraAngle: .side)

        XCTAssertEqual(features.schemaVersion, 2)
        XCTAssertEqual(features.frames.first?.joints.count, BodyJoint.allCases.count)
        XCTAssertEqual(features.frames.first?.feature(for: .root)?.x ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(features.frames.first?.feature(for: .leftAnkle)?.isPresent, false)
    }

    func testCompleteFeatureEvidenceRequiresOrderedFramesAndVideoFingerprint() {
        let frames = (0..<18).map { index in
            PoseFrame(
                timestamp: Double(index) * 0.1,
                joints: Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { joint in
                    (joint, PosePoint(x: 0.5, y: 0.5 + Double(index) * 0.001, confidence: 0.9))
                }),
                bodyConfidence: 0.9
            )
        }
        let sequence = ServeModelFeatureEncoder().encode(frames: frames, duration: 3, cameraAngle: .rear)
        let evidence = ServeModelFeatureEvidence(
            sequence: sequence,
            provenance: ServeModelFeatureProvenance(
                poseDetectorIdentifier: "test-detector",
                poseDetectorVersion: "1",
                videoSHA256: String(repeating: "a", count: 64),
                requestedSamplesPerSecond: 15,
                smoothingWindow: 5,
                sampledFrameCount: 18,
                detectedFrameCount: 18
            )
        )

        XCTAssertTrue(sequence.isCompleteForDataset)
        XCTAssertTrue(evidence.isCompleteForDataset)
    }

    func testStreamingVideoHasherMatchesKnownSHA256() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "serveai-hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        let digest = try await SHA256VideoContentHasher().sha256(of: url)

        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSignedCoachTaskRoundTripsAndPreservesEvidenceBinding() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(slotID: "slot-001", participantPseudonym: "participant-001"),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )
        let data = try CoachLabelingTaskService().encode(manifest)

        let decoded = try CoachLabelingTaskService().decodeAndVerify(data)

        XCTAssertEqual(decoded.analysisID, fixture.analysis.id)
        XCTAssertEqual(decoded.payload.sourceVideoSHA256, fixture.digest)
        XCTAssertEqual(
            decoded.payload.analysis.modelFeatureEvidence.provenance.videoSHA256,
            fixture.analysis.modelFeatureEvidence?.provenance.videoSHA256
        )
        XCTAssertEqual(
            decoded.payload.analysis.modelFeatureEvidence.sequence.frames,
            fixture.analysis.modelFeatureEvidence?.sequence.frames
        )
        XCTAssertEqual(decoded.payload.analysis.cameraAngle, fixture.analysis.cameraAngle)
        XCTAssertEqual(decoded.payload.capturePlanAssignment.slotID, "slot-001")
        XCTAssertEqual(decoded.payload.capturePlanAssignment.participantPseudonym, "participant-001")
    }

    func testResearchCaptureTaskContainsEvidenceButNoCoachingOutputs() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let research = ServeAnalysis(
            id: fixture.analysis.id,
            createdAt: fixture.analysis.createdAt,
            overallScore: 0,
            skillLevel: fixture.analysis.skillLevel,
            cameraAngle: fixture.analysis.cameraAngle,
            source: .researchCapture,
            videoURL: fixture.videoURL,
            phaseScores: [],
            technicalMetrics: [],
            insights: [],
            drills: [],
            limitations: fixture.analysis.limitations,
            confidence: fixture.analysis.confidence,
            videoMetadata: fixture.analysis.videoMetadata,
            modelFeatureEvidence: fixture.analysis.modelFeatureEvidence
        )

        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: research,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(
                slotID: "slot-001",
                participantPseudonym: "participant-001"
            ),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )

        XCTAssertEqual(manifest.payload.analysis.source, .researchCapture)
        XCTAssertEqual(manifest.payload.analysis.overallScore, 0)
        XCTAssertTrue(manifest.payload.analysis.phaseScores.isEmpty)
        XCTAssertTrue(manifest.payload.analysis.technicalMetrics.isEmpty)
        XCTAssertTrue(manifest.payload.analysis.insights.isEmpty)
        XCTAssertTrue(manifest.payload.analysis.drills.isEmpty)
        XCTAssertNoThrow(try CoachLabelingTaskCrypto.verify(manifest))
    }

    func testResearchCaptureTaskRejectsAnyCoachingOutput() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let invalidResearch = ServeAnalysis(
            id: fixture.analysis.id,
            createdAt: fixture.analysis.createdAt,
            overallScore: fixture.analysis.overallScore,
            skillLevel: fixture.analysis.skillLevel,
            cameraAngle: fixture.analysis.cameraAngle,
            source: .researchCapture,
            videoURL: fixture.videoURL,
            phaseScores: fixture.analysis.phaseScores,
            technicalMetrics: fixture.analysis.technicalMetrics,
            insights: fixture.analysis.insights,
            drills: fixture.analysis.drills,
            limitations: fixture.analysis.limitations,
            confidence: fixture.analysis.confidence,
            videoMetadata: fixture.analysis.videoMetadata,
            modelFeatureEvidence: fixture.analysis.modelFeatureEvidence
        )

        XCTAssertThrowsError(try CoachLabelingTaskCrypto.makeManifest(
            analysis: invalidResearch,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(
                slotID: "slot-001",
                participantPseudonym: "participant-001"
            ),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("cannot contain a coaching score"))
        }
    }

    func testSignedCoachTaskPreservesStructuredModelAndAppTrace() throws {
        let trace = AnalysisModelTrace(
            modelIdentifier: "serveai.release-candidate",
            modelVersion: "1.0.0",
            modelArtifactSHA256: String(repeating: "a", count: 64),
            validatedReleaseVerified: true,
            appBuildIdentifier: "com.serveai.app/1.0(42)"
        )
        let fixture = makeCoachTaskFixture(modelTrace: trace)
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(slotID: "slot-001", participantPseudonym: "participant-001"),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )

        let decoded = try CoachLabelingTaskService().decodeAndVerify(
            CoachLabelingTaskService().encode(manifest)
        )

        XCTAssertEqual(decoded.payload.analysis.modelTrace, trace)
    }

    func testTamperedCoachTaskIsRejected() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(slotID: "slot-001", participantPseudonym: "participant-001"),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: CoachLabelingTaskService().encode(manifest)) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["coordinatorPseudonym"] = "coordinator-tampered"
        object["payload"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try CoachLabelingTaskService().decodeAndVerify(tampered)) { error in
            XCTAssertEqual(error as? CoachLabelingTaskError, .invalidSignature)
        }
    }

    func testCoachTaskRejectsWrongVideoBeforeCopying() async throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let wrongURL = FileManager.default.temporaryDirectory.appending(path: "serveai-wrong-video-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: wrongURL) }
        try Data("different-video".utf8).write(to: wrongURL)
        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(slotID: "slot-001", participantPseudonym: "participant-001"),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )

        do {
            _ = try await CoachLabelingTaskService().importVerifiedVideo(wrongURL, for: manifest)
            XCTFail("Expected a wrong-video rejection")
        } catch {
            XCTAssertEqual(error as? CoachLabelingTaskError, .wrongVideo)
        }
    }

    func testCoachTaskDuplicateAnalysisIsRejectedBeforeVideoSelection() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }
        let manifest = try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(slotID: "slot-001", participantPseudonym: "participant-001"),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )
        let data = try CoachLabelingTaskService().encode(manifest)

        XCTAssertThrowsError(
            try CoachLabelingTaskService().decodeAndVerify(data, existingAnalysisIDs: [fixture.analysis.id])
        ) { error in
            XCTAssertEqual(error as? CoachLabelingTaskError, .duplicateAnalysis)
        }
    }

    func testInvisibleTechniqueDoesNotExportDefaultRating() {
        let hidden = CoachTechniqueAnnotation(
            label: .tossPlacement,
            rating: 3,
            isVisible: false
        )

        XCTAssertNil(hidden.rating)
    }

    func testCapturePlanAssignmentRejectsParticipantLeakage() throws {
        XCTAssertEqual(
            try CapturePlanAssignment.make(
                slotID: "slot-006",
                participantPseudonym: "participant-002"
            ).plan,
            CapturePlanAssignment.currentPlan
        )
        XCTAssertThrowsError(try CapturePlanAssignment.make(
            slotID: "slot-006",
            participantPseudonym: "participant-001"
        ))
    }

    func testNativeCapturePlanProfilesMatchFrozenBoundarySlots() throws {
        let first = try XCTUnwrap(CapturePlanSlot(number: 1))
        XCTAssertEqual(first.slotID, "slot-001")
        XCTAssertEqual(first.participantPseudonym, "participant-001")
        XCTAssertEqual(first.split, "train")
        XCTAssertEqual(first.cameraAngle, .side)
        XCTAssertEqual(first.skillLevel, .beginner)
        XCTAssertEqual(first.resolution, .hd1080)
        XCTAssertEqual(first.frameRate, .fps60)
        XCTAssertEqual(first.recordingIssueTags, [.poorFraming])

        let validation = try XCTUnwrap(CapturePlanSlot(number: 181))
        XCTAssertEqual(validation.participantPseudonym, "participant-037")
        XCTAssertEqual(validation.split, "validation")
        XCTAssertTrue(validation.recordingIssueTags.isEmpty)

        let test = try XCTUnwrap(CapturePlanSlot(number: 300))
        XCTAssertEqual(test.participantPseudonym, "participant-060")
        XCTAssertEqual(test.split, "test")
        XCTAssertEqual(test.cameraAngle, .rear)
        XCTAssertEqual(test.skillLevel, .competitive)
        XCTAssertEqual(test.dominantHand, .left)
        XCTAssertEqual(test.resolution, .ultraHD4K)
        XCTAssertEqual(test.frameRate, .fps120)
        XCTAssertNil(CapturePlanSlot(number: 301))
    }

    func testSignedTaskRejectsObservedCaptureCohortSubstitution() throws {
        let fixture = makeCoachTaskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.videoURL) }

        XCTAssertThrowsError(try CoachLabelingTaskCrypto.makeManifest(
            analysis: fixture.analysis,
            coordinatorPseudonym: "coordinator-a",
            capturePlanAssignment: try CapturePlanAssignment.make(
                slotID: "slot-002",
                participantPseudonym: "participant-001"
            ),
            sourceVideoSHA256: fixture.digest,
            privateKey: P256.Signing.PrivateKey()
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("rear view"))
        }
    }

    func testCollectionMetadataRequiresEveryReleaseCohort() {
        let incomplete = ServeCollectionMetadata(
            dominantHand: .unknown,
            environment: .outdoor,
            lighting: .evenDaylight,
            sourceDeviceCategory: .iPhone,
            sourceDeviceModel: "iPhone 15 Pro",
            subjectContrast: .typical,
            recordingIssueTags: [],
            videoWidth: 1920,
            videoHeight: 1080,
            nominalFrameRate: 60
        )
        let complete = ServeCollectionMetadata(
            dominantHand: .left,
            environment: .indoor,
            lighting: .indoorBright,
            sourceDeviceCategory: .iPhone,
            sourceDeviceModel: "iPhone 14",
            subjectContrast: .low,
            recordingIssueTags: [.occlusion],
            videoWidth: 1920,
            videoHeight: 1080,
            nominalFrameRate: 60
        )

        XCTAssertFalse(incomplete.isCompleteForDataset)
        XCTAssertTrue(complete.isCompleteForDataset)
    }
}

private func makeCoachTaskFixture(
    modelTrace: AnalysisModelTrace? = nil
) -> (analysis: ServeAnalysis, videoURL: URL, digest: String) {
    let videoURL = FileManager.default.temporaryDirectory.appending(path: "serveai-task-video-\(UUID().uuidString).mov")
    try! Data("abc".utf8).write(to: videoURL)
    let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    let frames = (0..<18).map { index in
        PoseFrame(
            timestamp: Double(index) * 0.1,
            joints: Dictionary(uniqueKeysWithValues: BodyJoint.allCases.map { joint in
                (joint, PosePoint(x: 0.5, y: 0.5 + Double(index) * 0.001, confidence: 0.9))
            }),
            bodyConfidence: 0.9
        )
    }
    let sequence = ServeModelFeatureEncoder().encode(frames: frames, duration: 3, cameraAngle: .side)
    let evidence = ServeModelFeatureEvidence(
        sequence: sequence,
        provenance: ServeModelFeatureProvenance(
            poseDetectorIdentifier: "test-detector",
            poseDetectorVersion: "1",
            videoSHA256: digest,
            requestedSamplesPerSecond: 15,
            smoothingWindow: 5,
            sampledFrameCount: 18,
            detectedFrameCount: 18
        )
    )
    let base = MockData.analysis(videoURL: videoURL)
    let analysis = ServeAnalysis(
        id: base.id,
        createdAt: base.createdAt,
        overallScore: base.overallScore,
        skillLevel: .beginner,
        cameraAngle: .side,
        source: .vision,
        videoURL: videoURL,
        phaseScores: base.phaseScores,
        technicalMetrics: base.technicalMetrics,
        insights: base.insights,
        drills: base.drills,
        limitations: base.limitations,
        confidence: base.confidence,
        videoMetadata: VideoMetadata(duration: 3, width: 1920, height: 1080, nominalFrameRate: 60, usableFrames: 18, sampledFrames: 18),
        modelFeatureEvidence: evidence,
        modelTrace: modelTrace
    )
    return (analysis, videoURL, digest)
}

private func packageCopy(
    _ package: CoachServeAnnotationPackage,
    annotationID: UUID,
    createdAt: Date,
    coachID: String?
) -> CoachServeAnnotationPackage {
    CoachServeAnnotationPackage(
        schemaVersion: package.schemaVersion,
        rubric: package.rubric,
        annotationID: annotationID,
        analysisID: package.analysisID,
        createdAt: createdAt,
        videoFilename: package.videoFilename,
        cameraAngle: package.cameraAngle,
        skillLevel: package.skillLevel,
        collectionMetadata: package.collectionMetadata,
        modelFeatureEvidence: package.modelFeatureEvidence,
        labelingTask: package.labelingTask,
        participantPseudonym: package.participantPseudonym,
        annotatorPseudonym: coachID,
        isVideoUsable: package.isVideoUsable,
        unusableReason: package.unusableReason,
        modelReport: package.modelReport,
        phaseBoundaries: package.phaseBoundaries,
        techniqueRatings: package.techniqueRatings,
        topPriority: package.topPriority,
        coachNotes: package.coachNotes,
        consent: package.consent
    )
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
