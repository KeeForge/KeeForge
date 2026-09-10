#if os(macOS)
import SwiftUI

/// Presented once by `AppRootView` when `MacTransitionNoticeService` finds a
/// database list left by the "Designed for iPad" build. Deliberately static
/// copy: it must be correct whether the list behind it is intact, stale, or
/// empty, so it never names a database or reports a count.
struct MacTransitionNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        let systemImage: String
    }

    private let steps: [Step] = [
        Step(
            id: "re-add",
            title: "Add each database again",
            detail: "For every database in your list, choose Remove from List, then use Import Existing Database and pick the same .kdbx file. Removing a database from the list never deletes the file itself.",
            systemImage: "externaldrive.badge.plus"
        ),
        Step(
            id: "webdav",
            title: "WebDAV databases",
            detail: "Connect your WebDAV account again instead of picking a file.",
            systemImage: "network"
        ),
        Step(
            id: "cloud",
            title: "Dropbox and OneDrive",
            detail: "This version of KeeForge for Mac doesn't connect to Dropbox or OneDrive. Open the iPad version once and let it finish syncing, then add the file from the folder Dropbox or OneDrive keeps on your Mac — it stays up to date that way.",
            systemImage: "folder"
        ),
        Step(
            id: "autofill",
            title: "Turn AutoFill back on",
            detail: "Enable KeeForge in System Settings under General > AutoFill & Passwords to fill passwords in Safari and other apps.",
            systemImage: "text.cursor"
        ),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    header

                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(steps) { step in
                            stepRow(step)
                        }
                    }
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 36)
            }
            .navigationTitle("Welcome to Mac")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("mac-transition-notice.done")
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 76, height: 76)
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            Text("Welcome to KeeForge for Mac")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("mac-transition-notice.title")

            Text("Your database files are safe and unchanged. The Mac app opens files differently from the iPad version, so it needs you to add them again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stepRow(_ step: Step) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: step.systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(step.title)
                    .font(.headline)

                Text(step.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-transition-notice.step.\(step.id)")
    }
}
#endif
