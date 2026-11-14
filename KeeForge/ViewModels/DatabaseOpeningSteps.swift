import Foundation

/// The steps an opening screen lists for an unlock in progress.
enum DatabaseOpeningSteps {
    enum State: Equatable, Sendable {
        case done
        case current
        case upcoming
    }

    struct Step: Equatable, Sendable {
        let title: String
        let state: State
        /// The sync's percentage while it is the current step.
        let detail: String?
    }

    static func make(
        step: DatabaseViewModel.OpeningStep,
        isCloudBacked: Bool,
        provider: CloudProviderKind?,
        progress: Double?
    ) -> [Step] {
        var steps: [Step] = []
        if isCloudBacked {
            let providerName = provider?.displayName ?? String(localized: "cloud")
            steps.append(Step(
                title: String(localized: "Sync with \(providerName)"),
                state: step == .syncing ? .current : .done,
                detail: step == .syncing ? progress.map { $0.formatted(.percent.precision(.fractionLength(0))) } : nil
            ))
        }
        steps.append(Step(
            title: String(localized: "Decrypt Database"),
            state: step == .decrypting ? .current : .upcoming,
            detail: nil
        ))
        steps.append(Step(title: String(localized: "Open Database"), state: .upcoming, detail: nil))
        return steps
    }
}
