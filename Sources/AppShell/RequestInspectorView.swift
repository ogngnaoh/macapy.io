import Combine
import ProviderKit
import SwiftUI

/// Read-only inspection of the final encoded request. The view retains only
/// bounded in-memory snapshots and drops its copies when it disappears.
struct RequestInspectorView: View {
    let inspector: RequestInspector
    var isStandalone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var requests: [InspectedRequest] = []
    @State private var selectedID: UUID?
    @State private var bodyText = ""
    @State private var retainedBytes = 0
    @State private var evictedCount = 0
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                requestList.frame(width: 220)
                Rectangle().fill(DesignTokens.hairlineStrong).frame(width: 1)
                requestBody
            }
            footer
        }
        .frame(minWidth: 800, idealWidth: 900, minHeight: 600, idealHeight: 650)
        .background(DesignTokens.bg)
        .onAppear {
            isVisible = true
            refresh()
        }
        .onDisappear {
            isVisible = false
            requests.removeAll(keepingCapacity: false)
            selectedID = nil
            bodyText = ""
            retainedBytes = 0
            evictedCount = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: RequestInspector.didChange, object: inspector)
            .receive(on: DispatchQueue.main)) { _ in
                if isVisible { refresh() }
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s2) {
            HStack {
                Text("outgoing AI text")
                    .font(UIType.title)
                    .foregroundStyle(DesignTokens.text)
                Spacer()
                Chip(text: "memory only")
            }
            Text("the exact outgoing JSON, including schema and settings. It can contain meeting text. Headers, credentials, and provider responses are excluded.")
                .font(UIType.compactReading)
                .foregroundStyle(DesignTokens.textSecondary)
                .lineSpacing(3)
            FormNote("temporary and view-only. Nothing is saved to disk here.")
            DisclosureGroup("retention limits") {
                FormNote("up to 3 recent requests, 512 KiB total and 256 KiB per request. Older requests may be evicted.")
                    .padding(.top, DesignTokens.Space.s1)
            }
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
        }
        .padding(DesignTokens.Space.s4)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private var requestList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(requests) { request in
                    Button {
                        selectedID = request.id
                        bodyText = request.bodyText
                    } label: {
                        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                            Text(title(request))
                                .font(UIType.bodySemibold)
                                .foregroundStyle(DesignTokens.text)
                            Text(request.at, style: .time)
                                .font(MachineType.number())
                                .foregroundStyle(DesignTokens.textSecondary)
                            Text(request.model)
                                .font(UIType.small)
                                .foregroundStyle(DesignTokens.textSecondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Space.s3)
                        .background(selectedID == request.id ? DesignTokens.surface : .clear)
                        .overlay(alignment: .leading) {
                            if selectedID == request.id {
                                Rectangle().fill(DesignTokens.selection).frame(width: 3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(selectedID == request.id ? "selected" : "")
                    .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
                }
            }
        }
        .background(DesignTokens.sunken)
    }

    @ViewBuilder
    private var requestBody: some View {
        if let selected = requests.first(where: { $0.id == selectedID }) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                    Text(selected.destination)
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.text)
                        .lineLimit(2)
                    Text("included sources: " + (selected.sources.isEmpty
                         ? "none declared" : selected.sources.map(\.rawValue).joined(separator: ", ")))
                        .font(UIType.small)
                        .foregroundStyle(DesignTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignTokens.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
                ScrollView {
                    Text(verbatim: bodyText)
                        .font(.system(size: 12, design: .monospaced))
                        .lineSpacing(3)
                        .foregroundStyle(DesignTokens.text)
                        .textSelection(.disabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Space.s3)
                }
            }
        } else {
            EmptyStateView(title: "no retained requests", message: "requests appear when you use AI. Clearing this record never makes another provider call.")
        }
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Space.s3) {
            VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
                Text("\(requests.count) retained · \(retainedBytes.formatted()) bytes")
                if evictedCount > 0 {
                    Text("\(evictedCount) older request\(evictedCount == 1 ? " is" : "s are") no longer retained.")
                }
            }
            .font(UIType.small)
            .foregroundStyle(DesignTokens.textSecondary)
            Spacer()
            Button("clear requests") {
                inspector.clear()
                refresh()
            }
            .buttonStyle(SubtleButtonStyle())
            .disabled(requests.isEmpty && evictedCount == 0)
            Button("done") {
                if isStandalone { dismissWindow(id: WindowID.requests) }
                else { dismiss() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.cancelAction)
        }
        .padding(DesignTokens.Space.s4)
        .overlay(alignment: .top) { Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1) }
    }

    private func refresh() {
        guard isVisible else { return }
        requests = inspector.snapshots
        retainedBytes = inspector.retainedBytes
        evictedCount = inspector.evictedCount
        if !requests.contains(where: { $0.id == selectedID }) { selectedID = requests.first?.id }
        bodyText = requests.first(where: { $0.id == selectedID })?.bodyText ?? ""
    }

    private func title(_ request: InspectedRequest) -> String {
        if request.sources.contains(.connectionTest) { return "connection test" }
        switch request.purpose {
        case .classifier: return "live classification"
        case .generation: return "copilot response"
        case .artifact: return "meeting draft"
        case .memory: return "memory request"
        case .brief: return "pre-meeting brief"
        }
    }
}
