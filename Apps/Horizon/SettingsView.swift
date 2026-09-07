import SwiftUI
import IngestKit
#if canImport(UIKit)
import UIKit
#endif

/// Where documents are read (and plans made), the OpenAI key that one of the choices needs, and what this device
/// reports. Everything applies as it is changed; the key lives in the Keychain and the page says what leaves the device.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var key = ""
    @State private var modelName = ""
    @State private var testing = false
    @State private var verdict: (ok: Bool, text: String)?

    private var hasKey: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                RouteRow(title: "On this device", detail: "Nothing leaves the phone. A long syllabus takes a few minutes and warms it.",
                         selected: model.readingRoute == .onDevice) { model.readingRoute = .onDevice }
                RouteRow(title: "Private Cloud Compute", detail: model.cloudUnavailableReason.map { "Unavailable: \($0)." } ?? "Apple's servers; nothing is kept. Faster on long documents.",
                         selected: model.readingRoute == .privateCloudCompute, disabled: model.cloudUnavailableReason != nil) { model.readingRoute = .privateCloudCompute }
                if FeatureFlags.openAI {
                    RouteRow(title: "OpenAI", detail: hasKey ? "Your key, model \(model.openAIModel). The text and pages of every document, and what the planner sees, are sent to OpenAI." : "Needs a key, below.",
                             selected: model.readingRoute == .openAI, disabled: !hasKey) { model.readingRoute = .openAI }
                }
            } header: {
                Kicker("Read documents")
            } footer: {
                Text("The day plan is made the same way. If a route cannot be used, the device reads the document instead and says so.")
            }
            if FeatureFlags.openAI {
                Section {
                    SecureField("sk-…", text: $key).textContentType(.password).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    LabeledContent("Model") {
                        TextField(OpenAIConfiguration.defaultModel, text: $modelName).multilineTextAlignment(.trailing).autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if testing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(!hasKey || testing)
                    if let verdict {
                        Label(verdict.text, systemImage: verdict.ok ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(verdict.ok ? .secondary : Design.accent).font(.footnote)
                    }
                    if hasKey {
                        Button("Remove Key", role: .destructive) { key = "" }
                    }
                } header: {
                    Kicker("OpenAI")
                } footer: {
                    Text("Kept in this device's Keychain, never synced. Any chat model that supports structured output and images will do; \(OpenAIConfiguration.defaultModel) is the default. Removing the key turns the route off.")
                }
            }
            Section {
                LabeledContent("Reminders access", value: model.remindersAuthorized.map { $0 ? "Granted" : "Denied" } ?? "Not asked")
                #if os(iOS)
                if model.remindersAuthorized == false {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                }
                #endif
                LabeledContent("Device", value: AppModel.deviceName)
            } header: {
                Kicker("This device")
            } footer: {
                Text("Only the device that read a document creates its reminders; the others see them arrive.")
            }
            #if DEBUG
            Section {
                Button("Ingest Sample Syllabus", systemImage: "ladybug") {
                    if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") { Task { await model.importFiles([sample]) } }
                }
            } header: {
                Kicker("Debug")
            } footer: {
                Text("Reads the bundled sample with whatever route is chosen above.")
            }
            #endif
        }
        .paper()
        .navigationTitle("Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { key = model.openAIKey; modelName = model.openAIModel }
        .onChange(of: key) { _, value in
            verdict = nil
            model.openAIKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if model.openAIKey.isEmpty, model.useOpenAI { model.readingRoute = .onDevice }   // the route needs the key
        }
        .onChange(of: modelName) { _, value in
            verdict = nil
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            model.openAIModel = trimmed.isEmpty ? OpenAIConfiguration.defaultModel : trimmed
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let configuration = OpenAIConfiguration(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), model: model.openAIModel)
        do {
            verdict = (true, try await OpenAIClient(configuration: configuration).probe())
        } catch {
            verdict = (false, error.localizedDescription)
        }
    }
}

/// One of the routes: a title, a line on what it means, a check on the one in use.
private struct RouteRow: View {
    let title: String
    let detail: String
    let selected: Bool
    var disabled = false
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(disabled ? .secondary : .primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Design.accent).opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy, value: selected)
    }
}
