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
                Text("Step 2: a staged change")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textDim)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    Not enabled yet. It unlocks only after step 1 shows the parameters are \
                    readable on this aircraft and we have seen the firmware's own maximum. Then \
                    a single small increase, verified in flight, before any further step.
                    """,
                    color: Palette.textDim
                )
            }
        }
    }
}
