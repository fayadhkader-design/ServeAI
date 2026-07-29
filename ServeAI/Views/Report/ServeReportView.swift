import AVKit
import SwiftUI

struct ServeReportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel
    let analysis: ServeAnalysis
    let openFrameReview: () -> Void
    let openCoachAnnotation: () -> Void
    @State private var player: AVPlayer?
    @State private var isShowingTaskExport = false

    private var strengths: [CoachingInsight] { analysis.insights.filter { $0.severity == .strength } }
    private var improvements: [CoachingInsight] { analysis.insights.filter { $0.severity != .strength } }

    init(
        analysis: ServeAnalysis,
        openFrameReview: @escaping () -> Void = {},
        openCoachAnnotation: @escaping () -> Void = {}
    ) {
        self.analysis = analysis
        self.openFrameReview = openFrameReview
        self.openCoachAnnotation = openCoachAnnotation
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                reportHeader
                if analysis.source == .researchCapture {
                    researchCaptureCard
                } else {
                    verdictCard
                    coachCard

                    Button(action: openFrameReview) {
                        HStack {
                            Text("FRAME BY FRAME")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(ServeAITheme.display(.headline, size: 17))
                        .foregroundStyle(ServeAITheme.background)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .padding(.horizontal, 18)
                        .background(ServeAITheme.ink, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the video phase review")
                }

                sourceBanner
                Button(action: openCoachAnnotation) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.text.rectangle")
                            .foregroundStyle(ServeAITheme.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("COACH CALIBRATION")
                                .font(ServeAITheme.body(.subheadline, size: 14, weight: .bold))
                            Text("Label phases and export ground truth")
                                .font(ServeAITheme.body(.caption, size: 12))
                                .foregroundStyle(ServeAITheme.mutedInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.separator) }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the internal coach annotation editor")

                Button { isShowingTaskExport = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .foregroundStyle(ServeAITheme.brand)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SEND BLIND COACH TASK")
                                .font(ServeAITheme.body(.subheadline, size: 14, weight: .bold))
                            Text("Sign and export the exact analysis evidence")
                                .font(ServeAITheme.body(.caption, size: 12))
                                .foregroundStyle(ServeAITheme.mutedInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(ServeAITheme.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.brand.opacity(0.26)) }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Creates a signed coach task JSON to use on another device")
                reportFacts

                if let player {
                    VStack(alignment: .leading, spacing: 10) {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .accessibilityLabel("Analyzed serve video")
                        HStack {
                            Button { player.seek(to: .zero); player.play() } label: { Label("Replay", systemImage: "arrow.counterclockwise") }.buttonStyle(.bordered)
                            Spacer()
                            Label("Pose overlay unavailable", systemImage: "figure.stand.line.dotted.figure.stand")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if analysis.source != .researchCapture {
                    ReportDisclosure(title: "Phase-by-phase", subtitle: "\(analysis.phaseScores.compactMap(\.score).count) of 10 phases measurable", symbol: "timeline.selection", initiallyExpanded: true) {
                        ForEach(analysis.phaseScores) { phase in
                            PhaseScoreRow(phase: phase)
                            if phase.id != analysis.phaseScores.last?.id { Divider() }
                        }
                    }

                    ReportDisclosure(title: "Top strengths", subtitle: strengths.first?.title ?? "No reliable strength identified", symbol: "arrow.up.forward.circle.fill", initiallyExpanded: true) {
                        if strengths.isEmpty { Text("More visible frames are needed before naming a reliable strength.").foregroundStyle(.secondary) }
                        else { ForEach(strengths) { InsightDetail(insight: $0) } }
                    }

                    ReportDisclosure(title: "Priority improvements", subtitle: improvements.first?.title ?? "No reliable priority identified", symbol: "scope", initiallyExpanded: true) {
                        if improvements.isEmpty { Text("No improvement is presented when the evidence is too limited.").foregroundStyle(.secondary) }
                        else {
                            ForEach(improvements) { insight in
                                InsightDetail(insight: insight)
                                if insight.id != improvements.last?.id { Divider().padding(.vertical, 8) }
                            }
                        }
                    }

                    ReportDisclosure(title: "Recommended drills", subtitle: "\(analysis.drills.count) focused practice options", symbol: "list.clipboard.fill") {
                        ForEach(Array(analysis.drills.enumerated()), id: \.element.id) { index, drill in
                            DrillDetail(number: index + 1, drill: drill)
                            if drill.id != analysis.drills.last?.id { Divider().padding(.vertical, 10) }
                        }
                    }

                    ReportDisclosure(title: "Technical measurements", subtitle: "Joint and movement estimates", symbol: "ruler") {
                        if analysis.technicalMetrics.isEmpty { Text("No technical measurements met the minimum visual-evidence threshold.").foregroundStyle(.secondary) }
                        else {
                            ForEach(analysis.technicalMetrics) { metric in
                                MetricRow(metric: metric)
                                if metric.id != analysis.technicalMetrics.last?.id { Divider() }
                            }
                        }
                    }
                }

                ReportDisclosure(title: "Video evidence & visibility", subtitle: "\(analysis.confidence.evidenceQualityTitle) · \(analysis.confidence.percentage)%", symbol: "checkmark.seal") {
                    ConfidenceDetail(confidence: analysis.confidence, metadata: analysis.videoMetadata, source: analysis.source)
                }

                ReportDisclosure(title: "Analysis limitations", subtitle: "What this report cannot establish", symbol: "exclamationmark.triangle") {
                    ForEach(analysis.limitations) { limitation in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: limitation.symbol).foregroundStyle(ServeAITheme.courtGold).frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(limitation.title).font(.headline)
                                Text(limitation.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    Text("ServeAI feedback is educational and may not replace feedback from a qualified tennis coach.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }

                Label("This report is stored locally. ServeAI does not identify faces or upload video in this MVP.", systemImage: "lock.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .serveAISurface()
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if let url = analysis.videoURL, FileManager.default.fileExists(atPath: url.path) { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $isShowingTaskExport) {
            CoachTaskExportSheet(
                analysis: analysis,
                suggestedAssignment: appModel.activePilotSlot?.assignment
            )
        }
    }

    private var reportHeader: some View {
        HStack {
            Text(analysis.source == .researchCapture ? "RESEARCH SAMPLE" : "THE VERDICT")
                .font(ServeAITheme.display(.title3, size: 19))
            Spacer()
            Button("DONE") { dismiss() }
                .font(ServeAITheme.mono(.caption2, size: 10, bold: true))
                .tracking(0.9)
                .foregroundStyle(ServeAITheme.mutedInk)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(ServeAITheme.surface, in: Capsule())
        }
    }

    private var researchCaptureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ServeAITheme.orange)
            Text("NO COACHING WAS GENERATED")
                .font(ServeAITheme.display(.headline, size: 18))
            Text("This rejected recording is stored only so authorized coaches can label input usability. The value 0 is not a serve score, and this sample is excluded from strengths, priorities, drills, and progress coaching.")
                .font(ServeAITheme.body(.subheadline, size: 14))
                .foregroundStyle(ServeAITheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(ServeAITheme.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.orange.opacity(0.30)) }
        .accessibilityElement(children: .combine)
    }

    private var verdictCard: some View {
        VStack(spacing: 14) {
            ScoreRing(score: analysis.overallScore, diameter: 196, lineWidth: 14)
            HStack(spacing: 8) {
                Text("\(grade) GRADE")
                    .font(ServeAITheme.display(.subheadline, size: 15))
                    .foregroundStyle(ServeAITheme.background)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(ServeAITheme.brand, in: Capsule())
                EvidenceQualityBadge(confidence: analysis.confidence.level, contextLabel: "Video evidence")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 18)
        .background(ServeAITheme.heroGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(ServeAITheme.brand.opacity(0.24))
        }
    }

    private var coachCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "tennisball.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ServeAITheme.background)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [ServeAITheme.brand, ServeAITheme.cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: Circle()
                )
            VStack(alignment: .leading, spacing: 6) {
                ServeAISectionLabel(text: "COACH AI SAYS")
                Text(coachLine)
                    .font(ServeAITheme.body(.body, size: 14))
                    .foregroundStyle(ServeAITheme.ink)
                    .lineSpacing(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(ServeAITheme.separator) }
    }

    private var grade: String {
        switch analysis.overallScore {
        case 93...: "A+"
        case 90...: "A"
        case 87...: "A−"
        case 83...: "B+"
        case 80...: "B"
        case 77...: "B−"
        case 73...: "C+"
        case 70...: "C"
        case 67...: "C−"
        case 60...: "D"
        default: "F"
        }
    }

    private var coachLine: String {
        let strength = strengths.first?.title
        let priority = improvements.first?.correction
        return switch (strength, priority) {
        case let (strength?, priority?): "Keep this strength: \(strength). Next priority: \(priority)"
        case let (strength?, nil): "\(strength) is your clearest strength. Repeat the same setup on the next serve."
        case let (nil, priority?): "One priority for the next basket: \(priority)"
        default: "The video evidence is limited. Record again with the full body and racket visible before changing your motion."
        }
    }

    private var sourceBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: analysis.source == .simulated ? "testtube.2" : (analysis.source.requiresCautionBanner ? "exclamationmark.triangle.fill" : "iphone.gen3"))
                .font(.title3).foregroundStyle(analysis.source.requiresCautionBanner ? ServeAITheme.courtGold : ServeAITheme.brand)
            VStack(alignment: .leading, spacing: 3) {
                Text(analysis.source.title).font(.headline)
                Text(analysis.source.detail)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(analysis.source.requiresCautionBanner ? ServeAITheme.orange.opacity(0.12) : ServeAITheme.brand.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke((analysis.source.requiresCautionBanner ? ServeAITheme.orange : ServeAITheme.brand).opacity(0.28)) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var reportHero: some View {
        ScoreRing(score: analysis.overallScore, diameter: 136)
        VStack(alignment: .leading, spacing: 8) {
            Text("Serve Report").font(.largeTitle.bold())
            EvidenceQualityBadge(confidence: analysis.confidence.level, contextLabel: "Video evidence")
            Text("Score is an estimate. Video evidence quality does not measure coaching correctness.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var reportFacts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { factItems }
            VStack(alignment: .leading, spacing: 12) { factItems }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var factItems: some View {
        Label(analysis.skillLevel.title, systemImage: "person.fill")
        Label(analysis.cameraAngle.title, systemImage: analysis.cameraAngle.symbol)
        Label { Text(analysis.createdAt, format: .dateTime.month(.abbreviated).day().year()) } icon: { Image(systemName: "calendar") }
    }
}

private struct CoachTaskExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let analysis: ServeAnalysis

    @State private var coordinatorPseudonym = ""
    @State private var captureSlotID = ""
    @State private var participantPseudonym = ""
    @State private var document: CoachAnnotationDocument?
    @State private var isCreating = false
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var exportedMessage: String?

    private let service = CoachLabelingTaskService()

    init(analysis: ServeAnalysis, suggestedAssignment: CapturePlanAssignment? = nil) {
        self.analysis = analysis
        _captureSlotID = State(initialValue: suggestedAssignment?.slotID ?? "")
        _participantPseudonym = State(initialValue: suggestedAssignment?.participantPseudonym ?? "")
    }

    private var trimmedCoordinator: String {
        coordinatorPseudonym.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var captureAssignment: CapturePlanAssignment? {
        try? CapturePlanAssignment.make(
            slotID: captureSlotID,
            participantPseudonym: participantPseudonym
        )
    }

    private var captureMismatches: [String] {
        captureAssignment?.observedMismatches(in: analysis) ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        ServeAISectionLabel(text: "CROSS-DEVICE LABELING")
                        Text("CREATE A BLIND TASK")
                            .font(ServeAITheme.display(.title2, size: 23))
                        Text("This signs the capture slot, report, pose sequence, analysis identity, and source-video fingerprint as one immutable task.")
                            .font(ServeAITheme.body(.body, size: 15))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ServeAISectionLabel(text: "COORDINATOR PSEUDONYM", color: ServeAITheme.cyan)
                        TextField("coordinator-01", text: $coordinatorPseudonym)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ServeAITheme.separator) }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        ServeAISectionLabel(text: "CAPTURE PLAN ASSIGNMENT", color: ServeAITheme.orange)
                        Text("Use the assigned pilot slot. Each participant owns five consecutive slots, and the portal rejects duplicates or cohort mismatches.")
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.mutedInk)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                captureSlotField
                                participantField
                            }
                            VStack(spacing: 10) {
                                captureSlotField
                                participantField
                            }
                        }
                        .padding(14)
                        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ServeAITheme.separator) }
                        Label(
                            captureAssignment == nil
                                ? "Enter a matching slot and participant."
                                : (captureMismatches.isEmpty
                                    ? "Assignment and observed video format match the frozen plan."
                                    : "This report does not match the selected slot."),
                            systemImage: captureAssignment == nil || !captureMismatches.isEmpty
                                ? "exclamationmark.circle"
                                : "checkmark.seal.fill"
                        )
                        .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                        .foregroundStyle(captureAssignment == nil || !captureMismatches.isEmpty ? ServeAITheme.orange : ServeAITheme.brand)

                        if let slot = captureAssignment?.slot {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("REQUIRED FOR \(slot.slotID.uppercased())")
                                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                                    .foregroundStyle(ServeAITheme.mutedInk)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) { captureRequirementTags(slot) }
                                    VStack(alignment: .leading, spacing: 6) { captureRequirementTags(slot) }
                                }
                                if slot.isFailureExample {
                                    Label(
                                        "Failure-example cohort: \(slot.recordingIssueTags.map(\.title).joined(separator: ", "))",
                                        systemImage: "waveform.path.ecg.rectangle"
                                    )
                                    .font(ServeAITheme.body(.caption, size: 12, weight: .semibold))
                                    .foregroundStyle(ServeAITheme.orange)
                                }
                            }
                            .padding(.top, 4)
                        }

                        ForEach(captureMismatches, id: \.self) { mismatch in
                            Label(mismatch, systemImage: "xmark.octagon.fill")
                                .font(ServeAITheme.body(.caption, size: 12))
                                .foregroundStyle(ServeAITheme.pink)
                        }
                    }
                    .serveAISurface()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Original video: \(analysis.videoURL?.lastPathComponent ?? "unavailable")", systemImage: "film")
                        Label("Pose evidence: \(analysis.modelFeatureEvidence?.sequence.frames.count ?? 0) frames", systemImage: "figure.stand.line.dotted.figure.stand")
                        Label("The device signing key stays in Keychain", systemImage: "key.fill")
                    }
                    .font(ServeAITheme.body(.subheadline, size: 14))
                    .foregroundStyle(ServeAITheme.mutedInk)
                    .serveAISurface()

                    Button {
                        createTask()
                    } label: {
                        if isCreating {
                            HStack { ProgressView(); Text("SIGNING TASK…") }
                        } else {
                            Label("CREATE SIGNED TASK", systemImage: "signature")
                        }
                    }
                    .buttonStyle(ServeAIPrimaryButtonStyle())
                    .disabled(trimmedCoordinator.count < 3 || captureAssignment == nil || !captureMismatches.isEmpty || isCreating)

                    if document != nil {
                        Label("Task ready. Save or AirDrop the JSON, then send the unchanged original video separately.", systemImage: "checkmark.seal.fill")
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.brand)
                            .serveAISurface()
                    }
                    if let exportedMessage {
                        Text(exportedMessage)
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.mutedInk)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(ServeAITheme.body(.subheadline, size: 14))
                            .foregroundStyle(ServeAITheme.pink)
                            .serveAISurface()
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .serveAIBackground()
            .navigationTitle("Coach task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: captureSlotID) { _, slotID in
            let normalized = slotID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized.hasPrefix("slot-"),
                  let number = Int(normalized.dropFirst(5)),
                  let slot = CapturePlanSlot(number: number),
                  slot.slotID == normalized else { return }
            participantPseudonym = slot.participantPseudonym
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .json,
            defaultFilename: "serveai-coach-task-\(analysis.id.uuidString.lowercased())"
        ) { result in
            exportedMessage = (try? result.get()).map { "Saved \($0.lastPathComponent)" }
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func createTask() {
        isCreating = true
        errorMessage = nil
        exportedMessage = nil
        Task {
            do {
                guard let captureAssignment else {
                    throw CoachLabelingTaskError.invalidManifest("enter a valid capture slot and participant")
                }
                let manifest = try await service.createManifest(
                    for: analysis,
                    coordinatorPseudonym: trimmedCoordinator,
                    capturePlanAssignment: captureAssignment
                )
                let data = try service.encode(manifest)
                await MainActor.run {
                    document = CoachAnnotationDocument(data: data)
                    isCreating = false
                    isExporting = true
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var captureSlotField: some View {
        TextField("slot-001", text: $captureSlotID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Capture plan slot")
    }

    private var participantField: some View {
        TextField("participant-001", text: $participantPseudonym)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Participant pseudonym")
    }

    @ViewBuilder
    private func captureRequirementTags(_ slot: CapturePlanSlot) -> some View {
        GuideTag(text: slot.cameraAngle.title.uppercased())
        GuideTag(text: slot.skillLevel.title.uppercased())
        GuideTag(text: slot.resolution.title.uppercased())
        GuideTag(text: slot.frameRate.title.uppercased())
    }
}

private struct ReportDisclosure<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @State private var isExpanded: Bool
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, symbol: String, initiallyExpanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        _isExpanded = State(initialValue: initiallyExpanded)
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) { content }.padding(.top, 16)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(ServeAITheme.brand).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased()).font(ServeAITheme.display(.headline, size: 16)).foregroundStyle(ServeAITheme.ink)
                    Text(subtitle).font(ServeAITheme.body(.caption, size: 12)).foregroundStyle(ServeAITheme.mutedInk).lineLimit(2)
                }
            }
        }
        .serveAISurface()
    }
}

private struct PhaseScoreRow: View {
    let phase: PhaseScore
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(phase.phase.title).font(.subheadline.weight(.semibold))
                Spacer()
                if let score = phase.score { Text("\(score)/100").font(.subheadline.monospacedDigit().weight(.bold)) }
                else { Text("Insufficient visibility").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            if let score = phase.score {
                ProgressView(value: Double(score), total: 100).tint(ServeAITheme.brand)
            }
            Text(phase.note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct InsightDetail: View {
    let insight: CoachingInsight
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(insight.title).font(.title3.bold()); Spacer(); EvidenceQualityBadge(confidence: insight.confidence, contextLabel: "Visual evidence") }
            DetailPair(title: "What we saw", text: insight.observation)
            DetailPair(title: "Why it matters", text: insight.whyItMatters)
            DetailPair(title: "Next correction", text: insight.correction)
        }
        .padding(.vertical, 4)
    }
}

private struct DetailPair: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(ServeAITheme.brand)
            Text(text).font(.subheadline)
        }
    }
}

private struct DrillDetail: View {
    let number: Int
    let drill: RecommendedDrill
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(number)").font(.title2.bold()).foregroundStyle(ServeAITheme.brand).frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) { Text(drill.name).font(.headline); Text(drill.purpose).font(.subheadline).foregroundStyle(.secondary) }
            }
            ForEach(Array(drill.instructions.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").font(.subheadline).padding(.leading, 40)
            }
            Label(drill.dosage, systemImage: "repeat").font(.caption.weight(.semibold)).padding(.leading, 40)
            if let safety = drill.safetyNote { Label(safety, systemImage: "cross.case").font(.caption).foregroundStyle(.secondary).padding(.leading, 40) }
        }
    }
}

private struct MetricRow: View {
    let metric: TechnicalMetric
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(metric.title).font(.subheadline.weight(.semibold))
                Text(metric.context).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(metric.value).font(.subheadline.monospacedDigit().weight(.bold))
                Text("\(metric.confidence.title) evidence").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ConfidenceDetail: View {
    let confidence: AnalysisConfidence
    let metadata: VideoMetadata
    let source: AnalysisSource
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This measures whether the camera view and detected body joints are usable. It is not a probability that the score or coaching priority is correct.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            DetailPair(title: "Model assurance", text: "\(source.assuranceTitle). \(source.assuranceDetail)")
            Divider()
            ConfidenceBar(title: "Visibility", value: confidence.visibilityScore)
            ConfidenceBar(title: "Pose quality", value: confidence.poseDetectionQuality)
            ConfidenceBar(title: "Camera suitability", value: confidence.cameraSuitability)
            Divider()
            HStack { Text("Usable frames"); Spacer(); Text("\(confidence.usableFrameCount) of \(metadata.sampledFrames)").monospacedDigit() }.font(.subheadline)
            HStack { Text("Video"); Spacer(); Text("\(Int(metadata.duration.rounded())) sec · \(Int(metadata.nominalFrameRate.rounded())) FPS").monospacedDigit() }.font(.subheadline)
            if !confidence.missingAreas.isEmpty { DetailPair(title: "Often missing or obscured", text: confidence.missingAreas.joined(separator: ", ")) }
        }
    }
}

private struct ConfidenceBar: View {
    let title: String
    let value: Double
    var body: some View {
        HStack {
            Text(title).font(.subheadline).frame(width: 130, alignment: .leading)
            ProgressView(value: value).tint(ServeAITheme.brand)
            Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        ServeReportView(analysis: MockData.analysis())
            .environmentObject(AppViewModel())
    }
}
