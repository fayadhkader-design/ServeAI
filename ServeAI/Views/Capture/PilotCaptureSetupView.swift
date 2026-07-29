import SwiftUI

struct PilotCaptureSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppViewModel
    @State private var slotID = ""

    init() {
#if DEBUG
        _slotID = State(initialValue: ProcessInfo.processInfo.arguments.contains("-SERVEAI_PILOT_PREVIEW") ? "slot-001" : "")
#else
        _slotID = State(initialValue: "")
#endif
    }

    private var slot: CapturePlanSlot? {
        let normalized = slotID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("slot-"),
              let number = Int(normalized.dropFirst(5)),
              let slot = CapturePlanSlot(number: number),
              slot.slotID == normalized else { return nil }
        return slot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 7) {
                    Text("PILOT DATA CAPTURE")
                        .font(ServeAITheme.display(.title2, size: 24))
                    Text("Load the assigned frozen slot before recording. ServeAI will lock its participant, view, skill cohort, and video format so the sample cannot drift into another split.")
                        .font(ServeAITheme.body(.body, size: 15))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }

                VStack(alignment: .leading, spacing: 9) {
                    Text("Capture slot")
                        .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))
                    TextField("slot-001", text: $slotID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(ServeAITheme.mono(.body, size: 16, bold: true))
                        .padding(14)
                        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ServeAITheme.separator) }
                        .accessibilityHint("Enter slot-001 through slot-300")
                }

                if let slot {
                    slotDetails(slot)
                } else {
                    Label("Enter an exact slot from slot-001 through slot-300.", systemImage: "number.square")
                        .font(ServeAITheme.body(.subheadline, size: 14))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }

                Button {
                    guard let slot else { return }
                    appModel.beginPilotCapture(slot)
                } label: {
                    Label("LOAD SLOT AND CONTINUE", systemImage: "arrow.right")
                }
                .buttonStyle(ServeAIPrimaryButtonStyle())
                .disabled(slot == nil)
                .accessibilityHint("Locks this slot and opens its recording instructions")
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .serveAIBackground()
        .toolbar(.hidden, for: .navigationBar)
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
            Text("COLLECTION SETUP")
                .font(ServeAITheme.display(.title3, size: 19))
            Spacer()
        }
    }

    private func slotDetails(_ slot: CapturePlanSlot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(slot.participantPseudonym, systemImage: "person.crop.circle.fill")
                Spacer()
                Text(slot.split.uppercased())
                    .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                    .foregroundStyle(ServeAITheme.cyan)
            }
            .font(ServeAITheme.body(.subheadline, size: 14, weight: .semibold))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { requirementTags(slot) }
                VStack(alignment: .leading, spacing: 6) { requirementTags(slot) }
            }

            Divider().overlay(ServeAITheme.separator)

            VStack(alignment: .leading, spacing: 7) {
                requirement("Hand", slot.dominantHand.title)
                requirement("Setting", "\(slot.environment.title) · \(slot.lighting.title)")
                requirement("Contrast", slot.subjectContrast.title)
                requirement("Study device", slot.sourceDeviceModel)
            }

            if slot.isFailureExample {
                VStack(alignment: .leading, spacing: 6) {
                    Label("INTENTIONAL FAILURE EXAMPLE", systemImage: "waveform.path.ecg.rectangle")
                        .font(ServeAITheme.mono(.caption2, size: 9, bold: true))
                        .foregroundStyle(ServeAITheme.orange)
                    Text("Introduce \(slot.recordingIssueTags.map { $0.title.lowercased() }.joined(separator: ", ")) during only part of the clip. Keep at least two seconds with the server independently visible so an honest evidence sequence can be encoded. This capture is for usability training, not coaching.")
                        .font(ServeAITheme.body(.caption, size: 12))
                        .foregroundStyle(ServeAITheme.mutedInk)
                }
            }
        }
        .padding(16)
        .background(ServeAITheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ServeAITheme.separator) }
        .accessibilityElement(children: .contain)
    }

    private func requirement(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(ServeAITheme.mutedInk)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(ServeAITheme.body(.caption, size: 12, weight: .medium))
    }

    @ViewBuilder
    private func requirementTags(_ slot: CapturePlanSlot) -> some View {
        GuideTag(text: slot.cameraAngle.title.uppercased())
        GuideTag(text: slot.skillLevel.title.uppercased())
        GuideTag(text: slot.resolution.title.uppercased())
        GuideTag(text: slot.frameRate.title.uppercased())
    }
}

#Preview {
    NavigationStack {
        PilotCaptureSetupView()
            .environmentObject(AppViewModel())
    }
}
