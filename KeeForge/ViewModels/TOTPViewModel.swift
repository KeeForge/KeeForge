import CryptoKit
import Foundation

@MainActor
@Observable
final class TOTPViewModel {
    private(set) var code: String = "------"
    private(set) var secondsRemaining: Int = 0
    private(set) var progress: Double = 1.0

    private let config: TOTPConfig
    private let resolvedSecret: TOTPGenerator.ResolvedSecret?
    private var timer: Timer?

    var period: Int { config.period }

    init(config: TOTPConfig, sessionKey: SymmetricKey) {
        self.config = config
        self.resolvedSecret = TOTPGenerator.resolveSecret(config: config, sessionKey: sessionKey)
        refresh()
    }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let now = Date()
        code = TOTPGenerator.generateCode(config: config, resolvedSecret: resolvedSecret, date: now)
        secondsRemaining = TOTPGenerator.secondsRemaining(period: config.period, date: now)
        progress = Double(secondsRemaining) / Double(config.period)
    }

}
