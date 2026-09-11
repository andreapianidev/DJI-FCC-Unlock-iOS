// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import SwiftUI

/// Experimental flight-parameter tools, kept on their own tab and behind a
/// warning so nothing here is a stray tap away.
///
/// Green buttons only read: the 0xF7/0xF8 and 0xFB probes, the telemetry
/// decode and the flight recorder. Three buttons write: the amber altitude-gate
/// probe writes altitude/geo limits, the red Sport boost writes the Sport
/// flight-control block (ground only, then a low-and-slow flight test) and the
/// amber Restore Sport Defaults puts that block back. FCC and altitude writes
/// are RAM-only; the Sport block may persist across a power cycle.
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
                    the drone hard to control or unstable.

                    Green buttons only read and are safe. The amber ones write altitude and geo \
                    limits, or put the Sport block back to stock. The red one writes \
                    flight-control parameters, runs only with the drone on the ground, and must \
                    be flown low and slow in open space. FCC and altitude writes are RAM-only: \
                    Restore CE or a power cycle resets them. Sport-block writes may survive a \
                    power cycle, so undo them with Restore Sport Defaults.
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
                    The DJI Neo tops out near 60 km/h in manual mode with the goggles, while \
                    the controller's Sport mode stops at 28.8 km/h. On DJI's current flight \
                    controllers each mode has its own config block, and Sport top speed is that \
                    block's max tilt. Up to v1.7 the app wrote older global parameters this Neo \
                    does not have: every write came back as a bare reply and nothing was \
                    stored. The boost now targets the Sport block and reads back what the \
                    drone keeps.
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

            GlowCard {
                Text("Record a Sport flight (measure peak km/h)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.textWhite)
                    .padding(.bottom, 6)
                BodyText(
                    """
                    The ground truth for the speed goal. Tap this, then fly Sport with full \
                    stick forward in open space for about half a minute. The app watches the \
                    drone's own telemetry and records the peak horizontal speed, so we measure \
                    the real km/h without opening DJI Fly, which would reset our writes. Reads \
                    only, sends nothing. The peak lands in the Log tab at the end, with the tilt \
                    flown at that moment: a tilt well below the one stored means a separate \
                    velocity limit, not the tilt, is holding Sport back.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Record Sport Flight (safe, 30s)", tint: Palette.green, filled: false) {
                        controller.recordFlight()
                    }
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }

            GlowCard {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.red)
                    Text("Sport-speed boost (writes control)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.red)
                }
                .padding(.bottom, 10)
                BodyText(
                    """
                    Resets the Sport block to stock, reads the factory tilt if the drone \
                    reports it, then writes stock + 10 degrees (never above 40) and full-stick \
                    scaling 1.0. Up to v1.7 this button wrote older global parameters this Neo \
                    does not have, so nothing was stored. The Log now says, per parameter, \
                    whether it exists on this firmware, what the drone stored, and whether it \
                    clamped the value to its own ceiling. The drone must be on the ground. Then \
                    record a Sport flight, low and slow in open space: handling and braking \
                    distance change.
                    """,
                    color: Palette.textGray
                )
                .padding(.bottom, 14)
                if controller.isConnected {
                    GlowButton(title: "Boost Sport Speed (on the ground)", tint: Palette.red, filled: false) {
                        controller.applySpeedBoost()
                    }
                    GlowButton(title: "Restore Sport Defaults", tint: Palette.amber, filled: false) {
                        controller.restoreSportDefaults()
                    }
                    .padding(.top, 10)
                } else {
                    BodyText("Connect on the FCC tab first.", color: Palette.textDim)
                }
            }
        }
    }
}
