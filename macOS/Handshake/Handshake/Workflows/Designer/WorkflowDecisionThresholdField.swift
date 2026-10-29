import SwiftUI

/// Apply valid input immediately so a later focus change cannot overwrite a restored answer form.
struct WorkflowDecisionThresholdField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var typedValue: Int?
    @FocusState private var focused: Bool

    private var entry: Binding<String> {
        Binding(
            get: { text },
            set: { proposed in
                text = proposed
                guard let percentage = try? Double(proposed, format: .number.locale(locale)), percentage.isFinite else {
                    return
                }
                let basisPoints = Int((min(100, max(0, percentage)) * 100).rounded())
                let clamped = min(range.upperBound, max(range.lowerBound, basisPoints))
                typedValue = clamped
                value = clamped
            })
    }

    private var increment: Binding<Int> {
        Binding(
            get: { value },
            set: {
                value = $0
                text = formatted
            })
    }

    private var formatted: String {
        (Double(value) / 100).formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, text: entry).focused($focused).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).frame(width: 60)
                    .accessibilityLabel("\(title), percent").accessibilityIdentifier(identifier)
                    .onChange(of: value, initial: true) {
                        let fromTyping = typedValue == value
                        typedValue = nil
                        if !fromTyping { text = formatted }
                    }
                    .onChange(of: focused) {
                        if !focused {
                            typedValue = nil
                            text = formatted
                        }
                    }
                Text("%").foregroundStyle(.secondary)
                Stepper("", value: increment, in: range, step: 100).labelsHidden().fixedSize()
                    .accessibilityLabel("Adjust \(title.lowercased())")
                    .accessibilityValue("\(Double(value) / 100) percent")
            }
        }
    }
}
