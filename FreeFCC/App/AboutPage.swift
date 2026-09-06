import SwiftUI

struct AboutPage: View {
    @Environment(FccController.self) private var controller

    private let siteURL = URL(string: "https://www.andreapiani.com")!
    private let protocolURL = URL(string: "https://github.com/o-gs/dji-firmware-tools")!

    var body: some View {
        PageBackground {
            PageTitle(title: "About", symbol: "info.circle")

            GlowCard {
                Text("FCC Unlock for iOS")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                Text("FCC unlock and 500m altitude for DJI RC-N1 / RC-N2 / RC-N3")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cyan)
                    .padding(.bottom, 16)
                BodyText(
                    """
                    Switches the radio from CE to FCC mode on a DJI aircraft flown with a cabled \
                    controller, for higher power and more range, and sets the altitude ceiling to \
                    500m. No server, no account, no tracking. Every command is built on device \
                    from a JSON profile you can read on the Profile tab.

                    The first FCC unlock built natively for iPhone.
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
                    On iPhone the only link to a cabled controller is the MFi channel that DJI Fly \
                    itself uses. The controller is a certified accessory, the app opens an \
                    ExternalAccessory session on one of its protocol strings and gets a stream \
                    pair. On the RC-N3 that channel is com.dji.logiclink, one of two strings DJI \
                    does not document, read off the hardware rather than from a manual.

                    Over that stream the app speaks the DUML command protocol: it builds each \
                    frame, wraps it, keeps the session alive, and reads the aircraft's replies \
                    back through a parser that locks onto valid frames in a noisy video stream.
                    """
                )
            }

            GlowCard {
                Text("What it changes")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    FCC region, by setting the country code to US, which is what moves the radio \
                    to the higher-power band and is the same command DJI Fly sends every session.

                    Altitude ceiling, by writing the flight controller's max-height parameter to \
                    500m and enforcing it. 500m is DJI's own standard maximum, not an override \
                    beyond it.

                    Both are RAM-only and revert when the aircraft and controller are power \
                    cycled, so they are re-applied each session.
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
                    Each apply sweeps several command paths and logs how many responses came \
                    back, so a line like "profile@02/RCLink: 36 responses" names the path your \
                    hardware answered on. All paths at 0 means the controller is not relaying to \
                    the aircraft, usually because the drone is not linked yet, which is different \
                    from the region being refused. The green link line on the FCC tab shows when \
                    the aircraft is really there.
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
                ForEach(["RC-N3 (confirmed with DJI Neo)", "RC-N1 (same protocol)", "RC-N2 (same protocol)"], id: \.self) {
                    CheckRow(text: $0)
                }
                Text("Aircraft, the profile is universal")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.cyan.opacity(0.8))
                    .padding(.top, 12)
                ForEach([
                    "Mini 3 / Mini 3 Pro / Mini 4 Pro / Mini 5 Pro",
                    "Mini 2 / Mini 2 SE / Mini 4K / Mavic Mini",
                    "Air 3 / Air 3S / Mavic Air / Air 2 / Air 2S",
                    "Mavic 3 / Classic / Pro / Mavic 4 Pro",
                    "Avata / Avata 2 / FPV / Flip / Neo",
                    "Phantom 4 family / Inspire 2 / Spark"
                ], id: \.self) {
                    CheckRow(text: $0)
                }
            }

            GlowCard {
                Text("Disclaimer")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.red.opacity(0.9))
                    .padding(.bottom, 12)
                BodyText(
                    """
                    For educational and research purposes. Modifying radio transmission power or \
                    altitude limits may violate the law where you are. In most places, \
                    transmitting above the power permitted for your region, or flying above the \
                    permitted altitude, requires authorisation from the regulator. You are solely \
                    responsible for compliance. If you are not sure whether this is legal where \
                    you live, do not use it.

                    Not affiliated with, endorsed by, or sponsored by DJI. Using this may void \
                    your warranty and DJI Care Refresh coverage.
                    """
                )
                DividerLine().padding(.vertical, 16)
                InfoRow(label: "Version", value: "1.0")
                InfoRow(label: "License", value: "GPL-3.0")
                InfoRow(label: "Protocol", value: "DUML")
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
                    An app by Andrea Piani. The DUML command protocol it speaks is publicly \
                    documented by the dji-firmware-tools project, which is where the region and \
                    altitude commands were verified. The iOS app, its transport and its logic are \
                    original work, released under GPL-3.0.
                    """
                )
                DividerLine().padding(.vertical, 16)
                Link(destination: siteURL) {
                    InfoRow(label: "Author", value: "andreapiani.com", valueColor: Palette.cyan)
                }
                Link(destination: protocolURL) {
                    InfoRow(label: "Protocol docs", value: "dji-firmware-tools", valueColor: Palette.cyan)
                }
            }

            Text("© 2026 Andrea Piani · NIE Z2331796-S · Tijarafe, Santa Cruz de Tenerife · Islas Canarias")
                .font(.system(size: 10))
                .foregroundStyle(Palette.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }
}
