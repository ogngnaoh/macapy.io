import AppKit
import EventKit
import SwiftUI

struct BriefWorkspaceView: View {
  @Bindable var model: BriefWorkspaceModel
  var isEmbedded = false
  @State private var reviewingEvidence = false

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
          Text("calendars & briefs").font(UIType.bodySemibold)
          Toggle(
            "calendar briefs",
            isOn: Binding(
              get: { model.preferences.enabled },
              set: { value in Task { await model.setEnabled(value) } })
          )
          .disabled(model.workDeferred)
          if model.preferences.enabled {
            Toggle(
              "automatic ai summaries",
              isOn: Binding(
                get: { model.preferences.automaticAIEnabled },
                set: { value in Task { await model.setAutomaticAI(value) } })
            )
            .disabled(model.workDeferred)
            FormNote(
              "optional ai sends reviewed history and ai-enabled sources to your provider. event titles, descriptions and attendees stay out. up to five a day while open; pauses during meetings."
            )
            SectionHead(title: "calendars")
            ForEach(model.calendars) { calendar in
              Toggle(
                calendar.title,
                isOn: Binding(
                  get: { model.preferences.selectedCalendarIDs.contains(calendar.id) },
                  set: { value in Task { await model.setCalendar(calendar.id, selected: value) } }))
            }
            SectionHead(title: "next 24 hours")
            VStack(spacing: 0) {
              ForEach(model.events) { item in
                Button {
                  Task { await model.select(item.id) }
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(item.event.title.isEmpty ? "untitled event" : item.event.title).font(
                      UIType.bodySemibold)
                    Text(item.event.startDate.formatted(date: .abbreviated, time: .shortened)).font(
                      UIType.small)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(
                    .horizontal, DesignTokens.Space.s3
                  ).padding(.vertical, DesignTokens.Space.s4)
                    .background(
                      model.selectedID == item.id ? DesignTokens.surface : .clear
                    )
                    .overlay(alignment: .leading) {
                      if model.selectedID == item.id {
                        Rectangle().fill(DesignTokens.text).frame(width: 2)
                      }
                    }
                }.buttonStyle(.plain)
              }
              if model.events.isEmpty {
                FormNote("no events in the next 24 hours.").padding(.vertical)
              }
            }
          }
          if let budget = model.budget {
            FormNote(
              String(
                format:
                  "ai budget · $%.3f / $0.10\ndaily allowance resets %@. unresolved usage stays reserved.",
                budget.committedUSD,
                budget.nextResetAt.formatted(date: .abbreviated, time: .shortened)))
          }
          Button("refresh") { Task { await model.refresh() } }.buttonStyle(SubtleButtonStyle())
            .disabled(model.workDeferred || !model.preferences.enabled)
        }
        .padding(DesignTokens.Space.s4).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 235).background(DesignTokens.sunken)
      Rectangle().fill(DesignTokens.hairlineStrong).frame(width: 1)
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if model.workDeferred {
            FormNote("briefs pause during meetings so capture keeps priority.")
          }
          if let message = model.message { FormNote(message) }
          if model.isWorking {
            HStack(spacing: DesignTokens.Space.s3) {
              ProgressView().controlSize(.small)
              Text(
                model.workingAutomatically ? "preparing automatic briefs…" : "writing your brief…"
              )
              .font(UIType.body)
              Spacer()
              Button("cancel") { model.cancelAndClear() }.buttonStyle(SubtleButtonStyle())
            }
          }
          if let event = model.selectedEvent {
            Text(event.event.title.isEmpty ? "untitled event" : event.event.title).font(
              UIType.title)
            Text(
              event.event.isAllDay
                ? "all day · \(event.event.startDate.formatted(date: .complete, time: .omitted))"
                : event.event.startDate.formatted(date: .complete, time: .shortened)
            )
            .font(UIType.compactReading).foregroundStyle(DesignTokens.textSecondary)
            DisclosureGroup("people & projects") {
              VStack(alignment: .leading, spacing: 8) {
                FormNote(
                  "choose the people and projects for this event. titles never link them automatically."
                )
                ForEach(model.entities) { entity in
                  Toggle(
                    entity.name,
                    isOn: Binding(
                      get: { event.entityIDs.contains(entity.id) },
                      set: { value in Task { await model.setEntity(entity.id, selected: value) } }))
                }
                if model.entities.isEmpty {
                  FormNote("add a person or project in memory first.")
                }
              }.padding(.top, 10)
            }.disabled(model.workDeferred || model.isWorking)
            if let snapshot = model.snapshot {
              SectionHead(
                title: snapshot.mode == .local
                  ? "your brief" : "ai brief · check the sources")
              if snapshot.mode == .local, !snapshot.context.isEmpty {
                ForEach(snapshot.context.excerpts) { excerpt in
                  briefText(excerpt.text)
                }
              } else {
                briefText(snapshot.text)
              }
              if !snapshot.context.isEmpty {
                HStack(spacing: DesignTokens.Space.s3) {
                  ForEach(Array(snapshot.context.excerpts.enumerated()), id: \.offset) {
                    index, excerpt in
                    if let source = excerpt.sources.first {
                      Button("source \(index + 1)") { Task { await model.preview(source) } }
                        .buttonStyle(.plain).foregroundStyle(DesignTokens.accent)
                    }
                  }
                }.font(UIType.body)
                if let preview = model.sourcePreview {
                  Text(preview).font(UIType.compactReading).textSelection(.enabled)
                    .padding(DesignTokens.Space.s4).frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.sunken)
                }
                Rectangle().fill(DesignTokens.hairlineStrong).frame(height: 1)
                DisclosureGroup("review sources & use ai", isExpanded: $reviewingEvidence) {
                  VStack(alignment: .leading, spacing: DesignTokens.Space.s4) {
                    ForEach(snapshot.context.excerpts) { excerpt in
                      VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                          "include this source",
                          isOn: Binding(
                            get: { model.selectedCitationIDs.contains(excerpt.citationID) },
                            set: { include in
                              if include {
                                model.selectedCitationIDs.insert(excerpt.citationID)
                              } else {
                                model.selectedCitationIDs.remove(excerpt.citationID)
                              }
                            })
                        )
                        .disabled(model.isWorking)
                        Text(excerpt.title).font(UIType.bodySemibold)
                        Text(excerpt.text).font(UIType.compactReading).foregroundStyle(
                          DesignTokens.textSecondary)
                        ForEach(Array(excerpt.sources.enumerated()), id: \.offset) { _, source in
                          Button(
                            source.pageNumber.map { "open source · page \($0)" } ?? "open source"
                          ) {
                            Task { await model.preview(source) }
                          }.buttonStyle(SubtleButtonStyle())
                        }
                      }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().stroke(DesignTokens.hairline))
                    }
                    Toggle(
                      "include the event title", isOn: $model.includeEventTitleForAI
                    )
                    .disabled(model.isWorking)
                    FormNote(
                      "sends selected sources and, if checked, the event title to your provider. descriptions and attendees stay out. a separate daily ai budget applies."
                    )
                    HStack {
                      Button(
                        model.isWorking
                          ? (model.workingAutomatically
                            ? "preparing briefs…" : "writing…")
                          : "send selected sources"
                      ) { model.generateSummary() }
                      .buttonStyle(PrimaryButtonStyle()).disabled(
                        model.isWorking || model.workDeferred || model.selectedCitationIDs.isEmpty)
                    }
                  }.padding(.top, DesignTokens.Space.s4)
                }.font(UIType.body)
              }
            }
          } else {
            Text("before you meet.").font(UIType.title)
            FormNote(
              "turn on briefs, choose a calendar, then link an event to people or projects. local briefs need no ai provider. calendar content is never sent automatically."
            )
          }
        }.padding(DesignTokens.Space.s5).frame(maxWidth: 850, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(minWidth: 960, minHeight: isEmbedded ? 440 : 660).background(DesignTokens.bg)
    .foregroundStyle(DesignTokens.text)
    .font(UIType.body)
    .task { await model.start() }
    .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
      Task { await model.refresh() }
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
    ) { _ in Task { await model.refresh() } }
    .onDisappear { model.cancelAndClear() }
  }

  /// Present local Markdown headings as typography, without rewriting the
  /// source, loading remote assets, or interpreting links as actions.
  private func briefText(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
        let heading = line.prefix(while: { $0 == "#" })
        if !heading.isEmpty, heading.count <= 6, line.dropFirst(heading.count).hasPrefix(" ") {
          Text(String(line.dropFirst(heading.count + 1))).font(UIType.bodySemibold)
            .padding(.bottom, 5)
        } else if line.isEmpty {
          Color.clear.frame(height: 5)
        } else {
          Text(verbatim: line).font(UIType.reading).lineSpacing(5)
        }
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
