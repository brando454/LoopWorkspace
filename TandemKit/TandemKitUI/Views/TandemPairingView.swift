import SwiftUI

struct TandemPairingView: View {
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var code: String = ""
    @FocusState private var fieldFocused: Bool

    private var isValid: Bool { code.count == 6 && code.allSatisfy(\.isNumber) }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(.accentColor)
                    .padding(.top, 32)

                VStack(spacing: 8) {
                    Text("Set Up Tandem Mobi")
                        .font(.largeTitle).bold()
                        .multilineTextAlignment(.center)
                    Text("On your pump, go to **Settings → Bluetooth** and note the 6-digit pairing code.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pairing Code")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    TextField("123456", text: $code)
                        .keyboardType(.numberPad)
                        .font(.system(size: 36, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        .focused($fieldFocused)
                        .onChange(of: code) { newValue in
                            // Allow only digits, max 6 chars
                            let filtered = String(newValue.filter(\.isNumber).prefix(6))
                            if filtered != newValue { code = filtered }
                        }
                }
                .padding(.horizontal)

                Button {
                    fieldFocused = false
                    onConfirm(code)
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isValid ? Color.accentColor : Color.gray.opacity(0.3))
                        .foregroundColor(isValid ? .white : .secondary)
                        .cornerRadius(12)
                        .font(.headline)
                }
                .disabled(!isValid)
                .padding(.horizontal)

                Spacer()
            }
        }
        .navigationTitle("Tandem Mobi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
        }
        .onAppear { fieldFocused = true }
    }
}
