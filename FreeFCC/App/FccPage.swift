import SwiftUI

/// The main control surface: connection state, current radio mode, and the one
/// button that matters at any given moment.
struct FccPage: View {
    @Environment(FccController.self) private var controller

    var body: some View {
        @Bindable var controller = controller

        PageBackground {
            AppHeader(kind: controller.transportKind)
            ConnectionPill(status: controller.status, isConnected: controller.isConnected)

            GlowCard {
                ModeBadge(isFccEnabled: controller.isFccEnabled)
                    .padding(.bottom, 20)
                actionSection
            }

            if !controller.accessories.isEmpty {
                accessoryCard
            }

            settingsCard($controller.autoFcc, $controller.framingMode)
        }
    }

    // MARK: Action section

    @ViewBuilder
    private var actionSection: some View {
        if controller.isBusy {
            ProgressDisplay(progress: controller.busyProgress, label: controller.message)
        } else if controller.status == .released {
            BodyText(
                """
                Session released. Open DJI Fly and check Transmission, it should read FCC.

                If it reads CE, come back, reconnect and apply again. Some aircraft also drop \
                to CE the moment they set the home point on GPS lock, so it can need a second \
                pass once you are outside.
                """,
                color: Palette.green
            )
            .padding(.bottom, 20)
            GlowButton(title: "Reconnect") { controller.connect() }
        } else if !controller.isConnected {
            BodyText(
                """
                Plug the phone into the TOP USB port of the RC-N1, RC-N2 or RC-N3, the one you \
                normally use for DJI Fly, then tap Connect. Close DJI Fly first. Connect keeps \
                looking for 15 seconds, so you can also tap it and close DJI Fly afterwards.
                """
            )
            .padding(.bottom, 20)
            GlowButton(title: "Connect") { controller.connect() }
        } else if controller.isFccEnabled {
            BodyText(
                """
                FCC applied. Re-applying every few seconds to hold it, which keeps working while \
                this app is in the background.

                If DJI Fly cannot see the controller, tap Release to hand the link back without \
                unplugging the cable.
                """,
                color: Palette.green
            )
            .padding(.bottom, 20)
            VStack(spacing: 12) {
                GlowButton(title: "Release for DJI Fly", tint: Palette.green) { controller.releaseSession() }
                GlowButton(title: "Re-apply FCC", filled: false) { controller.enableFcc() }
                GlowButton(title: "Restore CE Mode", tint: Palette.red, filled: false) { controller.disableFcc() }
            }
        } else {
            BodyText(controller.message.isEmpty ? "Tap the button below to enable FCC mode." : controller.message)
                .padding(.bottom, 20)
            VStack(spacing: 12) {
                GlowButton(title: "Enable FCC Mode") { controller.enableFcc() }
                GlowButton(title: "Release Session", tint: Palette.textGray, filled: false) { controller.releaseSession() }
            }
        }
    }

    // MARK: Cards

    private var accessoryCard: some View {
        GlowCard {
            Text("Hardware")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Palette.textWhite)
                .padding(.bottom, 12)

            ForEach(controller.accessories) { accessory in
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        label: accessory.manufacturer.isEmpty ? "Accessory" : accessory.manufacturer,
                        value: accessory.modelNumber.isEmpty ? accessory.name : accessory.modelNumber,
                        valueColor: accessory.looksLikeDji ? Palette.green : Palette.textWhite
                    )
                    if !accessory.firmwareRevision.isEmpty {
                        InfoRow(label: "Firmware", value: accessory.firmwareRevision)
                    }
                    ForEach(accessory.openableProtocols, id: \.self) { proto in
                        InfoRow(
                            label: proto == controller.protocolInUse ? "Protocol (open)" : "Protocol",
                            value: proto,
                            valueColor: proto == controller.protocolInUse ? Palette.green : Palette.textGray
                        )
                    }
                    ForEach(accessory.undeclaredProtocols, id: \.self) { proto in
                        InfoRow(label: "Not declared", value: proto, valueColor: Palette.amber)
                    }
                }
                .padding(.bottom, 8)
            }

            if !controller.detectedSerial.isEmpty {
                DividerLine().padding(.vertical, 8)
                InfoRow(label: "Aircraft", value: controller.detectedSerial, valueColor: Palette.green)
            }
            if let winner = controller.winningPath {
                DividerLine().padding(.vertical, 8)
                InfoRow(label: "Answered on", value: winner.label, valueColor: Palette.green)
            }
        }
    }

    private func settingsCard(_ autoFcc: Binding<Bool>, _ framing: Binding<FramingMode>) -> some View {
        GlowCard {
            Toggle(isOn: autoFcc) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-FCC")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textWhite)
                    Text("Connect and enable FCC as soon as the app opens.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.textGray)
                }
            }
            .tint(Palette.cyan)

            DividerLine().padding(.vertical, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("Framing")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                Text(
                    """
                    Which wrapper goes around each DUMPL frame. The controller decides, not iOS, \
                    so leave this on Sweep until the Log shows which one answers.
                    """
                )
                .font(.system(size: 12))
                .foregroundStyle(Palette.textGray)
                Picker("Framing", selection: framing) {
                    ForEach(FramingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 4)
            }
        }
    }
}

// MARK: Header

private struct AppHeader: View {
    let kind: String
    @State private var glow = 0.5

    var body: some View {
        VStack(spacing: 6) {
            Text("FreeFCC")
                .font(.system(size: 30, weight: .black))
                .kerning(0.5)
                .foregroundStyle(Palette.cyan.opacity(glow))
                .shadow(color: Palette.cyan.opacity(glow * 0.5), radius: 18)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true)) {
                        glow = 0.95
                    }
                }
            Text(kind.isEmpty ? "v1.0 for iOS" : "v1.0 for iOS · \(kind)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.textDim)
        }
        .padding(.top, 8)
    }
}

private struct ConnectionPill: View {
    let status: AppStatus
    let isConnected: Bool

    private var label: String {
        switch status {
        case .connecting: return "Connecting..."
        case .released: return "Released"
        default: return isConnected ? "Connected" : "Disconnected"
        }
    }

    private var color: Color {
        switch status {
        case .connecting: return Palette.amber
        case .released: return Palette.amber
        default: return isConnected ? Palette.green : Palette.textGray
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(color.opacity(0.1), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        .shadow(color: isConnected ? color.opacity(0.35) : .clear, radius: 14)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: isConnected)
    }
}

private struct ModeBadge: View {
    let isFccEnabled: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MODE")
                    .font(.system(size: 10, weight: .black))
                    .kerning(2)
                    .foregroundStyle(Palette.textDim)
                Text(isFccEnabled ? "FCC" : "CE")
                    .font(.system(size: 30, weight: .black))
                    .foregroundStyle(isFccEnabled ? Palette.green : Palette.textWhite)
                    .contentTransition(.numericText())
                Text(isFccEnabled ? "High-power region active" : "Default region")
                    .font(.system(size: 12))
                    .foregroundStyle(isFccEnabled ? Palette.green.opacity(0.7) : Palette.textGray)
            }
            Spacer()
            Image(systemName: isFccEnabled ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: isFccEnabled ? 40 : 32))
                .foregroundStyle(isFccEnabled ? Palette.green : Palette.textDim)
                .symbolEffect(.bounce, value: isFccEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: isFccEnabled
                    ? [Color(red: 0.039, green: 0.145, blue: 0.251), Color(red: 0.055, green: 0.188, blue: 0.314)]
                    : [Palette.bgLight.opacity(0.4), Palette.bgLight.opacity(0.2)],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.65), value: isFccEnabled)
    }
}

private struct ProgressDisplay: View {
    let progress: Double
    let label: String

    var body: some View {
        VStack(spacing: 10) {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.cyan)
                .multilineTextAlignment(.center)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.bgLight)
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.cyan, Palette.green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geometry.size.width * progress))
                }
            }
            .frame(height: 8)
            Text("\(Int(progress * 100))%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.textGray)
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.15), value: progress)
    }
}
