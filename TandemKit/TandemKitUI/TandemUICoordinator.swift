import LoopKit
import LoopKitUI
import SwiftUI
import TandemKit
import UIKit

// Navigation coordinator for both the setup flow and the settings flow.
// Setup flow: pairing code entry → BLE pairing → done
// Settings flow: pump info + remove pump
final class TandemUICoordinator: UINavigationController,
    PumpManagerOnboarding, CompletionNotifying, UIAdaptivePresentationControllerDelegate
{
    var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private var pumpManager: TandemPumpManager?
    private let colorPalette: LoopUIColorPalette
    private let setupSettings: PumpManagerSetupSettings?
    private let allowedInsulinTypes: [InsulinType]

    // MARK: - Init (setup flow)
    init(
        colorPalette: LoopUIColorPalette,
        setupSettings: PumpManagerSetupSettings,
        allowedInsulinTypes: [InsulinType]
    ) {
        self.pumpManager = nil
        self.colorPalette = colorPalette
        self.setupSettings = setupSettings
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    // MARK: - Init (settings flow)
    init(
        pumpManager: TandemPumpManager,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) {
        self.pumpManager = pumpManager
        self.colorPalette = colorPalette
        self.setupSettings = nil
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        presentationController?.delegate = self

        if pumpManager == nil {
            pushViewController(pairingCodeViewController(), animated: false)
        } else {
            pushViewController(settingsViewController(), animated: false)
        }
    }

    // MARK: - Screen factories

    private func pairingCodeViewController() -> UIViewController {
        let view = TandemPairingView { [weak self] code in
            self?.handlePairingCodeEntered(code)
        } onCancel: { [weak self] in
            self?.completionDelegate?.completionNotifyingDidComplete(self!)
        }
        return hostingController(rootView: view)
    }

    private func settingsViewController() -> UIViewController {
        let view = TandemSettingsView(
            pumpManager: pumpManager!,
            onRemovePump: { [weak self] in self?.removePump() }
        )
        return hostingController(rootView: view)
    }

    // MARK: - Actions

    private func handlePairingCodeEntered(_ code: String) {
        let state = TandemPumpState(basalRateSchedule: setupSettings?.basalSchedule)
        state.pairingCode = code
        let manager = TandemPumpManager(state: state)
        pumpManager = manager
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: manager)

        // Show a brief "Searching for pump…" screen then signal done.
        // The BLE manager will start scanning when Loop calls ensureCurrentPumpData.
        let done = TandemConnectingView {
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        pushViewController(hostingController(rootView: done), animated: true)
    }

    private func removePump() {
        guard let pm = pumpManager else { return }
        pm.notifyDelegateOfDeactivation {
            DispatchQueue.main.async {
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
        }
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    // MARK: - Helpers

    private func hostingController<Content: View>(rootView: Content) -> UIHostingController<Content> {
        let hc = UIHostingController(rootView: rootView)
        hc.view.backgroundColor = .systemBackground
        return hc
    }
}
