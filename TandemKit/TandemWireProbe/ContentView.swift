import SwiftUI

struct ContentView: View {
    @StateObject private var model = WireCaptureModel()
    @State private var pairingCode: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tandem Wire Probe")
                .font(.title2).bold()
            Text("Reads-only pairing-handshake capture. Issues no delivery commands.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                TextField("6-digit pairing code", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Button("Start Capture") {
                    model.start(pairingCode: pairingCode)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isCapturing)
            }

            HStack(spacing: 8) {
                if model.isCapturing { ProgressView() }
                Text(model.status)
                    .font(.subheadline).bold()
                    .foregroundColor(model.isAuthenticated ? .green : .primary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                }
                .onChange(of: model.logLines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .padding()
    }
}
