import SwiftUI

/// Per-service blocking settings and today's time in the service.
struct ServiceSettingsView: View {
    let service: AppState.Service

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Show on home screen", isOn: state.showOnHome(service.id))
                        .tint(Theme.switchOn)
                } footer: {
                    Text("Turn off to remove \(service.name) from the home screen carousel. Its settings and sign-in are kept.")
                        .footnoteStyle()
                }
                .listRowBackground(Theme.card)

                Section {
                    ForEach(state.surfaces(for: service.id)) { group in
                        Toggle(group.label,
                               isOn: state.binding(service: service.id, surfaces: group.keys))
                            .tint(Theme.switchOn)
                    }
                } header: {
                    EyebrowHeader("What's blocked")
                } footer: {
                    if service.beta {
                        Text("\(service.name) is in beta: its rules are written but not yet verified against the live site.")
                            .footnoteStyle()
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent("Time in \(service.name)", value: state.usageToday(for: service.id))
                } header: {
                    EyebrowHeader("Today")
                } footer: {
                    Text("Counted while \(service.name) is open in Simpli. Stays on this iPhone.")
                        .footnoteStyle()
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            .navigationTitle("\(service.name) Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
