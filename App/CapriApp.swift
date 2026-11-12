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
        Log.write("Swift started · \(Log.device())")
        CrashReporter.install()
        Log.write("crash catcher on")
        Res.registerFont()
        Log.write("font registered, resources at \(Res.dir.path) exists=\(FileManager.default.fileExists(atPath: Res.dir.path))")
        Log.write("texts: \(Texts.shared.languages.count) languages")
        let store = ChatStore()
        Log.write("chats loaded: \(store.chats.count)")
        let settings = Settings()
        Log.write("settings loaded · lang=\(settings.lang) brain=\(settings.brain)")
        let models = ModelManager()
        Log.write("models: \(models.installed.map(\.file))")
        let voice = Voice()
        Log.write("voice ready")
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _models = StateObject(wrappedValue: models)
        _voice = StateObject(wrappedValue: voice)
        _engine = StateObject(wrappedValue: ChatEngine(store: store, settings: settings, models: models, voice: voice))
        Log.write("app objects ready, showing UI")
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
