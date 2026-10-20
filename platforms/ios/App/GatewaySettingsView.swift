import MotoNavigationCore
import SwiftUI

struct GatewaySettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var message: AppMessage?
    @State private var isChecking = false
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L("https://your-gateway/"), text: $address, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("gateway-address-field")
                        .disabled(model.isUpdatingGateway)
                } header: {
                    Text(L("Gateway address"))
                } footer: {
                    Text(L("Enter the full HTTPS root address, for example https://nav.example.com/moto-gps/api/. Do not enter the AMap key."))
                }
                Section {
                    Button {
                        checkConnection()
                    } label: {
                        HStack {
                            Text(L("Test connection"))
                            if isChecking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isChecking || model.isUpdatingGateway || address.isEmpty)
                    .accessibilityIdentifier("gateway-check-button")
                    if let message {
                        Text(message.text).foregroundStyle(.secondary)
                            .accessibilityIdentifier("gateway-status-message")
                    }
                } footer: {
                    Text(L("The test only checks the gateway status; real search, navigation and maps also need their services to be available."))
                }
                Section {
                    Text(L("Saving takes effect immediately, without reinstalling. Changing the address clears the current search and pauses map downloads; downloaded maps are kept."))
                    Text(L("Place, route and location requests are sent to this address. Use a gateway you trust."))
                }
                if model.isNavigationActive {
                    Section { Text(L("End navigation before changing the gateway address.")) }
                }
            }
            .navigationTitle(L("Gateway settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }.disabled(model.isUpdatingGateway)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        checkTask?.cancel()
                        isChecking = false
                        Task {
                            do {
                                try await model.saveGatewayAddress(address)
                                dismiss()
                            } catch { message = .error(error) }
                        }
                    }
                    .disabled(model.isNavigationActive || model.isUpdatingGateway || address.isEmpty)
                    .accessibilityIdentifier("gateway-save-button")
                }
            }
            .interactiveDismissDisabled(model.isUpdatingGateway)
            .onAppear { address = model.isGatewayConfigured ? model.mapGatewayBaseURL.absoluteString : "" }
            .onChange(of: address) { _, _ in
                checkTask?.cancel()
                isChecking = false
                message = nil
            }
            .onDisappear { checkTask?.cancel() }
        }
    }

    private func checkConnection() {
        checkTask?.cancel()
        message = nil
        let url: URL
        do { url = try GatewayConfiguration.normalizedURL(address) }
        catch { message = .error(error); return }
        isChecking = true
        checkTask = Task { @MainActor in
            defer { if !Task.isCancelled { isChecking = false } }
            do {
                var request = URLRequest(url: url.appendingPathComponent("healthz"))
                request.timeoutInterval = 10
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.expectedContentLength <= 65_536 else { throw URLError(.badServerResponse) }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 65_536 else { throw URLError(.dataLengthExceedsMaximum) }
                    data.append(byte)
                }
                struct Health: Decodable {
                    let status: String
                    let ready_for_live_navigation: Bool
                }
                let health = try JSONDecoder().decode(Health.self, from: data)
                guard health.status == "ok" else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                if health.ready_for_live_navigation {
                    message = .localized("Gateway connected; live navigation is configured.")
                } else {
                    message = .localized("Gateway connected, but live navigation is not configured yet. Check the server configuration.")
                }
            } catch {
                guard !Task.isCancelled else { return }
                message = .localized("Connection failed. Check the address, the HTTPS certificate and that the gateway is running.")
            }
        }
    }
}
