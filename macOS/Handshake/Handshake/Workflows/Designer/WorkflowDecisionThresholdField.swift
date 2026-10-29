import SwiftUI

/// Apply valid input immediately so a later focus change cannot overwrite a restored answer form.
struct WorkflowDecisionThresholdField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String
    let scale: Int
    let suffix: String?
    let step: Int
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var typedValue: Int?
    @FocusState private var focused: Bool

    init(
        title: String, value: Binding<Int>, range: ClosedRange<Int>, identifier: String,
        scale: Int = 100, suffix: String? = "%", step: Int = 100
    ) {
        self.title = title
        self._value = value
        self.range = range
        self.identifier = identifier
        self.scale = scale
        self.suffix = suffix
        self.step = step
    }

    private var entry: Binding<String> {
        Binding(
            get: { text },
            set: { proposed in
                text = proposed
                guard let number = try? Double(proposed, format: .number.locale(locale)), number.isFinite else {
                    return
                }
                let bounded = min(
                    Double(range.upperBound) / Double(scale), max(Double(range.lowerBound) / Double(scale), number))
                let clamped = Int((bounded * Double(scale)).rounded())
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
        (Double(value) / Double(scale)).formatted(.number.precision(.fractionLength(0...4)).locale(locale))
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: entry).labelsHidden().focused($focused).textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).frame(width: 60)
                    .accessibilityLabel(suffix == "%" ? "\(title), percent" : title)
                    .accessibilityIdentifier(identifier)
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
                if let suffix { Text(suffix).foregroundStyle(.secondary) }
                Stepper("", value: increment, in: range, step: step).labelsHidden().fixedSize()
                    .accessibilityLabel("Adjust \(title.lowercased())")
                    .accessibilityValue(suffix == "%" ? "\(formatted) percent" : formatted)
            }
        }
    }
}
