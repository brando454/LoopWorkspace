import LoopKitUI
import TandemKit
import TandemKitUI

@objc(TandemKitPlugin)
class TandemKitPlugin: NSObject, PumpManagerUIPlugin {
    public var pumpManagerType: PumpManagerUI.Type? {
        TandemPumpManager.self
    }

    public var cgmManagerType: CGMManagerUI.Type? {
        nil
    }

    override init() {
        super.init()
    }
}
