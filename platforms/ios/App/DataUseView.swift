import SwiftUI

/// Available without a connection, so permission and storage information can
/// still be read when the gateway or the accessory is unavailable.
struct DataUseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L("Location and routes")) {
                    Text(L("When you search places, plan or replan a route, the search text, start, destination and the needed location are sent to the configured navigation service. The gateway forwards the needed information to AMap in mainland China and to Geoapify elsewhere. Online surrounding-map requests also reveal the area being viewed, and the gateway fetches those map tiles from Protomaps."))
                    Text(L("During navigation, location updates the route and the round-display guidance, and continues with the screen locked or in another app. Ending navigation stops navigation location. You can change permissions in Settings."))
                }
                Section(L("Bluetooth and music")) {
                    Text(L("With the round display connected, navigation, speed and the surrounding map sync over Bluetooth. If you allow media library access, the Apple Music title, artist and playback state also sync to the round display, which can go to the previous track, play or pause, and skip to the next track."))
                    Text(L("Music information is not sent to the MOTO GPS navigation server. Denying music access does not affect place search or navigation."))
                }
                Section(L("Storage and cleanup")) {
                    Text(L("Recent places, the connected device identifier and downloaded maps are stored on the phone. The home screen can clear recent searches; the maps and offline downloads screen can delete downloads and clear the temporary cache. Deleting the app removes its local data; system backups may contain part of it."))
                    Text(L("Server access logs may keep IP addresses, request times, search terms, location parameters and map areas. What is logged, rotation and retention depend on the operator’s configuration and privacy policy; data is therefore not only stored on the phone."))
                }
                Section {
                    Link(L("AMap privacy policy"), destination: URL(string: "https://lbs.amap.com/home/privacy/")!)
                    Link(L("Geoapify privacy policy"), destination: URL(string: "https://www.geoapify.com/privacy-policy/")!)
                    Link(L("Apple privacy policy"), destination: URL(string: "https://www.apple.com/legal/privacy/")!)
                    Link(L("OpenStreetMap data and license"), destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link(L("Protomaps map data"), destination: URL(string: "https://protomaps.com")!)
                } header: {
                    Text(L("Third-party services"))
                } footer: {
                    Text(L("The route map on the phone is provided by Apple Maps; roads and buildings on the round display use OpenStreetMap / Protomaps data."))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L("Privacy & data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Done")) { dismiss() }
                        .accessibilityIdentifier("privacy-data-done")
                }
            }
        }
    }
}
