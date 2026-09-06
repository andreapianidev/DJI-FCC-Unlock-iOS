import SwiftUI

struct AboutPage: View {
    @Environment(FccController.self) private var controller

    var body: some View {
        PageBackground {
            PageTitle(title: "About", symbol: "info.circle")

            GlowCard {
                Text("FreeFCC for iOS")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                Text("Open-source FCC unlock for DJI RC-N1 / RC-N2 / RC-N3")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cyan)
                    .padding(.bottom, 16)
                BodyText(
                    """
                    Switches the radio from CE to FCC mode on a DJI aircraft flown with a cabled \
                    controller. No server, no license, no tracking. Just raw DUMPL commands built \
                    from a JSON profile you can read on the Profile tab.
                    """
                )
            }

            GlowCard {
                Text("How it reaches the controller")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    The Android build talks to the controller in USB accessory mode (AOA), where \
                    the controller is the USB host and the phone is the accessory. iOS has no AOA. \
                    What it has is the MFi channel that DJI Fly itself uses: the controller is a \
                    certified accessory, the app opens an EASession on one of its protocol strings \
                    and gets a stream pair.

                    Everything above that stream is unchanged from the Android build. Same DUMPL \
                    frames, same CRC tables, same RCLink envelope, same bootstrap handshake, same \
                    2.5 second keepalive, same 21-frame profile.
                    """
                )
            }

            GlowCard {
                Text("Reading the Log tab")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    Each apply sweeps several command paths, because which sender byte and which \
                    framing the radio accepts varies across aircraft, controller and phone. Every \
                    pass logs how many responses came back, so a line like \
                    "profile@82/RCLink: 3 responses" names the path your hardware answered on.

                    All paths at 0 responses means the controller is not relaying to the aircraft \
                    at all, which is a different problem from FCC being rejected. That is the case \
                    worth reporting, together with the Hardware card's protocol list.
                    """
                )
            }

            GlowCard {
                Text("Supported")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                Text("Controllers")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cyan.opacity(0.8))
                ForEach(["RC-N1 (USB cabled to phone)", "RC-N2 (USB cabled to phone)", "RC-N3 (USB cabled to phone)"], id: \.self) {
                    CheckRow(text: $0)
                }
                Text("Aircraft, the profile is universal")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cyan.opacity(0.8))
                    .padding(.top, 12)
                ForEach([
                    "Mini 3",
                    "Mini 3 Pro / Mini 4 Pro / Mini 5 Pro",
                    "Mini 2 / Mini 2 SE / Mini 4K / Mavic Mini",
                    "Air 3 / Air 3S / Mavic Air / Air 2 / Air 2S",
                    "Mavic 3 / Classic / Pro / Mavic 4 Pro",
                    "Mavic Pro series / Mavic 2 Pro and Zoom",
                    "Avata / Avata 2 / FPV / FPV 2 / Flip / Neo / Neo 2",
                    "Phantom 4 family / Inspire 2 / Spark"
                ], id: \.self) {
                    CheckRow(text: $0)
                }
            }

            GlowCard {
                Text("Not tested on real hardware")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.amber)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    Neither this port nor the Android original has been confirmed on a live \
                    aircraft. The DUMPL frames come from the publicly documented dji-firmware-tools \
                    protocol. Whether the controller's MFi channel accepts them the way its USB \
                    accessory channel does is the open question this build exists to answer, and \
                    the Log tab is what answers it.
                    """
                )
            }

            GlowCard {
                Text("Disclaimer")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.red.opacity(0.9))
                    .padding(.bottom, 12)
                BodyText(
                    """
                    For educational and research purposes. Modifying radio transmission parameters \
                    may violate the law where you are. In most places, transmitting above the power \
                    permitted for your region requires authorisation from the regulator. You are \
                    solely responsible for compliance. If you are not sure whether FCC mode is legal \
                    where you live, do not use this.

                    Not affiliated with, endorsed by, or sponsored by DJI. Using this may void your \
                    warranty and DJI Care Refresh coverage.
                    """
                )
                DividerLine().padding(.vertical, 16)
                InfoRow(label: "Version", value: "1.0 (iOS)")
                InfoRow(label: "License", value: "AGPL-3.0")
                InfoRow(label: "Protocol", value: "DUMPL")
                InfoRow(label: "Transport", value: "MFi ExternalAccessory")
                InfoRow(label: "Server", value: "None, fully offline")
                if !controller.protocolInUse.isEmpty {
                    InfoRow(label: "Open protocol", value: controller.protocolInUse, valueColor: Palette.green)
                }
            }

            GlowCard {
                Text("Credits")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    iOS port of FreeFCC USB by doesthings, licensed AGPL-3.0. The DUMPL protocol \
                    implementation derives from the publicly documented dji-firmware-tools project \
                    (GPL-3.0). This port keeps the same license, and its source has to be offered \
                    to anyone it is distributed to.
                    """
                )
                DividerLine().padding(.vertical, 16)
                Link(destination: URL(string: "https://github.com/doesthings/FreeFCC-USB")!) {
                    InfoRow(label: "Upstream", value: "github.com/doesthings/FreeFCC-USB", valueColor: Palette.cyan)
                }
                Link(destination: URL(string: "https://github.com/o-gs/dji-firmware-tools")!) {
                    InfoRow(label: "Protocol docs", value: "github.com/o-gs/dji-firmware-tools", valueColor: Palette.cyan)
                }
            }
        }
    }
}
