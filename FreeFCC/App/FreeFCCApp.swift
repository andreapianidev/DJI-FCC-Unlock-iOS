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
    /// Launching with `-initialTab N` opens tab N (0 FCC, 1 Log, 2 Profile,
    /// 3 Experimental, 4 About); the default is FCC. This is how the README
    /// screenshots are taken from a headless simulator:
    /// `xcrun simctl launch <udid> com.andreapiani.freefcc -initialTab 4`.
    @State private var selection = UserDefaults.standard.integer(forKey: "initialTab")

    var body: some View {
        TabView(selection: $selection) {
            FccPage()
                .tabItem { Label("FCC", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(0)
            LogPage()
                .tabItem { Label("Log", systemImage: "list.bullet.rectangle") }
                .tag(1)
            ProfilePage()
                .tabItem { Label("Profile", systemImage: "doc.text.magnifyingglass") }
                .tag(2)
            ExperimentalPage()
                .tabItem { Label("Experimental", systemImage: "flask") }
                .tag(3)
            AboutPage()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(4)
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

/// The version and build the bundle was built with, so every screen and the
/// log header show the same number and a bump only touches project.yml.
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    static var versionAndBuild: String { "\(version) (\(build))" }
}
