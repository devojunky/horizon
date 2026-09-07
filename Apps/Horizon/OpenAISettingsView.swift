import SwiftUI
import IngestKit

/// The user's own OpenAI key and model, and the switch that sends reading and planning there. The key lives in the
/// Keychain; the sheet says plainly what leaves the device. Cancel leads, Save trails; a test button says whether
/// the key and the model work before anything is read with them.
struct OpenAISettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var modelName = ""
    @State private var enabled = false
    @State private var baseline: Fields?
    @State private var confirmingDiscard = false
    @State private var testing = false
    @State private var verdict: (ok: Bool, text: String)?

    private struct Fields: Equatable { var key: String; var model: String; var enabled: Bool }
    private var fields: Fields { Fields(key: key.trimmingCharacters(in: .whitespacesAndNewlines), model: modelName.trimmingCharacters(in: .whitespacesAndNewlines), enabled: enabled) }
    private var isDirty: Bool { baseline.map { $0 != fields } ?? false }
    private var hasKey: Bool { !fields.key.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
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
                } header: {
                    Text("API key")
                } footer: {
                    Text("Kept in this device's Keychain, never synced. Any chat model that supports structured output and images will do; \(OpenAIConfiguration.defaultModel) is the default.")
                }
                Section {
                    Toggle("Read documents and plan with OpenAI", isOn: $enabled).disabled(!hasKey)
                } footer: {
                    Text("When this is on, the text and pages of every document you read, and the calendar and items the planner sees, are sent to OpenAI. If OpenAI cannot be reached, the device reads the document instead and says so.")
                }
                Section {
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
                }
                if !(model.openAIKey.isEmpty) {
                    Section {
                        Button("Remove Key", role: .destructive) { key = ""; enabled = false }
                    } footer: {
                        Text("Removing the key turns OpenAI off; the device reads everything again.")
                    }
                }
            }
            .paper()
            .navigationTitle("OpenAI")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if isDirty { confirmingDiscard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(!isDirty) }
            }
            .interactiveDismissDisabled(isDirty)
            .confirmationDialog("Discard changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
            }
            .onAppear {
                key = model.openAIKey; modelName = model.openAIModel; enabled = model.useOpenAI
                baseline = fields
            }
            .onChange(of: key) { _, _ in verdict = nil }
            .onChange(of: modelName) { _, _ in verdict = nil }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let configuration = OpenAIConfiguration(apiKey: fields.key, model: fields.model)
        do {
            let line = try await OpenAIClient(configuration: configuration).probe()
            verdict = (true, line)
        } catch {
            verdict = (false, error.localizedDescription)
        }
    }

    private func save() {
        model.openAIKey = fields.key
        model.openAIModel = fields.model.isEmpty ? OpenAIConfiguration.defaultModel : fields.model
        model.useOpenAI = enabled && hasKey
        dismiss()
    }
}
