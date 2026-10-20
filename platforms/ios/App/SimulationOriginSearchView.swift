import SwiftUI

/// Picks where a route simulation starts, with the same place search as the
/// destination; results near the destination come first.
struct SimulationOriginSearchView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if model.isSearchingSimulationOrigin {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(L("Searching…")).foregroundStyle(Color.secondary)
                    }
                } else if model.simulationOriginResults.isEmpty {
                    ContentUnavailableView(
                        L("Where does the simulation start?"),
                        systemImage: "figure.walk.motion",
                        description: Text(L("Search for an address or place, for example a street and number."))
                    )
                }
                ForEach(Array(model.simulationOriginResults.enumerated()), id: \.element.id) { index, place in
                    Button {
                        model.selectSimulationOrigin(place)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(place.name).foregroundStyle(Color.primary)
                            Text(place.displayArea.isEmpty ? place.address : place.displayArea)
                                .font(.subheadline)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("simulation-origin-result-\(index)")
                }
            }
            .navigationTitle(L("Simulation start"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: L("Search for a place or address"))
            .onChange(of: query) { _, text in model.searchSimulationOrigin(text) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
        }
    }
}
