import AgentKit
import MemoryKit
import SwiftUI

struct LiveAskSourcesView: View {
    @Bindable var model: LiveAskSourcesModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("choose the evidence").font(UIType.title); Spacer()
                Button("close") { model.cancel(); dismiss() }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction) }
            Text(model.question).font(UIType.reading).textSelection(.enabled)
            FormNote("this question uses only checked excerpts: up to four recent transcript snippets and four saved sources, 8,000 characters total. source lookup stays on this mac. nothing is sent until you choose send.")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHead(title: "recent transcript · 90-second snapshot")
                    FormNote("these literal snippets were captured when this review opened. new speech is not added to this request automatically.")
                    if model.recentTranscript.isEmpty { FormNote("no finalized speech in this window. saved sources can still provide evidence.") }
                    ForEach(model.recentTranscript) { item in
                        Toggle(isOn: selected(item.id, in: $model.selectedTranscriptIDs)) {
                            evidence(title: item.title, text: item.text)
                        }.toggleStyle(.checkbox)
                    }
                    Divider()
                    DisclosureGroup("saved sources & dates") {
                        VStack(alignment: .leading, spacing: 12) {
                            FormNote("saved sources start unselected. documents must already allow ai context and belong to a selected meeting.")
                            ForEach(model.meetings) { meeting in
                                Toggle(meeting.title, isOn: selected(meeting.id, in: $model.selectedMeetingIDs)).toggleStyle(.checkbox)
                            }
                            Divider()
                            ForEach(model.documents) { document in
                                Toggle(document.name, isOn: selected(document.id, in: $model.selectedDocumentIDs)).toggleStyle(.checkbox)
                            }
                            Picker("person or project", selection: $model.selectedEntityID) {
                                Text("any explicit association").tag(UUID?.none)
                                ForEach(model.entities) { entity in Text(entity.name).tag(Optional(entity.id)) }
                            }
                            Toggle("saved evidence as of", isOn: $model.useAsOf).toggleStyle(.checkbox)
                            if model.useAsOf { DatePicker("as of", selection: $model.asOf, displayedComponents: [.date, .hourAndMinute]) }
                        }.padding(.top, 10)
                    }
                    HStack { Button(model.isSearching ? "finding sources…" : "find saved sources") { model.search() }
                            .buttonStyle(SubtleButtonStyle()).disabled(model.isSearching)
                        if model.isSearching { ProgressView().controlSize(.small) } }
                    if let results = model.results {
                        ForEach(results.excerpts) { item in
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: selected(item.citationID, in: $model.selectedExternalIDs)) { evidence(title: item.title, text: item.text) }.toggleStyle(.checkbox)
                                HStack {
                                    ForEach(Array(item.sources.enumerated()), id: \.offset) { index, source in
                                        Button("source \(index + 1) ↗") { Task { await model.preview(source) } }
                                            .buttonStyle(.plain).font(UIType.small).foregroundStyle(DesignTokens.accent)
                                    }
                                }
                            }.padding(.vertical, 15).overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
                        }
                    }
                    if let preview = model.sourcePreview { Text(verbatim: preview).font(UIType.compactReading).textSelection(.enabled).padding(14).background(DesignTokens.sunken) }
                }
            }
            if let message = model.message { FormNote(message) }
            HStack { Text("\(model.selectedCharacters) / 8,000 characters").font(UIType.small).foregroundStyle(DesignTokens.textSecondary); Spacer()
                Button("send selected & ask") { Task { if await model.send() { dismiss() } } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!model.canSend) }
            FormNote("uses the current meeting’s provider and remaining cap. capture continues independently. answers include clickable sources.")
        }.padding(30).frame(width: 700, height: 700).background(DesignTokens.bg)
        .task { await model.load() }
        .onDisappear { model.cancel() }
    }
    private func evidence(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(UIType.bodySemibold)
            Text(verbatim: text).font(UIType.reading).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func selected<ID: Hashable>(_ id: ID, in binding: Binding<Set<ID>>) -> Binding<Bool> {
        .init(get: { binding.wrappedValue.contains(id) }, set: { included in
            if included { binding.wrappedValue.insert(id) } else { binding.wrappedValue.remove(id) }
        })
    }
}

struct LiveGroundingEvidenceView: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(title).font(UIType.heading); Spacer(); Button("done") { dismiss() }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction) }
            ScrollView { Text(verbatim: text).font(UIType.reading).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(26).frame(width: 620, height: 500).background(DesignTokens.bg)
    }
}
