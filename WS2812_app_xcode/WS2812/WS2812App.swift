//
//  WS2812App.swift
//  WS2812
//
//  Created by isaac on 12/15/25.
//

import SwiftUI
import UIKit
import Darwin

final class AppDelegate: NSObject, UIApplicationDelegate {
    #if targetEnvironment(macCatalyst)
    func applicationShouldTerminateAfterLastWindowClosed(_ application: UIApplication) -> Bool {
        true
    }
    #endif
}

@main
struct WS2812App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .background else {
                        return
                    }
                    exit(EXIT_SUCCESS)
                }
        }
    }
}
