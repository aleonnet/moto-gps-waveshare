import SwiftUI

@main
struct MotoGPSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LocalizedRoot(model: model)
        }
    }
}

/// Views read their text through L(), which tracks the language, so a change
/// redraws each screen in place and open sheets, lists and fields keep their
/// state. The locale environment covers formatting inside SwiftUI controls.
private struct LocalizedRoot: View {
    let model: AppModel

    var body: some View {
        ContentView(model: model)
            .environment(\.locale, AppLocalization.shared.locale)
    }
}
