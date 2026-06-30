import Foundation
import LoopKit

final class TandemDoseProgressReporter: DoseProgressReporter {
    weak var observer: DoseProgressObserver?

    var progress: DoseProgress = DoseProgress(deliveredUnits: 0, percentComplete: 0)

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

    // WP6/M3+M6: push a new progress value and notify the observer. Called from
    // the status poll with a TIME-ESTIMATED deliveredUnits, because
    // CurrentBolusStatus carries no delivered-so-far field; the estimate is
    // superseded by the pump-confirmed completed reconcile. The observer MUST be
    // notified on this reporter own queue (the dispatchQueue LoopKit passed to
    // createBolusProgressReporter), never on the pump manager stateQueue.
    func update(deliveredUnits: Double, percentComplete: Double) {
        queue.async {
            self.progress = DoseProgress(deliveredUnits: deliveredUnits, percentComplete: percentComplete)
            self.observer?.doseProgressReporterDidUpdate(self)
        }
    }
}
