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

/// The settings window: four tabs, matching the approved mockups
/// (design/06-settings.html). Slice 2 builds Providers and Spend; General and
/// Diagnostics carry what already exists.
struct SettingsWindowView: View {
    let coordinator: AppShellCoordinator

    var body: some View {
        TabView {
            GeneralSettingsView(coordinator: coordinator)
                .tabItem { Label("General", systemImage: "gearshape") }
            ProvidersSettingsView(model: coordinator.providerSettingsModel())
                .tabItem { Label("Providers", systemImage: "key") }
            SpendSettingsView(model: coordinator.providerSettingsModel())
                .tabItem { Label("Spend", systemImage: "dollarsign.circle") }
            DiagnosticsSettingsView(coordinator: coordinator)
                .tabItem { Label("Diagnostics", systemImage: "waveform.path.ecg") }
        }
        .frame(width: 560, height: 430)
        .background(DesignTokens.bg)
    }
}

/// Shared chrome for a tab's body: the mockup's `.settings-body` padding on the
/// window background.
private struct SettingsBody<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
                content
            }
            .padding(DesignTokens.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.bg)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    let coordinator: AppShellCoordinator

    var body: some View {
        SettingsBody {
            FormRow(label: "Start / stop meeting") {
                Text("⌥⌘M").font(MachineType.number(11)).foregroundStyle(DesignTokens.text)
            }
            FormRow(label: "Pause / resume capture") {
                Text("⌥⌘P").font(MachineType.number(11)).foregroundStyle(DesignTokens.text)
            }
            FormRow(label: "Start meetings ephemeral") {
                Toggle("", isOn: Binding(
                    get: { coordinator.ephemeralNextMeeting },
                    set: { coordinator.ephemeralNextMeeting = $0 }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Start meetings ephemeral")
            }
            FormRow(label: "") {
                FormNote("Ephemeral meetings keep nothing — no transcript, no history, no rows on disk.")
            }
        }
    }
}

// MARK: - Providers

struct ProvidersSettingsView: View {
    @Bindable var model: ProviderSettingsModel
    @State private var keyEntry = ""
    @State private var fastModel = ""
    @State private var deepModel = ""

    var body: some View {
        SettingsBody {
            if !model.isConfigured {
                // PRD edge case: no credentials is a *state*, not an error.
                VStack(alignment: .leading, spacing: 2) {
                    Text("No provider configured")
                        .font(UIType.bodySemibold)
                        .foregroundStyle(DesignTokens.text)
                    FormNote(
                        "macapy works fully without one — live transcription and history are on-device. "
                            + "Add a key to unlock summaries, action items, and in-meeting suggestions."
                    )
                }
                .padding(.bottom, DesignTokens.Space.s1)
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
            syncFields()
        }
    }

    private func chipText(for profile: EndpointProfile) -> String {
        if model.settings.selectedProfileID == profile.id { return "Active" }
        return model.hasKey(for: profile.id) || !profile.quirks.requiresAPIKey ? "Ready" : "Set up"
    }

    @ViewBuilder
    private func credentialSection(for profile: EndpointProfile) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            if profile.quirks.requiresAPIKey {
                FormRow(label: "API key") {
                    SecureField("sk-…", text: $keyEntry)
                        .textFieldStyle(.roundedBorder)
                        .font(MachineType.number(11))
                        .frame(maxWidth: 230)
                        .onSubmit { Task { await saveKey(for: profile) } }
                    Button(model.hasKey(for: profile.id) ? "Replace" : "Save") {
                        Task { await saveKey(for: profile) }
                    }
                    .disabled(keyEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.hasKey(for: profile.id) {
                        Button("Remove") { Task { await model.removeKey(for: profile.id) } }
                    }
                }
                FormRow(label: "") {
                    FormNote("Stored only in the macOS Keychain — never in the database, settings, or logs.")
                }
            }

            FormRow(label: "Fast model") {
                TextField(profile.fastModel, text: $fastModel)
                    .textFieldStyle(.roundedBorder)
                    .font(MachineType.number(11))
                    .frame(maxWidth: 230)
                    .onSubmit {
                        Task { await model.setModelOverride(fastModel, tier: .fast, for: profile.id) }
                    }
            }
            FormRow(label: "Deep model") {
                TextField(profile.deepModel, text: $deepModel)
                    .textFieldStyle(.roundedBorder)
                    .font(MachineType.number(11))
                    .frame(maxWidth: 230)
                    .onSubmit {
                        Task { await model.setModelOverride(deepModel, tier: .deep, for: profile.id) }
                    }
            }

            FormRow(label: "") {
                Button("Test connection") { Task { await model.testConnection() } }
                    .disabled(model.connectionTest == .running)
                connectionResult
            }
            FormRow(label: "") {
                FormNote("Streams a short reply to verify the key and models. It costs a few tokens on your key.")
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
            Text("Connected — replied “\(reply)”")
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
        syncFields()
    }

    private func saveKey(for profile: EndpointProfile) async {
        await model.saveKey(keyEntry, for: profile.id)
        // The plaintext key never outlives the save (SPEC §8).
        keyEntry = ""
    }

    private func syncFields() {
        guard let profile = model.selectedProfile else { return }
        fastModel = model.settings.fastModelOverrides[profile.id] ?? ""
        deepModel = model.settings.deepModelOverrides[profile.id] ?? ""
        keyEntry = ""
    }
}

// MARK: - Spend

struct SpendSettingsView: View {
    @Bindable var model: ProviderSettingsModel
    @State private var capEntry = ""

    var body: some View {
        SettingsBody {
            meetingSpend
            capControls
            if model.spendEntries.isEmpty {
                FormNote("No AI calls yet. Every call this app makes appears here.")
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
        FormRow(label: "Latest meeting") {
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
                            ? "Cap reached — AI paused. Capture and transcription are unaffected."
                            : "When the cap is reached, AI features halt with a notice. "
                                + "Capture and transcription never stop."
                    )
                }
            }
        }
        if model.hasUnpricedEntries {
            FormRow(label: "") {
                FormNote("Some calls used models with no price set, so this total is partial.")
            }
        }
    }

    @ViewBuilder
    private var capControls: some View {
        FormRow(label: "Per-meeting cap") {
            TextField("none", text: $capEntry)
                .textFieldStyle(.roundedBorder)
                .font(MachineType.number(11))
                .frame(maxWidth: 90)
                .onSubmit { Task { await model.setCap(Double(capEntry)) } }
            Button("Apply") { Task { await model.setCap(Double(capEntry)) } }
            Button("Remove cap") {
                capEntry = ""
                Task { await model.setCap(nil) }
            }
            .disabled(model.settings.perMeetingCapUSD == nil)
        }
        FormRow(label: "") {
            FormNote("Costs are estimates from a built-in price list — check it against your provider's pricing page.")
        }
    }

    private var ledgerTable: some View {
        VStack(spacing: 0) {
            DataTableHeader(columns: ["Purpose", "Model", "Tokens", "Est. cost"], numericFrom: 2)
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

    var body: some View {
        SettingsBody {
            DiagnosticsSectionView(coordinator: coordinator)
            FormNote("Everything is measured on this Mac; nothing is reported anywhere.")
        }
    }
}
