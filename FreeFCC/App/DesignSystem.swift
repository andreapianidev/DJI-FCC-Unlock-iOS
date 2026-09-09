// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import SwiftUI

/// The app palette: near-black navy ground, cyan for the primary action,
/// green for "the radio took it", amber for work in progress, red for failure.
enum Palette {
    static let bgDark = Color(red: 0.027, green: 0.039, blue: 0.078)     // #070A14
    static let bgMid = Color(red: 0.051, green: 0.071, blue: 0.125)      // #0D1220
    static let bgLight = Color(red: 0.071, green: 0.094, blue: 0.188)    // #121830
    static let cardBg = Color(red: 0.063, green: 0.086, blue: 0.165)     // #10162A
    static let cardBorder = Color(red: 0.110, green: 0.157, blue: 0.282) // #1C2848
    static let cyan = Color(red: 0.310, green: 0.765, blue: 0.969)       // #4FC3F7
    static let green = Color(red: 0.204, green: 0.827, blue: 0.600)      // #34D399
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)      // #F59E0B
    static let red = Color(red: 0.937, green: 0.267, blue: 0.267)        // #EF4444
    static let textWhite = Color(red: 0.941, green: 0.957, blue: 1.0)    // #F0F4FF
    static let textGray = Color(red: 0.478, green: 0.522, blue: 0.639)   // #7A85A3
    static let textDim = Color(red: 0.290, green: 0.325, blue: 0.455)    // #4A5374

    /// Page background: vertical wash plus a cyan bloom behind the header.
    static var pageGradient: LinearGradient {
        LinearGradient(colors: [bgDark, bgMid, bgDark], startPoint: .top, endPoint: .bottom)
    }
}

/// Card with the border and radius every panel in the app shares.
struct GlowCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.cardBg, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Palette.cardBorder, lineWidth: 1)
        )
    }
}

/// Full-width action button, filled for the primary action on a screen and
/// outlined for everything secondary.
struct GlowButton: View {
    let title: String
    var tint: Color = Palette.cyan
    var filled = true
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .kerning(0.5)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .foregroundStyle(filled ? Palette.bgDark : tint)
                .background(filled ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(tint.opacity(filled ? 0.3 : 0.6), lineWidth: filled ? 1 : 1.5)
                )
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Body copy at the one size the app uses for it.
struct BodyText: View {
    let text: String
    var color: Color = Palette.textGray

    init(_ text: String, color: Color = Palette.textGray) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(6)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label on the left, value on the right, one line.
struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = Palette.textWhite

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textGray)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct DividerLine: View {
    var opacity: Double = 0.5

    var body: some View {
        Rectangle()
            .fill(Palette.cardBorder.opacity(opacity))
            .frame(height: 1)
    }
}

/// Section heading used at the top of the secondary tabs.
struct PageTitle: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Palette.cyan)
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.textWhite)
            Spacer()
        }
    }
}

/// Ticked list item, used for the compatibility lists.
struct CheckRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.green)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Palette.textGray)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
