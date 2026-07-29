import AVKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct CoachAnnotationView: View {
    @Environment(\.dismiss) private var dismiss

    let analysis: ServeAnalysis
    private let store: any CoachAnnotationPersisting

    @State private var player: AVPlayer?
    @State private var currentTime: TimeInterval = 0
    @State private var isPlaying = false
    @State private var isScrubbing = false
    @State private var selectedPhase = ServePhaseKind.startingStance
    @State private var phaseDrafts: [ServePhaseKind: PhaseBoundaryDraft]
    @State private var techniqueRatings: [CoachTechniqueLabel: Int]
    @State private var visibleTechniques: Set<CoachTechniqueLabel>
    @State private var topPriority: CoachTechniqueLabel?
    @State private var dominantHand = DominantHand.unknown
    @State private var courtEnvironment = CourtEnvironment.unknown
    @State private var lightingCondition = LightingCondition.unknown
    @State private var sourceDeviceCategory = SourceDeviceCategory.unknown
    @State private var sourceDeviceModel = ""
    @State private var subjectContrast = SubjectContrast.unknown
    @State private var recordingIssueTags: Set<RecordingIssueTag> = []
    @State private var participantPseudonym = ""
    @State private var annotatorPseudonym = ""
    @State private var isVideoUsable = true
    @State private var unusableReason = ""
    @State private var coachNotes = ""
    @State private var consent = DatasetConsent.notGranted
    @State private var annotationID: UUID
    @State private var createdAt: Date
    @State private var exportDocument: CoachAnnotationDocument?
    @State private var isExporting = false
    @State private var exportMessage: String?
    @State private var persistenceMessage: String?
    @State private var isLoadingDraft = true
    @State private var isSavingDraft = false
    @State private var isConfirmingRevocation = false
    @State private var savedSessions: [CoachAnnotationSessionDescriptor] = []
    @State private var isShowingSessionPicker = false
    @State private var hasSelectedSession = false
    @State private var isLoadingSession = false
    @State private var sessionSelectionError: String?
    @State private var lockedCoachPseudonym: String?

    private var lockedParticipantPseudonym: String? {
        analysis.coachLabelingTask?.payload.capturePlanAssignment.participantPseudonym
    }

    private var lockedCapturePlanSlot: CapturePlanSlot? {
        analysis.coachLabelingTask?.payload.capturePlanAssignment.slot
    }

    private let timer = Timer.publish(every: 0.10, on: .main, in: .common).autoconnect()

    init(
        analysis: ServeAnalysis,
        store: any CoachAnnotationPersisting = LocalCoachAnnotationStore()
    ) {
        self.analysis = analysis
        self.store = store
        let hasVideo = analysis.videoURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let isResearchFailureSample = analysis.source == .researchCapture
        let captureSlot = analysis.coachLabelingTask?.payload.capturePlanAssignment.slot
        let drafts = Dictionary(uniqueKeysWithValues: ServePhaseKind.allCases.map {
            ($0, PhaseBoundaryDraft(isVisible: hasVideo && !isResearchFailureSample, startTime: nil, endTime: nil))
        })
        let ratings = Dictionary(uniqueKeysWithValues: CoachTechniqueLabel.allCases.map { ($0, 3) })
        _phaseDrafts = State(initialValue: drafts)
        _techniqueRatings = State(initialValue: ratings)
        _visibleTechniques = State(initialValue: [])
        _isVideoUsable = State(initialValue: hasVideo && !isResearchFailureSample)
        _unusableReason = State(
            initialValue: isResearchFailureSample
                ? "Recording failed the ServeAI input-quality gate"
                : (hasVideo ? "" : "Original video unavailable")
        )
        _dominantHand = State(initialValue: captureSlot?.dominantHand ?? .unknown)
        _courtEnvironment = State(initialValue: captureSlot?.environment ?? .unknown)
        _lightingCondition = State(initialValue: captureSlot?.lighting ?? .unknown)
        _sourceDeviceCategory = State(initialValue: captureSlot == nil ? .unknown : .iPhone)
        _sourceDeviceModel = State(initialValue: captureSlot?.sourceDeviceModel ?? "")
        _subjectContrast = State(initialValue: captureSlot?.subjectContrast ?? .unknown)
        _recordingIssueTags = State(initialValue: Set(captureSlot?.recordingIssueTags ?? []))
        _participantPseudonym = State(
            initialValue: analysis.coachLabelingTask?.payload.capturePlanAssignment.participantPseudonym ?? ""
        )
        _annotationID = State(initialValue: UUID())
        _createdAt = State(initialValue: .now)
        if let url = analysis.videoURL, hasVideo {
            _player = State(initialValue: AVPlayer(url: url))
        } else {
            _player = State(initialValue: nil)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                calibrationNotice
                videoEditor
                phaseSection
                techniqueSection
                collectionSection
                reviewSection
                exportSection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .allowsHitTesting(hasSelectedSession)
        .accessibilityHidden(!hasSelectedSession)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .task { await prepareSessionSelection() }
        .onReceive(timer) { _ in updatePlaybackTime() }
        .onDisappear {
            player?.pause()
            guard !isLoadingDraft, hasSelectedSession else { return }
            let package = annotationPackage
            Task { try? await store.save(package) }
        }
        .sheet(isPresented: $isShowingSessionPicker) {
            CoachAnnotationSessionPicker(
                sessions: savedSessions,
                isLoading: isLoadingSession,
                errorMessage: sessionSelectionError,
                onStartNew: { coachID in beginNewSession(coachID: coachID) },
                onResume: { session in
                    Task { await resumeSession(session) }
                },
                onCancel: {
                    isShowingSessionPicker = false
                    dismiss()
                }
            )
            .interactiveDismissDisabled()
        }
        .confirmationDialog(
            "Record a consent withdrawal?",
            isPresented: $isConfirmingRevocation,
            titleVisibility: .visible
        ) {
            Button("Record withdrawal", role: .destructive) {
                consent = consent.revoked()
                Task { await saveDraft(showMessage: true) }
            }
            Button("Keep consent", role: .cancel) {}
        } message: {
            Text("This updates the local audit history. The consent authority must also issue a signed revocation receipt before the external dataset is rebuilt.")
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "serveai-annotation-\(annotationID.uuidString.lowercased())"
        ) { result in
            switch result {
            case .success:
                exportMessage = "Annotation JSON exported."
            case .failure(let error):
                exportMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left")
                    .frame(width: 44, height: 44)
                    .background(ServeAITheme.elevatedSurface, in: Circle())
            }
            .foregroundStyle(ServeAITheme.ink)
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 2) {
                Text("COACH LABELS")
                    .font(ServeAITheme.display(.title3, size: 19))
                Text("Schema v\(CoachServeAnnotationPackage.currentSchemaVersion) · Rubric v\(CoachAnnotationRubric.version)")
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
            Spacer()
            Label(
                annotationComplete ? "COMPLETE" : "DRAFT",
                systemImage: annotationComplete ? "checkmark.circle.fill" : "pencil.circle"
            )
            .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
            .foregroundStyle(annotationComplete ? ServeAITheme.brand : ServeAITheme.orange)
        }
    }

    private var calibrationNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.badge.shield.checkmark.fill")
                .foregroundStyle(ServeAITheme.cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("INTERNAL CALIBRATION TOOL")
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .bold))
                Text("Human labels are ground truth candidates, not corrections to the player’s saved report. Exported drafts remain local until you share them.")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .serveAISurface()
    }

    private var videoEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Video evidence", detail: "Scrub to an event, then mark its boundary")

            Group {
                if let player {
                    VideoPlayer(player: player)
                        .accessibilityLabel("Serve video for coach annotation")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash.fill").font(.title)
                        Text("Original video is unavailable")
                            .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                        Text("You can still label usability and technique, but phase timing cannot be verified.")
                            .font(ServeAITheme.body(.caption, size: 12))
                            .foregroundStyle(ServeAITheme.mutedInk)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Slider(
                value: $currentTime,
                in: 0...videoDuration,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { seek(to: currentTime) }
                }
            )
            .tint(ServeAITheme.brand)
            .onChange(of: currentTime) { _, value in
                if isScrubbing { seek(to: value) }
            }
            .disabled(player == nil)
            .accessibilityLabel("Video position")
            .accessibilityValue(timeLabel(currentTime))

            HStack(spacing: 10) {
                Button { stepFrame(direction: -1) } label: {
                    Label("BACK", systemImage: "backward.frame.fill")
                }
                .accessibilityLabel("Previous frame")

                Button { togglePlayback() } label: {
                    Label(isPlaying ? "PAUSE" : "PLAY", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }

                Button { stepFrame(direction: 1) } label: {
                    Label("NEXT", systemImage: "forward.frame.fill")
                }
                .accessibilityLabel("Next frame")
            }
            .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .disabled(player == nil)

            HStack {
                Text(timeLabel(currentTime))
                Spacer()
                Text("FRAME \(estimatedFrameNumber)")
            }
            .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
            .foregroundStyle(ServeAITheme.mutedInk)
        }
        .serveAISurface()
    }

    private var phaseSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                "Phase boundaries",
                detail: "\(completedPhaseCount) of \(ServePhaseKind.allCases.count) phases decided"
            )

            Picker("Selected phase", selection: $selectedPhase) {
                ForEach(ServePhaseKind.allCases) { phase in
                    Text(phase.title).tag(phase)
                }
            }
            .pickerStyle(.menu)
            .tint(ServeAITheme.brand)

            Toggle("Visible in this clip", isOn: phaseVisibilityBinding(selectedPhase))
                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                .disabled(player == nil)

            if phaseDrafts[selectedPhase]?.isVisible == true {
                HStack(spacing: 10) {
                    boundaryButton(title: "MARK START", symbol: "insertion.cursor", value: phaseDrafts[selectedPhase]?.startTime) {
                        setBoundary(.start)
                    }
                    boundaryButton(title: "MARK END", symbol: "selection.pin.in.out", value: phaseDrafts[selectedPhase]?.endTime) {
                        setBoundary(.end)
                    }
                }
            } else {
                Label("This phase will export as not visible.", systemImage: "eye.slash.fill")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }

            Divider().overlay(ServeAITheme.separator)

            ForEach(ServePhaseKind.allCases) { phase in
                Button { selectedPhase = phase } label: {
                    HStack(spacing: 10) {
                        Image(systemName: phaseStatusSymbol(phase))
                            .foregroundStyle(phaseStatusColor(phase))
                            .frame(width: 22)
                        Text(phase.title)
                            .font(ServeAITheme.body(.subheadline, size: 14, weight: phase == selectedPhase ? .semibold : .regular))
                        Spacer()
                        Text(phaseTimingLabel(phase))
                            .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .serveAISurface()
    }

    private var techniqueSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Technique ratings", detail: "Frozen single-serve 2D rubric · mark hidden evidence not visible")

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(CoachAnnotationRubric.scope)
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                    ForEach(CoachAnnotationRubric.ratingAnchors) { anchor in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(anchor.rating)")
                                .font(ServeAITheme.mono(.caption, size: 11, bold: true))
                                .foregroundStyle(ServeAITheme.brand)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(anchor.title)
                                    .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                                Text(anchor.definition)
                                    .font(ServeAITheme.body(.caption2, size: 11))
                                    .foregroundStyle(ServeAITheme.mutedInk)
                            }
                        }
                    }
                    Text(CoachAnnotationRubric.priorityRule)
                        .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                    Text(CoachAnnotationRubric.visibilityRule)
                        .font(ServeAITheme.body(.caption2, size: 11))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                .padding(.top, 10)
            } label: {
                Label("Rubric v\(CoachAnnotationRubric.version) anchors", systemImage: "list.clipboard.fill")
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
            }
            .tint(ServeAITheme.brand)

            ForEach(CoachTechniqueLabel.allCases, id: \.rawValue) { label in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(label.title)
                            .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                        Spacer()
                        Toggle("Visible", isOn: techniqueVisibilityBinding(label))
                            .labelsHidden()
                            .accessibilityLabel("\(label.title) visible")
                    }
                    Picker("\(label.title) rating", selection: techniqueRatingBinding(label)) {
                        ForEach(1...5, id: \.self) { rating in Text("\(rating)").tag(rating) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!visibleTechniques.contains(label))

                    if visibleTechniques.contains(label) {
                        Text(CoachAnnotationRubric.anchor(for: techniqueRatings[label] ?? 3).title)
                            .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                            .foregroundStyle(ServeAITheme.brand)
                    }

                    DisclosureGroup("Observation guide") {
                        let item = CoachAnnotationRubric.technique(for: label)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(item.observe)
                            Text("Required: \(item.requiredVisibility)")
                                .foregroundStyle(ServeAITheme.mutedInk)
                            Text(item.doNotInfer)
                                .foregroundStyle(ServeAITheme.orange)
                        }
                        .font(ServeAITheme.body(.caption, size: 12))
                        .padding(.top, 7)
                    }
                    .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                    .tint(ServeAITheme.brand)
                }
                if label != CoachTechniqueLabel.allCases.last {
                    Divider().overlay(ServeAITheme.separator)
                }
            }

            Picker("Highest-priority correction", selection: $topPriority) {
                Text("Choose a priority").tag(nil as CoachTechniqueLabel?)
                ForEach(priorityCandidates, id: \.rawValue) { label in
                    Text(label.title).tag(label as CoachTechniqueLabel?)
                }
            }
            .pickerStyle(.menu)
            .tint(ServeAITheme.brand)
        }
        .serveAISurface()
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                "Collection cohorts",
                detail: "Required for held-out subgroup checks; do not infer unknown details"
            )

            if let lockedCapturePlanSlot {
                Label(
                    "Locked to \(lockedCapturePlanSlot.slotID) and its frozen cohorts",
                    systemImage: "lock.fill"
                )
                .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                .foregroundStyle(ServeAITheme.cyan)
            }

            cohortPicker("Dominant hand", selection: $dominantHand)
            Divider().overlay(ServeAITheme.separator)
            cohortPicker("Court setting", selection: $courtEnvironment)
            Divider().overlay(ServeAITheme.separator)
            cohortPicker("Lighting", selection: $lightingCondition)
            Divider().overlay(ServeAITheme.separator)
            cohortPicker("Player/background contrast", selection: $subjectContrast)
            Divider().overlay(ServeAITheme.separator)
            cohortPicker("Source device", selection: $sourceDeviceCategory)

            TextField("Device model, e.g. iPhone 15 Pro", text: $sourceDeviceModel)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(12)
                .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHint("Use a model name or study device code, never a serial number")

            Label(
                "\(analysis.videoMetadata.width)×\(analysis.videoMetadata.height) · \(analysis.videoMetadata.nominalFrameRate.formatted(.number.precision(.fractionLength(0...1)))) FPS",
                systemImage: "video.fill"
            )
            .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
            .foregroundStyle(ServeAITheme.mutedInk)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(RecordingIssueTag.allCases) { tag in
                        Toggle(tag.title, isOn: recordingIssueBinding(tag))
                            .font(ServeAITheme.body(.subheadline, size: 14))
                    }
                }
                .padding(.top, 8)
            } label: {
                Text(recordingIssueTags.isEmpty ? "Recording issues · none" : "Recording issues · \(recordingIssueTags.count)")
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
            }
            .tint(ServeAITheme.brand)

            if !collectionMetadata.isCompleteForDataset {
                Label("Complete every cohort field before dataset review.", systemImage: "exclamationmark.triangle.fill")
                    .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                    .foregroundStyle(ServeAITheme.orange)
            }
        }
        .serveAISurface()
        .disabled(lockedCapturePlanSlot != nil)
    }

    private func cohortPicker<Value: Hashable & Identifiable & CaseIterable>(
        _ title: String,
        selection: Binding<Value>
    ) -> some View where Value.AllCases: RandomAccessCollection, Value: RawRepresentable, Value.RawValue == String {
        LabeledContent(title) {
            Picker(title, selection: selection) {
                ForEach(Value.allCases) { value in
                    Text(cohortTitle(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(ServeAITheme.brand)
        }
        .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
    }

    private func cohortTitle<Value: RawRepresentable>(_ value: Value) -> String where Value.RawValue == String {
        switch value {
        case let value as DominantHand: value.title
        case let value as CourtEnvironment: value.title
        case let value as LightingCondition: value.title
        case let value as SourceDeviceCategory: value.title
        case let value as SubjectContrast: value.title
        default: value.rawValue
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Coach review", detail: "Use study codes only; never enter a player or coach name")

            TextField("Participant ID (for player-separated splits)", text: $participantPseudonym)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHint("Use one stable anonymous code for every serve from this player")
                .disabled(lockedParticipantPseudonym != nil)

            if let lockedParticipantPseudonym {
                Label(
                    "Participant is locked by signed capture slot \(analysis.coachLabelingTask?.payload.capturePlanAssignment.slotID ?? "").",
                    systemImage: "lock.fill"
                )
                .font(ServeAITheme.body(.caption, size: 12))
                .foregroundStyle(ServeAITheme.mutedInk)
                .accessibilityLabel("Participant \(lockedParticipantPseudonym) is locked by the signed capture plan")
            }

            TextField("Coach ID or pseudonym", text: $annotatorPseudonym)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHint("Use a stable coach code, not a real name")
                .disabled(lockedCoachPseudonym != nil)

            if lockedCoachPseudonym != nil {
                Label("Coach ID is locked to this independent labeling session.", systemImage: "lock.fill")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }

            Toggle("Video is usable for evaluation", isOn: $isVideoUsable)
                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))

            if !isVideoUsable {
                TextField("Why is this video unusable?", text: $unusableReason, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Coach notes")
                    .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                TextEditor(text: $coachNotes)
                    .font(ServeAITheme.body(.body, size: 16))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Toggle(isOn: consentBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Consent record checked locally")
                        .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                    Text("Enable only after checking the participant’s current affirmative record. This local reference is not final dataset authorization.")
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
            }
            .tint(ServeAITheme.brand)

            if let recordedAt = consent.recordedAt {
                Label(
                    consent.isActive
                        ? "Local consent reference active · \(recordedAt.formatted(date: .abbreviated, time: .shortened))"
                        : "Local consent reference inactive",
                    systemImage: consent.isActive ? "checkmark.shield.fill" : "hand.raised.fill"
                )
                .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                .foregroundStyle(consent.isActive ? ServeAITheme.cyan : ServeAITheme.pink)
            }

            if let recordID = consent.consentRecordID {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONSENT RECORD ID")
                        .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                        .foregroundStyle(ServeAITheme.mutedInk)
                    Text(recordID.uuidString.lowercased())
                        .font(ServeAITheme.mono(.caption, size: 11))
                        .textSelection(.enabled)
                        .accessibilityLabel("Consent record ID \(recordID.uuidString)")
                    Text("A separate authorized administrator must bind this ID to a signed receipt covering the participant, notice, purposes, retention period, and source-video fingerprint.")
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
                .padding(12)
                .background(ServeAITheme.deepSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let revokedAt = consent.revokedAt {
                Text("Revoked \(revokedAt.formatted(date: .abbreviated, time: .shortened)). The prior grant remains in the local audit history.")
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .serveAISurface()
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: annotationComplete ? "checkmark.seal.fill" : "doc.badge.ellipsis")
                    .foregroundStyle(annotationComplete ? ServeAITheme.brand : ServeAITheme.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotationComplete ? "ANNOTATION COMPLETE" : "EXPORTS AS A DRAFT")
                        .font(ServeAITheme.body(.subheadline, size: 14, weight: .bold))
                    Text(exportReadinessDetail)
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
            }

            Label(
                datasetEligible ? "READY FOR EXTERNAL CONSENT + SIGNATURE REVIEW" : "NOT READY FOR DATASET REVIEW",
                systemImage: datasetEligible ? "checkmark.shield.fill" : "hand.raised.fill"
            )
            .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
            .foregroundStyle(datasetEligible ? ServeAITheme.cyan : ServeAITheme.pink)

            Button {
                Task { await saveDraft(showMessage: true) }
            } label: {
                if isSavingDraft {
                    Label("SAVING DRAFT", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("SAVE DRAFT ON THIS IPHONE", systemImage: "internaldrive.fill")
                }
            }
            .buttonStyle(ServeAISecondaryButtonStyle())
            .disabled(isLoadingDraft || isSavingDraft)

            Button {
                Task {
                    await saveDraft(showMessage: false)
                    prepareExport()
                }
            } label: {
                Label(annotationComplete ? "EXPORT ANNOTATION" : "EXPORT DRAFT", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ServeAIPrimaryButtonStyle())
            .disabled(isLoadingDraft)

            if let persistenceMessage {
                Text(persistenceMessage)
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }

            if let exportMessage {
                Text(exportMessage)
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
            }
        }
        .serveAISurface()
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(ServeAITheme.body(.headline, size: 17, weight: .bold))
            Text(detail)
                .font(ServeAITheme.body(.caption, size: 12))
                .foregroundStyle(ServeAITheme.mutedInk)
        }
    }

    private func boundaryButton(
        title: String,
        symbol: String,
        value: TimeInterval?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Label(title, systemImage: symbol)
                Text(value.map(timeLabel) ?? "NOT SET")
                    .foregroundStyle(value == nil ? ServeAITheme.orange : ServeAITheme.brand)
            }
            .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .disabled(player == nil)
    }

    private var videoDuration: TimeInterval { max(analysis.videoMetadata.duration, 0.1) }
    private var frameRate: Double { max(analysis.videoMetadata.nominalFrameRate, 30) }
    private var estimatedFrameNumber: Int { Int((currentTime * frameRate).rounded()) }

    private var completedPhaseCount: Int {
        ServePhaseKind.allCases.filter { phase in
            guard let draft = phaseDrafts[phase] else { return false }
            return !draft.isVisible || (draft.startTime != nil && draft.endTime != nil)
        }.count
    }

    private var annotationComplete: Bool {
        let hasCoachID = !annotatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isVideoUsable {
            return hasCoachID && !unusableReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasCoachID
            && completedPhaseCount == ServePhaseKind.allCases.count
            && topPriority.map { priorityCandidates.contains($0) } == true
    }

    private var datasetEligible: Bool {
        annotationComplete
            && consent.isActive
            && !participantPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && collectionMetadata.isCompleteForDataset
            && (analysis.modelFeatureEvidence?.isCompleteForDataset ?? false)
    }

    private var exportReadinessDetail: String {
        if annotatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a pseudonymous coach ID."
        }
        if !consent.isActive {
            return "Check the participant’s consent record; external signed proof will still be required."
        }
        if consent.isActive, participantPseudonym.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a stable participant ID so this player cannot leak across data splits."
        }
        if consent.isActive, !collectionMetadata.isCompleteForDataset {
            return "Complete handedness, setting, lighting, contrast, and source-device cohorts."
        }
        if consent.isActive, !(analysis.modelFeatureEvidence?.isCompleteForDataset ?? false) {
            return "Reanalyze the original video to attach a reproducible pose sequence and source fingerprint."
        }
        if !isVideoUsable, unusableReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add the reason this clip is unusable."
        }
        if isVideoUsable, completedPhaseCount < ServePhaseKind.allCases.count {
            return "Decide every phase: mark its boundaries or set it not visible."
        }
        if isVideoUsable, topPriority == nil {
            return "Choose the coach’s highest-priority correction."
        }
        if isVideoUsable, topPriority.map({ priorityCandidates.contains($0) }) != true {
            return "Choose one of the lowest-rated visible techniques as the coaching priority."
        }
        return "Human labels are ready; independent consent and coach signatures are still required."
    }

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { consent.isActive },
            set: { newValue in
                if newValue {
                    consent = consent.recordedAt == nil ? .granted() : consent.grantedAgain()
                } else if consent.isActive {
                    isConfirmingRevocation = true
                }
            }
        )
    }

    @MainActor
    private func prepareSessionSelection() async {
        defer { isLoadingDraft = false }
        do {
            savedSessions = try await store.listSessions(analysisID: analysis.id)
            sessionSelectionError = nil
        } catch {
            savedSessions = []
            sessionSelectionError = "Saved sessions could not be read: \(error.localizedDescription)"
        }
        isShowingSessionPicker = true
    }

    @MainActor
    private func beginNewSession(coachID: String) {
        let trimmedCoachID = coachID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCoachID.isEmpty, sessionSelectionError == nil else { return }
        resetEditorForNewSession(coachID: trimmedCoachID)
        hasSelectedSession = true
        isShowingSessionPicker = false
        persistenceMessage = "New blind labeling session started. No saved coach decisions were loaded."
    }

    @MainActor
    private func resumeSession(_ session: CoachAnnotationSessionDescriptor) async {
        guard !isLoadingSession, sessionSelectionError == nil else { return }
        isLoadingSession = true
        defer { isLoadingSession = false }
        do {
            guard let package = try await store.load(
                analysisID: analysis.id,
                annotationID: session.annotationID
            ) else {
                sessionSelectionError = "That saved labeling session is no longer available."
                return
            }
            apply(package)
            lockedCoachPseudonym = package.annotatorPseudonym
            hasSelectedSession = true
            isShowingSessionPicker = false
            persistenceMessage = "Your saved labeling session was restored from this iPhone."
        } catch {
            sessionSelectionError = "Could not restore that session: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func saveDraft(showMessage: Bool) async {
        guard !isLoadingDraft, hasSelectedSession else { return }
        isSavingDraft = true
        defer { isSavingDraft = false }
        do {
            let trimmedCoachID = annotatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
            if lockedCoachPseudonym == nil, !trimmedCoachID.isEmpty {
                lockedCoachPseudonym = trimmedCoachID
            }
            try await store.save(annotationPackage)
            if showMessage { persistenceMessage = "Draft saved privately on this iPhone." }
        } catch {
            persistenceMessage = "Could not save the draft: \(error.localizedDescription)"
        }
    }

    private func apply(_ package: CoachServeAnnotationPackage) {
        guard package.analysisID == analysis.id else { return }
        annotationID = package.annotationID
        createdAt = package.createdAt
        participantPseudonym = lockedParticipantPseudonym ?? package.participantPseudonym ?? ""
        annotatorPseudonym = package.annotatorPseudonym ?? ""
        isVideoUsable = package.isVideoUsable
        unusableReason = package.unusableReason ?? ""
        coachNotes = package.coachNotes ?? ""
        topPriority = package.topPriority

        var restoredPhases = phaseDrafts
        for boundary in package.phaseBoundaries {
            restoredPhases[boundary.phase] = PhaseBoundaryDraft(
                isVisible: boundary.isVisible,
                startTime: boundary.startTime,
                endTime: boundary.endTime
            )
        }
        phaseDrafts = restoredPhases

        var restoredRatings = techniqueRatings
        var restoredVisibility: Set<CoachTechniqueLabel> = []
        for technique in package.techniqueRatings {
            if let rating = technique.rating { restoredRatings[technique.label] = rating }
            if technique.isVisible { restoredVisibility.insert(technique.label) }
        }
        techniqueRatings = restoredRatings
        visibleTechniques = restoredVisibility

        if let metadata = package.collectionMetadata {
            dominantHand = metadata.dominantHand
            courtEnvironment = metadata.environment
            lightingCondition = metadata.lighting
            sourceDeviceCategory = metadata.sourceDeviceCategory
            sourceDeviceModel = metadata.sourceDeviceModel ?? ""
            subjectContrast = metadata.subjectContrast
            recordingIssueTags = Set(metadata.recordingIssueTags)
        }
        restoreLockedCaptureCohorts()

        consent = package.consent.upgradedForCurrentSchema()
    }

    private func resetEditorForNewSession(coachID: String) {
        let hasVideo = analysis.videoURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        phaseDrafts = Dictionary(uniqueKeysWithValues: ServePhaseKind.allCases.map {
            ($0, PhaseBoundaryDraft(isVisible: hasVideo, startTime: nil, endTime: nil))
        })
        techniqueRatings = Dictionary(uniqueKeysWithValues: CoachTechniqueLabel.allCases.map { ($0, 3) })
        visibleTechniques = []
        topPriority = nil
        dominantHand = .unknown
        courtEnvironment = .unknown
        lightingCondition = .unknown
        sourceDeviceCategory = .unknown
        sourceDeviceModel = ""
        subjectContrast = .unknown
        recordingIssueTags = []
        participantPseudonym = lockedParticipantPseudonym ?? ""
        annotatorPseudonym = coachID
        lockedCoachPseudonym = coachID
        isVideoUsable = hasVideo
        unusableReason = hasVideo ? "" : "Original video unavailable"
        coachNotes = ""
        consent = .notGranted
        restoreLockedCaptureCohorts()
        annotationID = UUID()
        createdAt = .now
        currentTime = 0
        selectedPhase = .startingStance
        player?.seek(to: .zero)
    }

    private func phaseVisibilityBinding(_ phase: ServePhaseKind) -> Binding<Bool> {
        Binding(
            get: { phaseDrafts[phase]?.isVisible ?? true },
            set: { value in
                var draft = phaseDrafts[phase] ?? PhaseBoundaryDraft(isVisible: value, startTime: nil, endTime: nil)
                draft.isVisible = value
                if !value { draft.startTime = nil; draft.endTime = nil }
                phaseDrafts[phase] = draft
            }
        )
    }

    private func techniqueRatingBinding(_ label: CoachTechniqueLabel) -> Binding<Int> {
        Binding(
            get: { techniqueRatings[label] ?? 3 },
            set: { techniqueRatings[label] = $0 }
        )
    }

    private func techniqueVisibilityBinding(_ label: CoachTechniqueLabel) -> Binding<Bool> {
        Binding(
            get: { visibleTechniques.contains(label) },
            set: { visible in
                if visible { visibleTechniques.insert(label) }
                else {
                    visibleTechniques.remove(label)
                    if topPriority == label { topPriority = nil }
                }
            }
        )
    }

    private func recordingIssueBinding(_ tag: RecordingIssueTag) -> Binding<Bool> {
        Binding(
            get: { recordingIssueTags.contains(tag) },
            set: { isPresent in
                if isPresent { recordingIssueTags.insert(tag) }
                else { recordingIssueTags.remove(tag) }
            }
        )
    }

    private enum BoundaryKind { case start, end }

    private func setBoundary(_ kind: BoundaryKind) {
        var draft = phaseDrafts[selectedPhase] ?? PhaseBoundaryDraft(isVisible: true, startTime: nil, endTime: nil)
        switch kind {
        case .start:
            draft.startTime = currentTime
            if let end = draft.endTime, end < currentTime { draft.endTime = nil }
        case .end:
            if let start = draft.startTime, currentTime < start {
                draft.startTime = nil
            }
            draft.endTime = currentTime
        }
        phaseDrafts[selectedPhase] = draft
    }

    private func phaseStatusSymbol(_ phase: ServePhaseKind) -> String {
        guard let draft = phaseDrafts[phase] else { return "circle.dashed" }
        if !draft.isVisible { return "eye.slash.fill" }
        if draft.startTime != nil, draft.endTime != nil { return "checkmark.circle.fill" }
        return "circle.dashed"
    }

    private func phaseStatusColor(_ phase: ServePhaseKind) -> Color {
        guard let draft = phaseDrafts[phase] else { return ServeAITheme.mutedInk }
        if !draft.isVisible { return ServeAITheme.mutedInk }
        return draft.startTime != nil && draft.endTime != nil ? ServeAITheme.brand : ServeAITheme.orange
    }

    private func phaseTimingLabel(_ phase: ServePhaseKind) -> String {
        guard let draft = phaseDrafts[phase] else { return "UNMARKED" }
        if !draft.isVisible { return "NOT VISIBLE" }
        guard let start = draft.startTime, let end = draft.endTime else { return "UNMARKED" }
        return "\(timeLabel(start))–\(timeLabel(end))"
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying { player.pause() }
        else {
            if currentTime >= videoDuration - 0.05 { seek(to: 0) }
            player.play()
        }
        isPlaying.toggle()
    }

    private func stepFrame(direction: Int) {
        player?.pause()
        isPlaying = false
        let target = min(videoDuration, max(0, currentTime + Double(direction) / frameRate))
        currentTime = target
        seek(to: target)
    }

    private func seek(to seconds: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func updatePlaybackTime() {
        guard isPlaying, !isScrubbing, let player else { return }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        currentTime = min(videoDuration, max(0, seconds))
        if currentTime >= videoDuration - 0.02 {
            isPlaying = false
            player.pause()
        }
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        String(format: "%.2fs", seconds)
    }

    private func prepareExport() {
        do {
            exportDocument = CoachAnnotationDocument(data: try CoachAnnotationExporter().data(for: annotationPackage))
            isExporting = true
            exportMessage = nil
        } catch {
            exportMessage = "Could not prepare JSON: \(error.localizedDescription)"
        }
    }

    private var annotationPackage: CoachServeAnnotationPackage {
        let trimmedParticipantID = participantPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCoachID = annotatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = coachNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReason = unusableReason.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoachServeAnnotationPackage(
            schemaVersion: CoachServeAnnotationPackage.currentSchemaVersion,
            rubric: CoachAnnotationRubric.currentBinding,
            annotationID: annotationID,
            analysisID: analysis.id,
            createdAt: createdAt,
            videoFilename: analysis.videoURL?.lastPathComponent,
            cameraAngle: analysis.cameraAngle,
            skillLevel: analysis.skillLevel,
            collectionMetadata: collectionMetadata,
            modelFeatureEvidence: analysis.modelFeatureEvidence,
            labelingTask: analysis.coachLabelingTask,
            participantPseudonym: trimmedParticipantID.isEmpty ? nil : trimmedParticipantID,
            annotatorPseudonym: trimmedCoachID.isEmpty ? nil : trimmedCoachID,
            isVideoUsable: isVideoUsable,
            unusableReason: isVideoUsable || trimmedReason.isEmpty ? nil : trimmedReason,
            modelReport: ModelReportSnapshot(
                source: analysis.source,
                overallScore: analysis.overallScore,
                phaseScores: analysis.phaseScores,
                confidence: analysis.confidence
            ),
            phaseBoundaries: ServePhaseKind.allCases.map { phase in
                let draft = phaseDrafts[phase] ?? PhaseBoundaryDraft(isVisible: false, startTime: nil, endTime: nil)
                return CoachPhaseBoundaryAnnotation(
                    phase: phase,
                    startTime: draft.startTime,
                    endTime: draft.endTime,
                    isVisible: draft.isVisible
                )
            },
            techniqueRatings: CoachTechniqueLabel.allCases.map { label in
                let isVisible = isVideoUsable && visibleTechniques.contains(label)
                return CoachTechniqueAnnotation(
                    label: label,
                    rating: isVisible ? (techniqueRatings[label] ?? 3) : nil,
                    isVisible: isVisible
                )
            },
            topPriority: topPriority,
            coachNotes: trimmedNotes.isEmpty ? nil : trimmedNotes,
            consent: consent
        )
    }

    private var collectionMetadata: ServeCollectionMetadata {
        let trimmedDevice = sourceDeviceModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServeCollectionMetadata(
            dominantHand: dominantHand,
            environment: courtEnvironment,
            lighting: lightingCondition,
            sourceDeviceCategory: sourceDeviceCategory,
            sourceDeviceModel: trimmedDevice.isEmpty ? nil : trimmedDevice,
            subjectContrast: subjectContrast,
            recordingIssueTags: recordingIssueTags.sorted { $0.rawValue < $1.rawValue },
            videoWidth: analysis.videoMetadata.width,
            videoHeight: analysis.videoMetadata.height,
            nominalFrameRate: analysis.videoMetadata.nominalFrameRate
        )
    }

    private func restoreLockedCaptureCohorts() {
        guard let slot = lockedCapturePlanSlot else { return }
        dominantHand = slot.dominantHand
        courtEnvironment = slot.environment
        lightingCondition = slot.lighting
        sourceDeviceCategory = .iPhone
        sourceDeviceModel = slot.sourceDeviceModel
        subjectContrast = slot.subjectContrast
        recordingIssueTags = Set(slot.recordingIssueTags)
    }

    private var priorityCandidates: [CoachTechniqueLabel] {
        let visible = CoachTechniqueLabel.allCases.filter(visibleTechniques.contains)
        guard let minimum = visible.compactMap({ techniqueRatings[$0] }).min() else { return [] }
        return visible.filter { techniqueRatings[$0] == minimum }
    }
}

private struct CoachAnnotationSessionPicker: View {
    let sessions: [CoachAnnotationSessionDescriptor]
    let isLoading: Bool
    let errorMessage: String?
    let onStartNew: (String) -> Void
    let onResume: (CoachAnnotationSessionDescriptor) -> Void
    let onCancel: () -> Void

    @State private var coachPseudonym = ""

    private var trimmedCoachPseudonym: String {
        coachPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "person.2.badge.shield.checkmark.fill")
                            .font(.title)
                            .foregroundStyle(ServeAITheme.cyan)
                            .accessibilityHidden(true)
                        Text("Choose a labeling session")
                            .font(ServeAITheme.display(.title2, size: 24))
                        Text("Start blank for every independent review. Resume only a draft you created. Another coach’s phase and technique decisions are never previewed here.")
                            .font(ServeAITheme.body(.body, size: 16))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                            .foregroundStyle(ServeAITheme.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .serveAISurface()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("New blind label")
                            .font(ServeAITheme.body(.headline, size: 17, weight: .bold))
                        Text("Your pseudonymous coach ID is locked to the new session so it cannot be reassigned later.")
                            .font(ServeAITheme.body(.caption, size: 12))
                            .foregroundStyle(ServeAITheme.mutedInk)
                        TextField("Coach ID or pseudonym", text: $coachPseudonym)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(
                                ServeAITheme.deepSurface,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .accessibilityHint("Use a stable study code, never a real name")
                        Button {
                            onStartNew(trimmedCoachPseudonym)
                        } label: {
                            Label("START NEW BLIND LABEL", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(ServeAIPrimaryButtonStyle())
                        .disabled(trimmedCoachPseudonym.isEmpty || isLoading || errorMessage != nil)
                    }
                    .serveAISurface()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Saved sessions on this iPhone")
                            .font(ServeAITheme.body(.headline, size: 17, weight: .bold))
                        if sessions.isEmpty {
                            Label("No saved coach sessions yet", systemImage: "tray")
                                .font(ServeAITheme.body(.subheadline, size: 14))
                                .foregroundStyle(ServeAITheme.mutedInk)
                                .frame(minHeight: 44)
                        } else {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 {
                                    Divider().overlay(ServeAITheme.separator)
                                }
                                Button {
                                    onResume(session)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "doc.text.fill")
                                            .foregroundStyle(ServeAITheme.brand)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(session.annotatorPseudonym ?? "Unassigned legacy draft")
                                                .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                                            Text("\(session.createdAt.formatted(date: .abbreviated, time: .shortened)) · ID \(session.annotationID.uuidString.prefix(8).lowercased())")
                                                .font(ServeAITheme.mono(.caption2, size: 9))
                                                .foregroundStyle(ServeAITheme.mutedInk)
                                        }
                                        Spacer()
                                        if isLoading {
                                            ProgressView().tint(ServeAITheme.brand)
                                        } else {
                                            Image(systemName: "chevron.right")
                                                .foregroundStyle(ServeAITheme.mutedInk)
                                        }
                                    }
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading || errorMessage != nil)
                                .accessibilityLabel(
                                    "Resume session for \(session.annotatorPseudonym ?? "unassigned coach"), created \(session.createdAt.formatted(date: .abbreviated, time: .shortened))"
                                )
                            }
                        }
                    }
                    .serveAISurface()

                    Label(
                        "Session selection separates local drafts. External coach signatures still prove who authorized each exported annotation.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(ServeAITheme.body(.caption, size: 12))
                    .foregroundStyle(ServeAITheme.mutedInk)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .serveAIBackground()
            .navigationTitle("Coach session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(ServeAITheme.ink)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PhaseBoundaryDraft: Hashable {
    var isVisible: Bool
    var startTime: TimeInterval?
    var endTime: TimeInterval?
}

struct CoachAnnotationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#Preview {
    NavigationStack {
        CoachAnnotationView(analysis: MockData.analysis())
    }
}
