import SwiftUI

extension TOTPEnrollmentAlert {
    var alertContent: Alert {
        switch self {
        case .unsupportedLink:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("This setup link uses an unsupported code type. Only time-based (TOTP) codes are supported."),
                dismissButton: .default(Text("OK"))
            )
        case .invalidLink:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("The verification code setup link is invalid or incomplete."),
                dismissButton: .default(Text("OK"))
            )
        case .unlockNeeded:
            Alert(
                title: Text("Unlock a Database"),
                message: Text("Open and unlock a database, and KeeForge will then add the verification code."),
                dismissButton: .default(Text("OK"))
            )
        case .linkExpired:
            Alert(
                title: Text("Couldn’t Add Verification Code"),
                message: Text("This setup link expired. Open it again from the service to add the verification code."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
