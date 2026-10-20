import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppLanguage.allCases) { language in
                        // Applies at once; this sheet stays open and redraws
                        // in the new language like the rest of the app.
                        Button {
                            model.selectLanguage(language)
                        } label: {
                            HStack {
                                Text(model.languageName(language)).foregroundStyle(Color.primary)
                                Spacer()
                                if model.language == language {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                        .accessibilityIdentifier("language-option-\(language.rawValue)")
                        .accessibilityAddTraits(model.language == language ? .isSelected : [])
                    }
                } footer: {
                    Text(L("The round display uses the same language. Permission prompts follow the iOS language."))
                }
                Section {
                    // Apple's recommended path (WWDC19 session 403): the
                    // per-app language in iOS Settings also covers system
                    // prompts; "System" above follows it.
                    Button(L("Open iOS language settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    }
                    .accessibilityIdentifier("language-ios-settings")
                }
            }
            .navigationTitle(L("Language"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                        .accessibilityIdentifier("language-settings-done")
                }
            }
            .accessibilityIdentifier("language-settings-sheet")
        }
    }
}
