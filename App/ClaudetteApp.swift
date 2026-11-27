import SwiftUI
import UserNotifications
import CoreSpotlight

@main
struct ClaudetteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)   // #d97757
    static let bg = Color(red: 0.12, green: 0.118, blue: 0.114)     // #1f1e1d
    static let card = Color(red: 0.17, green: 0.165, blue: 0.16)
    static let userBubble = Color(red: 0.26, green: 0.25, blue: 0.24)
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Store.shared.sendPushToken(hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Store.shared.pushNote = "Push not registered: \(error.localizedDescription)" }
    }

    // Banner while the app is open, unless that session is already on screen.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let sid = notification.request.content.userInfo["sid"] as? String
        let showing = await MainActor.run { Store.shared.path.last }
        return sid != nil && sid == showing ? [] : [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let sid = response.notification.request.content.userInfo["sid"] as? String {
            await MainActor.run { Store.shared.open(sid) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if store.configured {
                NavigationStack(path: $store.path) {
                    SessionListView()
                        .navigationDestination(for: String.self) { SessionView(id: $0).id($0) } // fresh view state per session: a notification tap never shows another session's draft
                }
            } else {
                SetupView()
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: phase) { _, p in
            if p == .active { store.foreground() } else { store.background() }
        }
        .onAppear { store.foreground() }
        // A session picked from Spotlight search.
        .onContinueUserActivity(CSSearchableItemActionType) { a in
            if let id = a.userInfo?[CSSearchableItemActivityIdentifier] as? String { store.open(id) }
        }
    }
}
