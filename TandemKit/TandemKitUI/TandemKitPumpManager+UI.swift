import LoopKit
import LoopKitUI
import TandemKit
import UIKit

extension TandemPumpManager: PumpManagerUI {

    public static func setupViewController(
        initialSettings settings: PumpManagerSetupSettings,
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<any PumpManagerViewController, any PumpManagerUI> {
        let coordinator = TandemUICoordinator(
            colorPalette: colorPalette,
            setupSettings: settings,
            allowedInsulinTypes: allowedInsulinTypes
        )
        return .userInteractionRequired(coordinator)
    }

    public func settingsViewController(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        TandemUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    public func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> (UIViewController & CompletionNotifying) {
        TandemDeliveryUncertaintyVC()
    }

    public var smallImage: UIImage? { nil }

    public func hudProvider(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) -> HUDProvider? { nil }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? { nil }

    public static var onboardingImage: UIImage? { nil }

    // MARK: - PumpStatusIndicator

    public var pumpStatusHighlight: DeviceStatusHighlight? { nil }
    public var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }
    public var pumpStatusBadge: DeviceStatusBadge? { nil }
}

private final class TandemDeliveryUncertaintyVC: UIViewController, CompletionNotifying {
    weak var completionDelegate: CompletionDelegate?
}
