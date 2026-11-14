import CryptoKit
import Foundation
import OneTimeCodes

@MainActor
@Observable
final class TOTPViewModel {
    private(set) var code: String = TOTPGenerator.placeholderCode
    private(set) var secondsRemaining: Int = 0
    private(set) var progress: Double = 1.0

    private var config: TOTPConfig
    private var parameters: TOTPParameters?
    private(set) var timer: Timer?

    var period: Int { config.period }

    /// `code` split in the middle the way authenticator apps print it
    /// ("284 019"); a code with an odd number of digits stays whole.
    var groupedCode: String { Self.grouped(code) }

    static func grouped(_ code: String) -> String {
        guard code.count >= 6, code.count.isMultiple(of: 2) else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }

    init(config: TOTPConfig, sessionKey: SymmetricKey) {
        self.config = config
        self.parameters = TOTPGenerator.parameters(for: config, sessionKey: sessionKey)
        refresh()
    }

    func start() {
        stop()
        refresh()
        // On whole seconds, so every countdown showing the same code reads the same number.
        let timer = Timer(fire: Self.nextWholeSecond(after: .now), interval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.current.add(timer, forMode: .default)
        self.timer = timer
    }

    static func nextWholeSecond(after date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 + 1).rounded(.down))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func update(config: TOTPConfig, sessionKey: SymmetricKey, date: Date = .now) {
        self.config = config
        parameters = TOTPGenerator.parameters(for: config, sessionKey: sessionKey)
        refresh(date: date)
    }

    private func refresh(date: Date = .now) {
        code = TOTPGenerator.code(for: parameters, at: date)
        secondsRemaining = TOTP.secondsRemaining(period: config.period, at: date)
        progress = Double(secondsRemaining) / Double(config.period)
    }

}
