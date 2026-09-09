// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
// FreeFCC for iOS. Free for noncommercial use only. See LICENSE and NOTICE.md.
// Attribution required; do not present this work as your own.
//

import ExternalAccessory
import SwiftUI

@main
struct FreeFCCApp: App {
    @State private var controller = FccController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(controller)
                .preferredColorScheme(.dark)
                .tint(Palette.cyan)
                .task { controller.start() }
                .onReceive(NotificationCenter.default.publisher(for: .EAAccessoryDidConnect)) { _ in
                    controller.refreshAccessories()
                }
                .onReceive(NotificationCenter.default.publisher(for: .EAAccessoryDidDisconnect)) { _ in
                    controller.accessoryDisconnected()
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            FccPage()
                .tabItem { Label("FCC", systemImage: "antenna.radiowaves.left.and.right") }
            LogPage()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
            ProfilePage()
                .tabItem { Label("Profile", systemImage: "doc.text.magnifyingglass") }
            ExperimentalPage()
                .tabItem { Label("Experimental", systemImage: "flask") }
            AboutPage()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}

/// Shared scaffolding for every tab: the dark wash, the cyan bloom behind the
/// header, and a scroll view that keeps clear of the tab bar.
struct PageBackground<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Palette.pageGradient
                .ignoresSafeArea()
            RadialGradient(
                colors: [Palette.cyan.opacity(0.10), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
            .frame(height: 380)
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
        }
    }
}
