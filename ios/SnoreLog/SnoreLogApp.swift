import SwiftUI
@main struct SnoreLogApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state).task {
                #if DEBUG
                state.runDemoIfRequested()
                #endif
                state.setForeground(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in state.setForeground(phase == .active) }
        }
    }
}
