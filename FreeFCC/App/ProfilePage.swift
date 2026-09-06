import SwiftUI

/// Every byte the app will send, listed. The profile is a plain JSON file in
/// the bundle, and this tab is it rendered rather than summarised, so nothing
/// about what goes on the wire has to be taken on trust.
struct ProfilePage: View {
    @Environment(FccController.self) private var controller

    var body: some View {
        PageBackground {
            PageTitle(title: "Profile", symbol: "doc.text.magnifyingglass")

            if let profile = controller.profile {
                GlowCard {
                    Text(profile.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Palette.textWhite)
                        .padding(.bottom, 10)
                    BodyText(profile.summary)
                        .padding(.bottom, 16)
                    InfoRow(label: "Frames", value: "\(profile.frames.count)")
                    InfoRow(label: "Rounds", value: "\(profile.rounds)")
                    InfoRow(label: "Inter-frame delay", value: "\(profile.interFrameDelayMs) ms")
                    InfoRow(label: "Inter-round delay", value: "\(profile.interRoundDelayMs) ms")
                    InfoRow(label: "Repeat interval", value: "\(profile.repeatIntervalMs) ms")
                    InfoRow(label: "Sender", value: String(format: "0x%02X", profile.sender))
                    InfoRow(label: "Command type", value: String(format: "0x%02X", profile.cmdType))
                }

                GlowCard {
                    Text("Timing")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.textWhite)
                        .padding(.bottom, 10)
                    BodyText(
                        """
                        Frame 1 opens the service-mode window and the last frame closes it. \
                        Everything in between has to land inside that window, which is why the \
                        profile uses a \(profile.interFrameDelayMs)ms inter-frame delay: one round \
                        takes about \(String(format: "%.2f", Double(profile.frames.count * profile.interFrameDelayMs) / 1000))s. \
                        Stretch the sequence over several seconds and the radio silently stays on \
                        CE even though every write succeeded.
                        """
                    )
                }

                ForEach(Array(profile.frames.enumerated()), id: \.offset) { index, frame in
                    FrameCard(index: index + 1, frame: frame, profile: profile)
                }
            } else {
                GlowCard {
                    BodyText("The profile could not be loaded from the app bundle.", color: Palette.red)
                }
            }
        }
    }
}

private struct FrameCard: View {
    let index: Int
    let frame: ProfileFrame
    let profile: Profile

    /// The frame as it goes on the wire, built with sequence 0 so the preview
    /// stays stable between redraws.
    private var wireHex: String {
        let bytes = DumplBuilder.buildFrame(
            DumplFrame(
                sender: profile.sender,
                cmdType: profile.cmdType,
                cmdSet: frame.cmdSet,
                cmdId: frame.cmdId,
                dst: frame.dst,
                payload: frame.payload
            ),
            seq: 0
        )
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var body: some View {
        GlowCard {
            HStack(alignment: .top, spacing: 12) {
                Text("\(index)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundStyle(Palette.bgDark)
                    .frame(width: 26, height: 26)
                    .background(Palette.cyan.opacity(0.85), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(frame.note)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.textWhite)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("set \(frame.cmdSet) · id \(frame.cmdId) · dst \(frame.dst)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.textGray)
                    if !frame.payload.isEmpty {
                        Text(frame.payloadHex)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.amber.opacity(0.85))
                    }
                    Text(wireHex)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.textDim)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
