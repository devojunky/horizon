import WidgetKit
import SwiftUI
import AppIntents

// The app's controls, for Control Center, the Lock Screen and the Action button (SPEC §7: "one-tap ingest of the current
// screenshot"). No app may take a screenshot or reach the screen's pixels from a control, so the nearest a press can
// come is the app opened at the user's screenshots, newest first, one tap from reading one; iOS 27's Shortcuts
// automation "When a screenshot is saved" with Horizon's Read a Document takes a screenshot with no tap at all, and the
// share sheet from the screenshot's thumbnail does the same by hand.

struct ReadScreenshotControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ReadScreenshot") {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "horizon://import/screenshots")!)) {
                Label("Read a Screenshot", systemImage: "camera.viewfinder")
                    .controlWidgetActionHint("Read a screenshot")   // what the Action button says it does (HIG: a verb)
            }
        }
        .displayName("Read a Screenshot")
        .description("Opens Horizon at your screenshots, to read an assignment list or a page of a syllabus.")
    }
}

struct PlanDayControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "PlanDay") {
            ControlWidgetButton(action: PlanDayControlIntent()) {
                Label("Plan My Day", systemImage: "sun.horizon")
                    .controlWidgetActionHint("Plan the day")
            }
        }
        .displayName("Plan My Day")
        .description("Plans the rest of today around your calendar and shows it in a Live Activity.")
    }
}
