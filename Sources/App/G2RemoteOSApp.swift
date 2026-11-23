import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Initialize CoreBluetooth + Flic background manager + live services immediately on launch.
        AppCoordinator.shared.bootstrap()
        return true
    }
}

@main
struct G2RemoteOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = AppCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.ble)
                .environmentObject(coordinator.flic)
                .environmentObject(coordinator.gamepad)
                .environmentObject(coordinator.os)
                .environmentObject(coordinator.backgroundKeeper)
                .environmentObject(coordinator.weather)
                .environmentObject(coordinator.calendar)
                .environmentObject(coordinator.pedometer)
                .environmentObject(coordinator.clockTools)
                .environmentObject(coordinator.spark)
                .environmentObject(coordinator.tailscale)
                .preferredColorScheme(.dark)
        }
    }
}
