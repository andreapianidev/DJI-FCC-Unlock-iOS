// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import SwiftUI

/// Activity log. This is the tab that matters when something does not work:
/// the per-path response counts tell you whether the controller answered at
/// all, which is a different failure from FCC being rejected.
struct LogPage: View {
    @Environment(FccController.self) private var controller

    var body: some View {
        PageBackground {
            HStack {
                PageTitle(title: "Activity Log", symbol: "list.bullet.rectangle")
                if !controller.logMessages.isEmpty {
                    ShareLink(item: controller.logExport) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Palette.cyan)
                    }
                    Button {
                        controller.clearLog()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Palette.textDim)
                    }
                }
            }

            GlowCard {
                if controller.logMessages.isEmpty {
                    BodyText("No activity yet.", color: Palette.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 40)
                } else {
                    ForEach(Array(controller.logMessages.enumerated()), id: \.offset) { index, entry in
                        if index > 0 {
                            DividerLine(opacity: 0.3).padding(.vertical, 2)
                        }
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Self.color(for: entry))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private static func color(for entry: String) -> Color {
        let lower = entry.lowercased()
        if lower.contains("fail") || lower.contains("error") || lower.contains("no responses") {
            return Palette.red
        }
        if lower.contains("applied") || lower.contains("connected") || lower.contains("restored") || lower.contains("answered") {
            return Palette.green
        }
        if lower.contains("enabling") || lower.contains("restoring") || lower.contains("sweeping") || lower.contains("not declared") {
            return Palette.amber
        }
        return Palette.cyan.opacity(0.7)
    }
}
