import SwiftUI

struct ApplicationsSettingsView: View {
    var body: some View {
        Form {
            LauncherCategorySwitchSection(
                kind: .application, anchor: .applicationsApplications,
                title: "Enable Applications",
                subtitle: "Open the apps on your Mac. Turning this off also disables their shortcuts.")

            SearchScopesSection()

            LauncherItemsSection(
                kind: .application,
                anchor: .applicationsApplications,
                searchPrompt: "Search applications…",
                emptyMessage: LocalizedStringResource("applications-empty", defaultValue: "Nothing here yet.")
            )
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.applications)
        .releasesFocusOnOutsideClick()
    }

}
