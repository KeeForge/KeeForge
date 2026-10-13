import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import KeeForge

@MainActor
final class GroupIconViewTests: XCTestCase {
    func testCustomImageTakesPrecedenceAndKeepsItsColorsWhenSelected() throws {
        let pixel: [UInt8] = [20, 190, 40, 255]
        let pixels = Array(repeating: pixel, count: 16 * 16).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let source = try XCTUnwrap(CGImage(
            width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = try pngData(source)

        for (size, prominence) in [(CGFloat(18), BackgroundProminence.standard), (18, .increased), (22, .standard)] {
            let image = try render(
                GroupIconView(iconID: 0, customIconData: data, size: size)
                    .environment(\.backgroundProminence, prominence)
            )
            let bitmap = try rgbaPixels(image)
            let center = ((image.height / 2) * image.width + image.width / 2) * 4
            for (actual, expected) in zip(bitmap[center..<center + 4], pixel) {
                XCTAssertEqual(Int(actual), Int(expected), accuracy: 1)
            }
            let attachment = XCTAttachment(data: try pngData(image), uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "custom-group-icon-\(size)-\(prominence)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testMissingOrInvalidCustomImageUsesTheStoredStandardIcon() throws {
        XCTAssertNotEqual(
            try rgbaPixels(render(GroupIconView(iconID: 0))),
            try rgbaPixels(render(GroupIconView(iconID: 48)))
        )
        for iconID in [0, 19, 37, 48, 43] {
            let expected = try rgbaPixels(render(StandardIconView(
                iconID: iconID, fallbackSystemName: "folder.fill", fallbackPalette: .blue
            )))
            for data in [nil, Data([0, 1, 2])] as [Data?] {
                let actual = try rgbaPixels(render(GroupIconView(iconID: iconID, customIconData: data)))
                XCTAssertEqual(actual, expected, "standard icon \(iconID)")
            }
        }
    }

    func testUnknownStandardIconUsesTheFolderFallback() throws {
        let actual = try rgbaPixels(render(GroupIconView(iconID: -1)))
        let expected = try rgbaPixels(render(StandardIconView(iconID: 48)))
        XCTAssertEqual(actual, expected)
    }

    #if os(macOS)
    func testMacSidebarNodeCarriesCustomImageAlongsideItsStoredStandardIcon() {
        let uuid = UUID()
        let data = Data([1, 2, 3])
        let group = KPGroup(name: "Banking", iconID: 0, customIconUUID: uuid)
        let node = MacGroupNode(group: group, recycleBinUUID: nil, customIcons: [uuid: data])

        XCTAssertEqual(node.iconID, 0)
        XCTAssertEqual(node.customIconData, data)
        XCTAssertNil(MacGroupNode(group: group, recycleBinUUID: nil, customIcons: [:]).customIconData)
    }

    func testMacRecycleBinNodeKeepsTrashIconDespiteACustomImage() {
        let uuid = UUID()
        let group = KPGroup(name: "Recycle Bin", iconID: 0, customIconUUID: uuid)
        let node = MacGroupNode(group: group, recycleBinUUID: group.id, customIcons: [uuid: Data([1])])

        XCTAssertEqual(node.iconID, 43)
        XCTAssertNil(node.customIconData)
    }
    #endif

    private func render(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view
            .font(.system(size: 18))
            .frame(width: 28, height: 28)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
