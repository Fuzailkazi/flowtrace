import SwiftUI
import FlowTraceCore

/// Creating a thread by hand — title, why, and what's next.
struct NewThreadSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var intent = ""
    @State private var nextStep = ""
    @State private var priority: Priority = .medium

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text("New work thread").font(.system(size: 15, weight: .semibold))

            LabeledField("Title", text: $title)
            LabeledField("Why am I doing this?", text: $intent, axis: .vertical)
            LabeledField("What should I do next?", text: $nextStep, axis: .vertical)

            VStack(alignment: .leading, spacing: 3) {
                FieldLabel(text: "Priority")
                Picker("", selection: $priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    model.create(title: title, intent: intent, nextStep: nextStep, priority: priority)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 480, height: 420)
    }
}
