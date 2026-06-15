import LoopKit
import SwiftUI
import TandemKit

struct TandemSettingsView: View {
    @ObservedObject var pumpManager: TandemPumpManager
    let onRemovePump: () -> Void

    @State private var showRemoveConfirm = false

    private var state: TandemPumpState { pumpManager.state }

    var body: some View {
        List {
            Section("Pump") {
                LabeledContent("Status") {
                    Text(connectionLabel)
                        .foregroundColor(connectionColor)
                }
                if !state.pumpSerialNumber.isEmpty {
                    LabeledContent("Serial", value: state.pumpSerialNumber)
                }
                if !state.firmwareVersion.isEmpty {
                    LabeledContent("Firmware", value: state.firmwareVersion)
                }
            }

            Section("Reservoir") {
                LabeledContent("Insulin Remaining") {
                    Text("\(Int(state.reservoirUnits)) U")
                }
            }

            Section("Battery") {
                LabeledContent("Battery") {
                    Text("\(state.batteryPercent)%")
                }
            }

            if let lastSync = pumpManager.lastSync {
                Section("Sync") {
                    LabeledContent("Last Updated") {
                        Text(lastSync, style: .relative)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    showRemoveConfirm = true
                } label: {
                    Text("Remove Pump")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("Tandem Mobi")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Remove Pump?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Pump", role: .destructive, action: onRemovePump)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop insulin delivery from this pump and remove it from Loop.")
        }
    }

    private var connectionLabel: String {
        switch state.connectionState {
        case .disconnected:    return "Disconnected"
        case .connecting:      return "Connecting…"
        case .authenticating:  return "Authenticating…"
        case .connected:       return "Connected"
        }
    }

    private var connectionColor: Color {
        switch state.connectionState {
        case .connected:       return .green
        case .authenticating:  return .orange
        default:               return .secondary
        }
    }
}
