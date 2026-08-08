import SwiftUI

@main
struct PerfMonitorApp: App {
    @StateObject private var engine = MonitorEngine()

    var body: some Scene {
        WindowGroup(id: "main") {
            DashboardView()
                .environmentObject(engine)
                // maxWidth/maxHeight matter here, not just min: without an
                // explicit max, SwiftUI falls back to the content's *ideal*
                // size as the window's effective ceiling, so the window
                // couldn't be grown past its default size at all. With these,
                // it correctly grows to fill whatever screen space is
                // available (verified by hand: shrinks down to the declared
                // 720x640 floor, grows up to the full screen, nothing in
                // between is refused).
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
                .onAppear { engine.start() }
                // Deliberately no onDisappear/stop here: closing the dashboard window
                // should not stop monitoring, since the menu bar item needs to keep
                // updating even when the window is closed.
        }
        .windowResizability(.automatic)

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(engine)
        } label: {
            MenuBarLabel()
                .environmentObject(engine)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}
