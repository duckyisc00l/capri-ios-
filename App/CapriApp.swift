import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Model downloads keep going in the background; the ModelManager session picks them up on launch.
        completionHandler()
    }
}

@main
struct CapriApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store: ChatStore
    @StateObject private var settings: Settings
    @StateObject private var models: ModelManager
    @StateObject private var voice: Voice
    @StateObject private var engine: ChatEngine

    init() {
        CrashReporter.install()
        Res.registerFont()
        let store = ChatStore()
        let settings = Settings()
        let models = ModelManager()
        let voice = Voice()
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _models = StateObject(wrappedValue: models)
        _voice = StateObject(wrappedValue: voice)
        _engine = StateObject(wrappedValue: ChatEngine(store: store, settings: settings, models: models, voice: voice))
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(models)
                .environmentObject(voice)
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.pink)
        }
    }
}
