import SwiftUI
import IngestKit
#if canImport(UIKit)
import UIKit
#endif

/// Where documents are read (Claude, or this iPhone, iPad or Mac), the Claude key and model, whether the day plan may
/// use Claude, and what this device reports. Everything applies as it is changed; the key lives in the Keychain and the
/// page says what leaves the device, briefly, and names the device as the user knows it ("iPhone", never "the phone").
/// On iOS one page, reached from the More menu; on the Mac the same sections make up the Settings window.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ReadingSettingsSections()
            DeviceSettingsSections()
            LibrarySettingsSection()
            #if DEBUG
            Section {
                Button("Ingest Sample Syllabus", systemImage: "ladybug") {
                    if let sample = Bundle.main.url(forResource: "sample-syllabus", withExtension: "pdf") { Task { await model.importFiles([sample]) } }
                }
                .macBordered()
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
    }
}

/// The reading route as one choice (the device's own greyed where Apple Intelligence is not supported); which Claude
/// (Horizon's reading service, where it is offered, or the user's own key, with its model); and the day plan, the one
/// small task Claude may take on. Each row says what it sends, in as few words as that takes.
struct ReadingSettingsSections: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var testing = false
    @State private var verdict: (ok: Bool, text: String)?
    @State private var confirmRemove = false

    private var hasKey: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Horizon's reading service is offered here (an iPhone or iPad with App Attest, in a build that names the service).
    private var serviceOffered: Bool { AppModel.readingService != nil }
    private var canUseClaude: Bool { model.usesReadingService || hasKey }
    /// The device can read for itself: it supports Apple Intelligence, on or not yet (a document then waits for it).
    private var deviceReads: Bool { model.deviceModel.supported }
    private let here = AppModel.deviceKind
    #if os(macOS)
    private let systemSettings = "System Settings"
    #else
    private let systemSettings = "the Settings app"
    #endif

    private var claudeDetail: String {
        if model.usesReadingService { return "Documents go to Anthropic through Horizon's server." }
        if hasKey { return "Documents go to Anthropic under your key." }
        return serviceOffered ? "Needs Horizon's server or a key." : "Needs a key."
    }

    private var deviceDetail: String {
        switch model.deviceModel {
        case .ready: "Nothing leaves your \(here). Slower, and less sure of tables and pictures."
        case .downloading: "Nothing leaves your \(here). Apple Intelligence is still downloading."
        case .off: "Turn on Apple Intelligence in \(systemSettings) to read here."
        case .unsupported: "This \(here) doesn't support Apple Intelligence."
        }
    }

    var body: some View {
        @Bindable var model = model
        Section {
            RouteRow(title: "Claude", detail: claudeDetail, selected: model.readRoute == .claude, disabled: !canUseClaude) { model.readingRoute = .claude }
            RouteRow(title: "On This \(here)", detail: deviceDetail, selected: model.readRoute == .onDevice, disabled: !deviceReads) { model.readingRoute = .onDevice }
        } header: {
            Kicker("Read documents")
        }
        .onAppear { key = model.claudeKey }   // on a section that is drawn: an empty one never appears
        .onChange(of: key) { _, value in
            verdict = nil
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let had = !model.claudeKey.isEmpty
            model.claudeKey = trimmed
            if trimmed.isEmpty { model.planWithClaude = false; if deviceReads { model.readingRoute = .onDevice } }   // the route needs the key; with no model here, documents wait for one
            else if !had { model.readingRoute = .claude }                                                             // a key entered is Claude asked for
        }
        .onChange(of: model.claudeModel) { _, _ in verdict = nil }
        if serviceOffered {
            Section {
                RouteRow(title: "Through Horizon", detail: "No key needed. Sonnet 5.5, with a daily allowance.", selected: model.usesReadingService) {
                    withAnimation { model.claudeAccess = .service; model.readingRoute = .claude; verdict = nil }   // Horizon's Claude chosen is Claude asked for
                }
                RouteRow(title: "With Your Own Key", detail: "Any model, billed to your Anthropic account.", selected: !model.usesReadingService) {
                    withAnimation {
                        model.claudeAccess = .ownKey; verdict = nil
                        if model.claudeKey.isEmpty { model.planWithClaude = false; if deviceReads { model.readingRoute = .onDevice } }   // as with a key removed
                    }
                }
                if model.usesReadingService { testRows }
            } header: {
                Kicker("Claude")
            } footer: {
                if model.usesReadingService {
                    Text("Horizon's server keeps none of what it passes to Anthropic, and knows this \(here) only by a key made for it.")
                }
            }
            .animation(.default, value: verdict?.text)
        }
        if !model.usesReadingService {
            Section {
                SecureField("API Key", text: $key, prompt: Text("sk-ant-…")).autocorrectionDisabled()   // no content type: as a password it drew AutoFill's offers to save one
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Model", selection: $model.claudeModel) {
                    ForEach(ClaudeModelChoice.allCases) { Text($0.displayName).tag($0) }
                }
                .macInk()
                Text(model.claudeModel.detail).font(.footnote).foregroundStyle(.secondary)
                testRows
                if hasKey {
                    // Asks first: the Console shows a key once, so one lost by a slip has to be made again.
                    Button("Remove Key…", role: .destructive) { confirmRemove = true }
                        .macBordered()
                        .confirmationDialog("Remove your Claude key?", isPresented: $confirmRemove, titleVisibility: .visible) {
                            Button("Remove Key", role: .destructive) { key = "" }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(deviceReads ? "Documents will then be read on this \(here)." : "Documents will then wait for Claude.")
                        }
                }
            } header: {
                Kicker(serviceOffered ? "Your key" : "Claude")
            } footer: {
                // With the service offered, its row has already said who bills.
                Text(serviceOffered ? "From the Claude Console, kept only on this \(here)." : "From the Claude Console, kept only on this \(here) and billed to your Anthropic account.")
            }
            .animation(.default, value: hasKey)          // Remove Key comes with a key, animated
            .animation(.default, value: verdict?.text)   // the test's verdict arrives under the button, animated
        }
        Section {
            Toggle("Plan the day with Claude", isOn: $model.planWithClaude).disabled(!canUseClaude)
        } header: {
            Kicker("Day plan")
        } footer: {
            Text("Claude follows your instructions more closely. The day's calendar events, your items and what you told the planner go to Anthropic\(model.usesReadingService ? " through Horizon's server" : "").")
        }
    }

    /// Test Connection and its verdict: through the service (its first attestation, when it has none yet), or the key.
    @ViewBuilder private var testRows: some View {
        Button {
            Task { await test() }
        } label: {
            HStack {
                Text("Test Connection")
                Spacer()
                if testing { ProgressView().controlSize(.small) }
            }
        }
        .macBordered()
        .disabled(!canUseClaude || testing)
        if let verdict {
            Label(verdict.text, systemImage: verdict.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(verdict.ok ? .secondary : Design.accentInk).font(.footnote)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let configuration = model.usesReadingService ? model.claudeConfiguration : ClaudeConfiguration(apiKey: key, model: model.claudeModel)
            guard let configuration else { return }
            verdict = (true, try await Ingestor.probe(claude: configuration))
        } catch IngestError.claudeUnavailable(let why) {
            verdict = (false, why.sentenceStart + ".")   // the reason alone: "Claude could not read the document" is a read's words, not a test's
        } catch {
            verdict = (false, error.localizedDescription)
        }
    }
}

/// What this device reports: Reminders access, and on a Mac its name (an iPhone's or iPad's is only "iPhone" or "iPad"
/// to an app, which the kicker says already).
struct DeviceSettingsSections: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("Reminders access", value: model.remindersAuthorized.map { $0 ? "Granted" : "Denied" } ?? "Not asked")
            if model.remindersAuthorized == false {
                #if os(iOS)
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                #else
                Button("Open System Settings") { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { openURL(url) } }.bordered()
                #endif
            }
            #if os(macOS)
            LabeledContent("Name", value: AppModel.deviceName)
            #endif
        } header: {
            Kicker("This \(AppModel.deviceKind)")
        } footer: {
            if model.remindersAuthorized == nil { Text("Asked the first time there's a deadline to write.") }
        }
    }
}

/// One of the routes: a title, a line on what it means, a check on the one in use. A route that cannot be chosen here
/// is greyed, its check too when it is the one on file (a key gone, a model this device does not have).
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
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(disabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Design.accent)).opacity(selected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.snappy, value: selected)
    }
}
