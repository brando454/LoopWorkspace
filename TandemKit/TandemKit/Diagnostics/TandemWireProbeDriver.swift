import Combine
import Foundation

// Diagnostic-only, READS-ONLY public facade over the (internal) Tandem BLE
// stack. It exists solely to let a separate app module capture the EC-JPAKE
// pairing handshake against a spare pump for protocol validation.
//
// SAFETY CONTRACT — this type is delivery-incapable by construction:
//   • It exposes exactly four capabilities: set the pairing code, set an
//     observe-only wire tap, start a reads-only handshake, and observe the
//     connection/auth state.
//   • It has NO bolus, basal, suspend, resume, cancel, or CONTROL-write method,
//     and never constructs a delivery request.
//   • startReadOnlyHandshake bottoms out in connectAndAuthenticateOnly, which
//     drives scan -> connect -> discover -> authenticate and then stops; the
//     only frames on the wire are the handshake itself.
//   • The wire tap returns Void and cannot alter, drop, or reorder a frame.
public final class TandemWireProbeDriver: ObservableObject {

    private let pumpManager: TandemPumpManager
    private var cancellable: AnyCancellable?

    @Published public private(set) var connectionState: TandemConnectionState = .disconnected

    public init() {
        let state = TandemPumpState(basalRateSchedule: nil)
        self.pumpManager = TandemPumpManager(state: state)
        self.connectionState = pumpManager.state.connectionState
        // The pump manager is an ObservableObject that publishes on state
        // mutation; mirror its connection state onto our own @Published so the
        // probe UI can react to scan -> connecting -> authenticating -> connected.
        cancellable = pumpManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                self.connectionState = self.pumpManager.state.connectionState
            }
    }

    // Pairing code is read by startAuthentication() from pump state. Setting it
    // here (before the handshake) populates the value the auth machine reads.
    public func setPairingCode(_ code: String) {
        pumpManager.state.pairingCode = code
    }

    // Observe-only tap: receives a copy of every frame placed on or read from
    // the wire. Cannot mutate transport behavior.
    public func setWireTap(_ tap: @escaping (WireDirection, Data) -> Void) {
        pumpManager.wireTap = tap
    }

    // Drives connect + EC-JPAKE auth, then stops. Issues no delivery commands.
    public func startReadOnlyHandshake(completion: @escaping (Error?) -> Void) {
        pumpManager.startDiagnosticHandshake(completion: completion)
    }

    public var isAuthenticated: Bool {
        connectionState == .connected
    }
}
