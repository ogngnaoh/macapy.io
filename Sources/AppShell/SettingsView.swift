import DiarizeKit
import PersistKit
import ProviderKit
import SwiftUI

/// Numerals for the Spend tab.
enum SpendFormat {
    /// An unknown cost is a dash, never `$0.00`: a model with no known price
    /// hasn't been measured, and rendering it as free would be a claim we
    /// can't support (slice-02 doc Notes 8).
    static func cost(_ usd: Double?) -> String {
        guard let usd else { return "—" }
        if usd > 0 && usd < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", usd)
    }

    static func tokens(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}

/// Keep the familiar native tab structure while the body uses shared controls.
struct SettingsWindowView: View {
    let coordinator: AppShellCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(coordinator: coordinator)
                .tabItem { Label("general", systemImage: "gearshape") }
            ProvidersSettingsView(model: coordinator.providerSettingsModel())
                .tabItem { Label("providers", systemImage: "key") }
            SpendSettingsView(model: coordinator.providerSettingsModel())
                .tabItem { Label("spend", systemImage: "dollarsign.circle") }
            DiagnosticsSettingsView(coordinator: coordinator)
                .tabItem { Label("diagnostics", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 660, height: 560)
        .background(DesignTokens.bg)
        .disabled(coordinator.contentDeletionInProgress)
    }
}

/// One scroll owner keeps every tab usable in a compact settings window.
private struct SettingsBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                content
            }
            .padding(DesignTokens.Space.s5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.bg)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let coordinator: AppShellCoordinator
    @State private var deleteModel: DeleteEverythingModel?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsBody {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Text("general").font(UIType.title)
                    FormNote("capture, AI, and your preferences.")
                }
                Spacer()
                Button("setup…") { openWindow(id: WindowID.setup) }
                    .buttonStyle(SubtleButtonStyle())
            }
            .padding(.bottom, DesignTokens.Space.s3)
            SectionHead(title: "capture")
            FormRow(label: "audio sources") {
                Picker("audio sources", selection: Bindable(coordinator.setup).captureMode) {
                    ForEach(CaptureMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                .labelsHidden()
                .disabled(coordinator.session.isActive)
            }
            FormRow(label: "ephemeral meetings") {
                Toggle("", isOn: Binding(
                    get: { coordinator.ephemeralNextMeeting },
                    set: { coordinator.ephemeralNextMeeting = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("start meetings ephemeral")
                .disabled(coordinator.session.isActive)
            }
            FormRow(label: "") {
                FormNote("no saved transcript or history. Optional AI can still send live meeting text to your provider.")
            }
            FormRow(label: "speaker separation") {
                DiarizationSetupControl(activity: coordinator.setup.activity)
            }
            FormRow(label: "") {
                FormNote(
                    "labels other participants S1, S2, … on this Mac once the models are installed.")
            }
            Divider().padding(.vertical, DesignTokens.Space.s2)
            SectionHead(title: "optional AI")
            LiveAISettingsSection(model: coordinator.liveAISettingsModel())
            Divider().padding(.vertical, DesignTokens.Space.s2)
            LaunchPreferencesView(model: coordinator.launchPreferencesModel(), shortcuts: coordinator.shortcuts)
            Divider().padding(.vertical, DesignTokens.Space.s2)
            SectionHead(title: "local data")
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                // Delete-everything (FR-013; slice-05 doc decision 7).
                // Disabled while capturing — the coordinator also refuses,
                // this just says so up front.
                Button("delete all meeting data…") {
                    deleteModel = DeleteEverythingModel(
                        performDelete: { await coordinator.deleteAllMeetingData() })
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(coordinator.session.isActive)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                ResetPreferencesView(makeModel: {
                    ResetPreferencesModel(performReset: { await coordinator.resetRetainedPreferences() })
                })
                .disabled(coordinator.session.isActive || coordinator.setup.activity.isBusy)
            }
            if coordinator.session.isActive {
                FormNote("stop the current meeting before deleting data or resetting preferences.")
            }
        }
        .sheet(item: $deleteModel) { model in
            DeleteEverythingSheet(model: model, onDismiss: { deleteModel = nil })
        }
    }
}

struct LiveAISettingsSection: View {
    @Bindable var model: LiveAISettingsModel
    @State private var preferredName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            FormRow(label: "AI features") {
                Toggle("", isOn: Binding(
                    get: { model.settings.aiFeaturesEnabled },
                    set: { value in Task { await model.setEnabled(value) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("AI features")
            }
            FormRow(label: "copilot sensitivity") {
                Picker("copilot sensitivity", selection: Binding(
                    get: { model.settings.sensitivity },
                    set: { value in Task { await model.setSensitivity(value) } }
                )) {
                    Text("off").tag(LiveAISensitivity.off)
                    Text("quiet").tag(LiveAISensitivity.quiet)
                    Text("balanced").tag(LiveAISensitivity.balanced)
                    Text("active").tag(LiveAISensitivity.active)
                }
                .labelsHidden()
                .frame(maxWidth: 180)
                .accessibilityLabel("copilot sensitivity")
            }
            FormRow(label: "preferred name") {
                TextField("name used in meetings", text: $preferredName)
                    .textFieldStyle(.plain)
                    .padding(DesignTokens.Space.s2)
                    .background(DesignTokens.sunken)
                    .overlay(Rectangle().stroke(nameFocused ? DesignTokens.accent : DesignTokens.hairlineStrong))
                    .frame(maxWidth: 230)
                    .focused($nameFocused)
                    .onSubmit { Task { await model.setPreferredName(preferredName) } }
                    .accessibilityLabel("preferred name")
                Button("apply") { Task { await model.setPreferredName(preferredName) } }
                    .buttonStyle(SubtleButtonStyle())
            }
            FormRow(label: "") {
                FormNote("turning AI off cancels copilot and draft requests. Capture, transcription, and history continue.")
            }
        }
        .task {
            await model.load()
            preferredName = model.settings.preferredName ?? ""
        }
    }
}

/// The consent-gated model-download affordance (slice-4 decision 6; author
/// ruling 2026-08-07): the ONLY path that ever downloads the diarization
/// models, and the one documented exception to G6 — the button itself names
/// the endpoint and size, so clicking it is the consent. Installed ⇒ a quiet
/// settled chip; the next meeting picks diarization up automatically.
struct DiarizationSetupControl: View {
    private enum Phase: Equatable {
        case notInstalled
        case downloading
        case failed(String)
        case installed
    }

    let activity: SetupActivityGate
    @State private var phase: Phase = DiarizationModelStore.isInstalled ? .installed : .notInstalled
    @State private var downloadTask: Task<Void, Never>?
    @State private var cancelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch phase {
            case .notInstalled:
                Button("download models · ~\(DiarizationModelStore.approximateDownloadMegabytes) MB from huggingface.co") {
                    download()
                }
                .buttonStyle(.link)
                .font(UIType.small)
                .disabled(activity.sessionActive || activity.isBusy)
            case .downloading:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(cancelling ? "cancelling…" : "downloading…")
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Button("cancel") {
                        cancelling = true
                        downloadTask?.cancel()
                    }
                    .disabled(cancelling)
                }
            case .failed(let message):
                Button("try download again") { download() }
                    .buttonStyle(.link)
                    .font(UIType.small)
                    .disabled(activity.sessionActive || activity.isBusy)
                Text(message)
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
            case .installed:
                Chip(text: "installed", style: .quiet)
            }
            if activity.sessionActive {
                FormNote("downloads are unavailable during a meeting.")
            }
        }
        .accessibilityLabel("speaker separation models")
        .onDisappear {
            cancelling = true
            downloadTask?.cancel()
        }
    }

    private func download() {
        guard let lease = activity.beginDownload() else { return }
        phase = .downloading
        cancelling = false
        downloadTask = Task {
            defer {
                activity.endDownload(lease)
                downloadTask = nil
                cancelling = false
            }
            do {
                try await DiarizationModelStore.download()
                try Task.checkCancellation()
                phase = DiarizationModelStore.isInstalled ? .installed
                    : .failed("speaker models are not ready. Check your connection and try again.")
            } catch is CancellationError {
                phase = DiarizationModelStore.isInstalled ? .installed : .notInstalled
            } catch {
                phase = .failed("speaker model setup could not finish. Check your connection and available disk space, then try again.")
            }
        }
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Bindable var model: ProviderSettingsModel
    @State private var keyEntry = ""
    @FocusState private var keyFocused: Bool

    var body: some View {
        SettingsBody {
            Text("providers").font(UIType.title)
            if !model.isConfigured {
                // PRD edge case: no credentials is a *state*, not an error.
                FormNote("no provider configured. Transcription and history work on this Mac without a key. Add one for optional AI.")
            }

            ForEach(model.profiles) { profile in
                ProviderRow(
                    name: profile.displayName,
                    note: profile.dataPolicyNote,
                    chip: chipText(for: profile),
                    isActive: model.settings.selectedProfileID == profile.id,
                    action: { Task { await select(profile) } }
                )
            }

            if let profile = model.selectedProfile {
                credentialSection(for: profile)
            }
        }
        .task {
            await model.load()
        }
    }

    private func chipText(for profile: EndpointProfile) -> String {
        if model.settings.selectedProfileID == profile.id { return "active" }
        return model.hasKey(for: profile.id) || !profile.quirks.requiresAPIKey ? "ready" : "set up"
    }

    @ViewBuilder
    private func credentialSection(for profile: EndpointProfile) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            if profile.quirks.requiresAPIKey {
                FormRow(label: "API key") {
                    SecureField("sk-…", text: $keyEntry)
                        .textFieldStyle(.plain)
                        .font(MachineType.number(12))
                        .padding(DesignTokens.Space.s2)
                        .background(DesignTokens.sunken)
                        .overlay(Rectangle().stroke(keyFocused ? DesignTokens.accent : DesignTokens.hairlineStrong))
                        .frame(maxWidth: 230)
                        .focused($keyFocused)
                        .onSubmit { Task { await saveKey(for: profile) } }
                    Button(model.hasKey(for: profile.id) ? "replace" : "save") {
                        Task { await saveKey(for: profile) }
                    }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.hasKey(for: profile.id) {
                        Button("remove") { Task { await model.removeKey(for: profile.id) } }
                            .buttonStyle(SubtleButtonStyle())
                    }
                }
                FormRow(label: "") {
                    FormNote("stored only in the macOS Keychain, never in the database, settings, or logs.")
                }
            }

            FormRow(label: "models") {
                FormNote("uses the supported DeepSeek fast and deep model defaults.")
            }

            FormRow(label: "") {
                Button("test connection") { Task { await model.testConnection() } }
                    .buttonStyle(SubtleButtonStyle())
                    .disabled(model.connectionTest == .running)
                connectionResult
            }
            FormRow(label: "") {
                FormNote("sends a short request to your provider. The test uses a few billable tokens on your key.")
            }
        }
        .padding(.top, DesignTokens.Space.s2)
    }

    @ViewBuilder
    private var connectionResult: some View {
        switch model.connectionTest {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded(let reply):
            Text("connected · “\(reply)”")
                .font(UIType.small)
                .foregroundStyle(DesignTokens.live)
        case .failed(let message):
            Text(message)
                .font(UIType.small)
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func select(_ profile: EndpointProfile) async {
        await model.select(profileID: profile.id)
    }

    private func saveKey(for profile: EndpointProfile) async {
        await model.saveKey(keyEntry, for: profile.id)
        // The plaintext key never outlives the save (SPEC §8).
        keyEntry = ""
    }

}

// MARK: - Spend

struct SpendSettingsView: View {
    @Bindable var model: ProviderSettingsModel
    @State private var capEntry = ""
    @FocusState private var capFocused: Bool

    var body: some View {
        SettingsBody {
            Text("spend").font(UIType.title)
            meetingSpend
            capControls
            if model.spendEntries.isEmpty {
                FormNote("no settled AI calls recorded. Unresolved requests can still count toward a budget.")
                    .padding(.top, DesignTokens.Space.s3)
            } else {
                ledgerTable
            }
        }
        .task {
            await model.load()
            capEntry = model.settings.perMeetingCapUSD.map { String(format: "%.2f", $0) } ?? ""
        }
    }

    @ViewBuilder
    private var meetingSpend: some View {
        // "Latest meeting", honestly: no current-meeting id reaches this tab
        // until slice 3 meters real meetings (verifier finding V3).
        let spent = model.latestMeetingSpendUSD
        FormRow(label: "latest meeting") {
            Text(SpendFormat.cost(spent))
                .font(MachineType.number(14))
                .foregroundStyle(DesignTokens.text)
            if let cap = model.settings.perMeetingCapUSD {
                FormNote("of \(SpendFormat.cost(cap)) cap")
            }
        }
        if let cap = model.settings.perMeetingCapUSD, cap > 0 {
            FormRow(label: "") {
                VStack(alignment: .leading, spacing: 4) {
                    CapMeter(fraction: (spent ?? 0) / cap)
                        .frame(maxWidth: 280)
                    FormNote(
                        (spent ?? 0) >= cap
                            ? "cap reached. AI is paused; capture and transcription continue."
                            : "at the cap, AI pauses with a notice. Capture and transcription continue."
                    )
                }
            }
        }
        if model.hasUnpricedEntries {
            FormRow(label: "") {
                FormNote("some calls have no known model price, so this total is partial.")
            }
        }
    }

    @ViewBuilder
    private var capControls: some View {
        FormRow(label: "per-meeting cap") {
            TextField("none", text: $capEntry)
                .textFieldStyle(.plain)
                .font(MachineType.number(12))
                .padding(DesignTokens.Space.s2)
                .background(DesignTokens.sunken)
                .overlay(Rectangle().stroke(capFocused ? DesignTokens.accent : DesignTokens.hairlineStrong))
                .frame(maxWidth: 90)
                .focused($capFocused)
                .onSubmit { Task { await model.setCap(Double(capEntry)) } }
            Button("apply") { Task { await model.setCap(Double(capEntry)) } }
                .buttonStyle(SubtleButtonStyle())
            Button("remove cap") {
                capEntry = ""
                Task { await model.setCap(nil) }
            }
            .buttonStyle(SubtleButtonStyle())
            .disabled(model.settings.perMeetingCapUSD == nil)
        }
        FormRow(label: "") {
            FormNote("costs use a built-in price list and may differ from your provider’s bill.")
        }
    }

    private var ledgerTable: some View {
        VStack(spacing: 0) {
            DataTableHeader(columns: ["purpose", "model", "tokens", "est. cost"], numericFrom: 2)
            ForEach(model.spendEntries) { entry in
                DataTableRow(
                    cells: [
                        entry.purpose.rawValue,
                        entry.model,
                        SpendFormat.tokens(entry.usage.promptTokens + entry.usage.completionTokens),
                        SpendFormat.cost(entry.estCostUSD),
                    ],
                    numericFrom: 2
                )
            }
        }
        .padding(.top, DesignTokens.Space.s3)
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettingsView: View {
    let coordinator: AppShellCoordinator
    @State private var showingRequests = false

    var body: some View {
        SettingsBody {
            Text("diagnostics").font(UIType.title)
            DiagnosticsSectionView(coordinator: coordinator)
            FormNote("diagnostics stay on this Mac. Nothing is uploaded.")
            Divider().padding(.vertical, DesignTokens.Space.s3)
            SectionHead(title: "outgoing AI text")
            FormNote("review the exact outgoing JSON and included sources. This temporary record excludes headers, credentials, and responses.")
            Button("inspect outgoing AI text…") { showingRequests = true }
                .buttonStyle(SubtleButtonStyle())
            Divider().padding(.vertical, DesignTokens.Space.s3)
            SanitizedDiagnosticsExportView(model: coordinator.diagnosticsExportModel())
        }
        .sheet(isPresented: $showingRequests) {
            RequestInspectorView(inspector: coordinator.requestInspector)
        }
    }
}
