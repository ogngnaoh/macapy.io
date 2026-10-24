import SwiftUI

/// The isolated sample uses the same views as real meetings. One persistent
/// disclosure identifies its fictional data and scripted replies throughout.
struct SampleView: View {
    private enum Tab { case live, history, memory, briefs }
    @State private var sample: SampleSession?
    @State private var selectedTab: Tab = .live
    @State private var loadingError: String?
    @State private var resetID = UUID()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            masthead
            navigation
            Group {
                if let sample {
                    switch selectedTab {
                    case .live: liveMeeting(sample)
                    case .history:
                        HistoryView(model: sample.history, store: sample.meetings,
                                    makeDetailModel: { sample.makeDetail($0) }, isEmbedded: true)
                    case .memory: MemoryWorkspaceView(model: sample.memory, isEmbedded: true)
                    case .briefs: BriefWorkspaceView(model: sample.briefs, isEmbedded: true)
                    }
                } else if let loadingError {
                    VStack(spacing: DesignTokens.Space.s3) {
                        EmptyStateView(title: "the sample could not open", message: loadingError)
                        Button("try again") { resetID = UUID() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(DesignTokens.Space.s5)
                } else {
                    ProgressView("preparing the sample…")
                        .font(UIType.body)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            footer
        }
        .frame(minWidth: 1100, idealWidth: 1200, minHeight: 720, idealHeight: 760)
        .background(DesignTokens.bg)
        .task(id: resetID) { await load() }
        .onDisappear {
            sample?.close()
            sample = nil
        }
    }

    private var masthead: some View {
        HStack {
            Text("macapy").font(UIType.title)
            Spacer()
        }
        .foregroundStyle(DesignTokens.text)
        .padding(.horizontal, DesignTokens.Space.s5)
        .frame(height: 64)
        .background(DesignTokens.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private var navigation: some View {
        HStack(spacing: DesignTokens.Space.s5) {
            tabButton("live", tab: .live)
            tabButton("history", tab: .history)
            tabButton("memory", tab: .memory)
            tabButton("briefs", tab: .briefs)
            Spacer()
            Button {
                sample?.close()
                sample = nil
                selectedTab = .live
                resetID = UUID()
            } label: {
                Text("reset").frame(height: 45).contentShape(Rectangle())
            }
            .disabled(sample == nil)
            .accessibilityLabel("reset sample")
            .help("restore the fictional sample")
            Button {
                sample?.close()
                dismissWindow(id: WindowID.sample)
            } label: {
                Text("exit").frame(height: 45).contentShape(Rectangle())
            }
            .accessibilityLabel("exit sample")
        }
        .buttonStyle(.plain)
        .font(UIType.compactReading)
        .foregroundStyle(DesignTokens.text)
        .padding(.horizontal, DesignTokens.Space.s5)
        .frame(height: 45)
        .background(DesignTokens.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private func tabButton(_ title: String, tab: Tab) -> some View {
        Button { selectedTab = tab } label: {
            Text(title)
                .foregroundStyle(selectedTab == tab ? DesignTokens.text : DesignTokens.textSecondary)
                .padding(.horizontal, DesignTokens.Space.s1)
                .frame(height: 45)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if selectedTab == tab { Rectangle().fill(DesignTokens.selection).frame(height: 2) }
                }
        }
        .accessibilityValue(selectedTab == tab ? "selected" : "")
    }

    private func liveMeeting(_ sample: SampleSession) -> some View {
        HStack(alignment: .center, spacing: 90) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s5) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    Text("live meeting")
                        .font(UIType.body)
                        .foregroundStyle(DesignTokens.textSecondary)
                    Text(sample.featuredMeeting.title)
                        .font(UIType.title)
                        .foregroundStyle(DesignTokens.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("a fictional team working through its next launch.")
                        .font(UIType.reading)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: DesignTokens.Space.s2) {
                    Button(sample.isReplaying ? "replaying…" : "replay conversation") { sample.replay() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(sample.isReplaying)
                    Button("review meeting") { selectedTab = .history }
                        .buttonStyle(SubtleButtonStyle())
                }
                Text("follow the transcript, then try catch up or ask. replies are scripted for this sample.")
                    .font(UIType.compactReading)
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Space.s2)
                    .overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
            }
            .frame(maxWidth: 380, alignment: .leading)
            VStack(spacing: DesignTokens.Space.s2) {
                PanelView(onOpenSetup: {})
                    .environment(sample.session)
                    .environment(sample.transcript)
                    .environment(sample.copilot)
                    .overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
                Text("live panel · fictional conversation")
                    .font(UIType.small)
                    .foregroundStyle(DesignTokens.textSecondary)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, DesignTokens.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("fictional data · no capture, network, or external actions")
            Spacer()
            Text("changes reset on close · exports only when you save")
        }
        .font(UIType.small)
        .foregroundStyle(DesignTokens.textSecondary)
        .padding(.horizontal, DesignTokens.Space.s5)
        .frame(height: 40)
        .overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private func load() async {
        loadingError = nil
        do {
            let built = try await SampleSession.make()
            guard !Task.isCancelled else { built.close(); return }
            sample = built
        } catch {
            loadingError = "the local sample could not be prepared. try resetting it; your meeting history is unaffected."
        }
    }
}
