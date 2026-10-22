import SwiftUI

@main
struct MeetingNotesApp: App {
    @StateObject private var controller = PhoneController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environmentObject(controller)
                .onAppear { controller.onAppear() }
                .onChange(of: scenePhase) { _, phase in
                    controller.setForeground(phase == .active)
                }
        }
    }
}
