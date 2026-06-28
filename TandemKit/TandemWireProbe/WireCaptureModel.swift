import Combine
import Foundation
import TandemKit

// Drives the reads-only TandemWireProbeDriver and records captured frames both
// to an on-disk log in Documents and to the on-screen log. NEVER issues any
// delivery command — the driver exposes none.
final class WireCaptureModel: ObservableObject {

    @Published var status: String = "Idle"
    @Published var logLines: [String] = []
    @Published var isCapturing: Bool = false
    @Published var logFileURL: URL?

    private var driver: TandemWireProbeDriver?
    private var cancellable: AnyCancellable?

    private let fileQueue = DispatchQueue(label: "com.loopandlearn.TandemWireProbe.fileLog")
    private var fileHandle: FileHandle?

    private let lineFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var isAuthenticated: Bool { status.hasPrefix("AUTHENTICATED") }

    func start(pairingCode: String) {
        guard !isCapturing else { return }
        let trimmed = pairingCode.trimmingCharacters(in: .whitespaces)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            status = "Enter a 6-digit pairing code"
            return
        }

        logLines.removeAll()
        isCapturing = true
        status = "Starting…"

        openLogFile()

        let driver = TandemWireProbeDriver()
        self.driver = driver

        cancellable = driver.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, self.isCapturing else { return }
                switch state {
                case .disconnected:   self.status = "Scanning / connecting…"
                case .connecting:     self.status = "Connecting…"
                case .authenticating: self.status = "Authenticating (EC-JPAKE)…"
                case .connected:      self.status = "AUTHENTICATED — capture complete"
                }
            }

        driver.setPairingCode(trimmed)
        driver.setWireTap { [weak self] direction, data in
            self?.record(direction: direction, data: data)
        }

        driver.startReadOnlyHandshake { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCapturing = false
                if let error {
                    self.status = "Failed: \(error.localizedDescription)"
                    self.append("ERROR: \(error.localizedDescription)")
                } else {
                    self.status = "AUTHENTICATED — capture complete"
                    self.append("AUTHENTICATED — capture complete")
                }
                self.closeLogFile()
            }
        }
    }

    private func record(direction: WireDirection, data: Data) {
        let tag = direction == .outbound ? "TX" : "RX"
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        let line = "\(lineFormatter.string(from: Date())) \(tag) [\(data.count)] \(hex)"
        appendToFile(line)
        DispatchQueue.main.async { [weak self] in self?.append(line) }
    }

    private func append(_ line: String) {
        logLines.append(line)
    }

    private func openLogFile() {
        let stamp = lineFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let name = "wirecap_\(stamp).log"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileQueue.sync { self.fileHandle = try? FileHandle(forWritingTo: url) }
        logFileURL = url
        append("Log file: \(url.lastPathComponent)")
    }

    private func appendToFile(_ line: String) {
        fileQueue.async {
            guard let handle = self.fileHandle, let data = (line + "\n").data(using: .utf8) else { return }
            handle.write(data)
        }
    }

    private func closeLogFile() {
        fileQueue.async {
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }
}
