import SwiftUI

struct GroupIconView: View {
    let iconID: Int
    var customIconData: Data? = nil
    var size: CGFloat = 22

    var body: some View {
        if let customIconData, let icon = PlatformImage(data: customIconData) {
            Image(platformImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: size, height: size)
        } else {
            StandardIconView(
                iconID: iconID,
                fallbackSystemName: "folder.fill",
                fallbackPalette: .blue
            )
        }
    }
}
