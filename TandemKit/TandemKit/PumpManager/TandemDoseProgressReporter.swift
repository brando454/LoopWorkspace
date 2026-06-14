import Foundation
import LoopKit

final class TandemDoseProgressReporter: DoseProgressReporter {
    weak var observer: DoseProgressObserver?

    private let pumpManager: TandemPumpManager
    private let queue: DispatchQueue

    init(pumpManager: TandemPumpManager, queue: DispatchQueue) {
        self.pumpManager = pumpManager
        self.queue = queue
    }

    func addObserver(_ observer: DoseProgressObserver) {
        self.observer = observer
    }

    func removeObserver(_ observer: DoseProgressObserver) {
        if self.observer === observer {
            self.observer = nil
        }
    }
}
