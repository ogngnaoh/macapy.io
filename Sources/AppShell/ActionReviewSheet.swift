import ActionKit
import PersistKit
import SwiftUI

struct ActionReviewSheet: View {
    @Bindable var model: ActionReviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
            if model.isSample {
                Text("sample / no external action").font(UIType.small)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(DesignTokens.brandPink)
                FormNote("this review uses a fictional destination. creating an item changes only the sample’s temporary database.")
            }
            Text(model.kind == .calendarEvent ? "create a calendar event" : "create a reminder")
                .font(UIType.title)
            FormNote("create one new item after reviewing every field. your meeting transcript and other drafts are not included.")
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Space.s3) {
                    if let reviewed = model.reviewed { review(reviewed) }
                    else { editor }
                    if !model.records.isEmpty {
                        SectionHead(title: "saved attempts")
                        ForEach(model.records) { record in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(record.action.title) · \(record.action.target.title)").font(UIType.bodySemibold)
                                Text(status(record.status)).font(UIType.small)
                                if record.status == .needsReconciliation {
                                    HStack {
                                        Button("check outcome") { Task { await model.reconcile(record) } }
                                        Button("allow outcome lookup") { Task { await model.grantAccess(forReconciliation: true) } }
                                    }.buttonStyle(SubtleButtonStyle())
                                }
                            }.padding(.vertical, 15).frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.hairline).frame(height: 1) }
                        }
                    }
                }
            }.frame(maxHeight: 440)
            if let message = model.message {
                Text(message).font(UIType.small).foregroundStyle(model.succeeded ? DesignTokens.statusApproved : DesignTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(model.succeeded ? "done" : "close") { dismiss() }.buttonStyle(SubtleButtonStyle())
                Spacer()
                if !model.succeeded {
                    if model.reviewed != nil {
                        Button("edit") { model.editReview() }.buttonStyle(SubtleButtonStyle())
                        Button(model.isBusy ? "saving…" : model.isSample ? "approve & create sample" : "approve & create") {
                            Task { await model.approveAndCreate() }
                        }.buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button("review exact item") { model.prepareReview() }
                            .buttonStyle(PrimaryButtonStyle()).disabled(!model.canCreate || model.targetID.isEmpty)
                    }
                }
            }.disabled(model.isBusy)
        }
        .padding(30).frame(width: 600)
        .background(DesignTokens.bg).foregroundStyle(DesignTokens.text)
        .interactiveDismissDisabled(model.isBusy)
        .task { await model.load() }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.canCreate {
                FormNote(model.kind == .calendarEvent ? "Calendar permission is optional. Allow it only if you want to create this event." : "Reminders permission is optional. Allow it only if you want to create this task.")
                Button("allow access") { Task { await model.grantAccess() } }.buttonStyle(SubtleButtonStyle())
            }
            Picker(model.kind == .calendarEvent ? "Calendar" : "reminder list", selection: $model.targetID) {
                if model.targets.isEmpty { Text("no writable destinations").tag("") }
                ForEach(model.targets) { Text($0.title).tag($0.id) }
            }
            TextField("title", text: $model.title).textFieldStyle(.plain).padding(10).overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
            Text("notes included in the new item").font(UIType.small)
            TextEditor(text: $model.notes).font(UIType.reading).frame(height: 70)
                .overlay(Rectangle().stroke(DesignTokens.hairline))
            if model.kind == .reminder { Toggle("include a due date", isOn: $model.hasDueDate) }
            if model.kind == .calendarEvent || model.hasDueDate {
                DatePicker(model.kind == .calendarEvent ? "start" : "due", selection: $model.start)
                    .environment(\.timeZone, TimeZone(identifier: model.timeZoneIdentifier) ?? .current)
            }
            if model.kind == .calendarEvent {
                DatePicker("end", selection: $model.end)
                    .environment(\.timeZone, TimeZone(identifier: model.timeZoneIdentifier) ?? .current)
            }
            TextField("time zone", text: $model.timeZoneIdentifier).textFieldStyle(.plain).padding(10).overlay(Rectangle().stroke(DesignTokens.hairlineStrong))
            FormNote("dates are your selection. a draft deadline is not automatically interpreted. no attendees, invitations, or recurring series are created.")
        }.font(UIType.compactReading).disabled(model.isBusy)
    }

    private func review(_ action: ReviewedAction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHead(title: "exact item to create")
            Text(action.title).font(UIType.heading)
            Text("Destination · \(action.target.title)").font(UIType.bodySemibold)
            Text(schedule(action.schedule)).font(UIType.compactReading)
            Text("Time zone · \(action.schedule.timeZoneIdentifier)").font(UIType.small)
            Text(action.externalNotes).font(UIType.reading).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(DesignTokens.sunken)
            FormNote("the operation marker above is included in notes so an uncertain save can be checked without creating a duplicate.")
        }
    }

    private func schedule(_ schedule: ActionSchedule) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: schedule.timeZoneIdentifier)
        switch schedule {
        case .calendar(let start, let end, _): return "\(formatter.string(from: start)) → \(formatter.string(from: end))"
        case .reminder(let due, _): return due.map { "Due · \(formatter.string(from: $0))" } ?? "no due date"
        }
    }

    private func status(_ status: ActionJournalStatus) -> String {
        switch status {
        case .prepared: "approval saved; dispatch has not started."
        case .dispatching: "dispatch began; receipt is pending."
        case .created: "created."
        case .failed: "no save attempted."
        case .needsReconciliation: "outcome unknown. retry blocked."
        }
    }
}
