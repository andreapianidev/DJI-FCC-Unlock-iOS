import SwiftUI

/// Experimental flight-parameter tools, kept on their own tab and behind a
/// warning so nothing here is a stray tap away.
///
/// Step one is read only. It reads the attitude parameters that cap horizontal
/// speed, and the bounds the firmware enforces on them, so any later change is
/// informed by the drone's own limits rather than a number from a video.
struct ExperimentalPage: View {
    @Environment(FccController.self) private var controller

    var body: some View {
        PageBackground {
            PageTitle(title: "Experimental", symbol: "flask")

            GlowCard {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.amber)
                    Text("Flight-safety territory")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.amber)
                }
                .padding(.bottom, 12)
                BodyText(
                    """
                    These parameters change how the aircraft flies, not just what region it \
                    reports. Unlike the FCC and altitude settings, a wrong value here can make \
                    the drone hard to control or unstable. Everything on this tab is read only \
                    for now: it inspects the flight controller, it does not change it.

                    Read first, understand the numbers, then decide. Any change that comes later \
                    will be small, staged, and tested low and slow in open space.
                    """,
                    color: Palette.textGray
                )
            }

            GlowCard {
                Text("Goal: 60 km/h on Sport")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 12)
                BodyText(
                    """
                    The DJI Neo tops out near 60 km/h in manual mode with the goggles, but the \
                    controller's Sport mode keeps a tighter attitude envelope and so a lower \
                    speed. The lever is the attitude range: how far the aircraft may tilt. \
                    Reading it, and the firmware's own maximum for it, tells us whether the \
                    controller modes can be brought up toward that 60 km/h without going past \
                    what the flight controller already considers valid.
                    """
                )
            }

            GlowCard {
                Text("Step 1: read the parameters")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    Sends only read commands. For each parameter it reports the current value \
                    and the min, max and default the firmware enforces. Results go to the Log \
                    tab. Connect with the drone linked first, so the flight controller is there \
                    to answer.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Read Attitude Parameters (safe)", tint: Palette.green, filled: false) {
                        controller.probeSpeedParams()
                    }
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }

            GlowCard {
                Text("Step 2: hunt the 500m gate")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    Writing max_height to 500 is accepted but the drone stores 120, so a \
                    different parameter gates the ceiling. This probe writes one altitude or geo \
                    limit candidate at a time and reads back the value the drone actually stored, \
                    so we can find the one that opens the DJI Fly slider past 120. Results go to \
                    the Log tab. After it runs, open DJI Fly and check the altitude slider.

                    It writes limit parameters only, never a flight-control one. Restore CE or a \
                    power cycle undoes every write.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Probe 500m Gate (writes limits)", tint: Palette.amber, filled: false) {
                        controller.probeAltitudeGate()
                    }
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }

            GlowCard {
                Text("Read via 0xFB")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    A pure read over the 0xFB verb, the one this firmware may still answer after \
                    0xF7/0xF8 came back silent. It reads the authority and geo values behind the \
                    500m gate and the attitude ranges that cap Sport speed, with their firmware \
                    bounds, writing nothing. Results go to the Log tab.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Read via 0xFB (safe)", tint: Palette.green, filled: false) {
                        controller.probeReadFB()
                    }
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }

            GlowCard {
                Text("Read flight telemetry")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    Decodes the latest OSD frame the flight controller pushes: ground speed, \
                    height and flight mode. Fly in Sport and push full stick, then read this to \
                    see the real km/h and whether the mode is limited. Reads only, sends nothing.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Read Flight Telemetry (safe)", tint: Palette.green, filled: false) {
                        controller.readTelemetry()
                    }
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }
        }
    }
}
