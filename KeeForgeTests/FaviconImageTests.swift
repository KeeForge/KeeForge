import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import KeeForge

/// Decoding what `icons.duckduckgo.com` serves, and drawing small icons in large slots.
final class FaviconImageTests: XCTestCase {
    func testAMultiSizeIconDecodesToItsLargestFrame() throws {
        // Frames in the order sites write them: smallest first, so a first-frame decoder gets 16 px.
        let ico = try icoData(frameSizes: [16, 64, 32])
        let image = try XCTUnwrap(FaviconService.image(from: ico))
        XCTAssertEqual(image.pixelEdge, 64)
        let stored = try XCTUnwrap(FaviconIconEncoder.iconData(from: image))
        XCTAssertEqual(try pixelEdge(of: stored), 64, "The icon stored in the database keeps the largest frame")
    }

    func testASinglePNGDecodesAtItsSizeAndJunkDecodesToNothing() throws {
        let image = try XCTUnwrap(FaviconService.image(from: try pngData(side: 32)))
        XCTAssertEqual(image.pixelEdge, 32)
        XCTAssertNil(FaviconService.image(from: Data("not an image".utf8)))
    }

    func testSmallBitmapsSitOnATileInLargeSlotsOnly() {
        // A 32 px favicon in the Mac detail header (72 pt at 2x): half the slot, not a 4.5x stretch.
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 32, fullSide: 72, scale: 2), 36)
        XCTAssertTrue(IconBitmapLayout.isTiled(pixelEdge: 32, fullSide: 72, scale: 2))
        // Twice its pixel size when that is more than half the slot.
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 40, fullSide: 72, scale: 2), 40)
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 48, fullSide: 72, scale: 2), 72, "Exactly 3x still fills")
        // Never under half the slot, however small the bitmap.
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 16, fullSide: 72, scale: 2), 36)
        // A 64 px icon fills the header; so does a 32 px one in a 28 pt row or the 1x header.
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 64, fullSide: 72, scale: 2), 72)
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 32, fullSide: 28, scale: 2), 28)
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 32, fullSide: 72, scale: 1), 72)
        // The iPhone header's inset image area (64 pt less 15% each side) at 3x.
        XCTAssertEqual(IconBitmapLayout.side(pixelEdge: 32, fullSide: 44.8, scale: 3), 22.4, accuracy: 0.001)
        XCTAssertFalse(IconBitmapLayout.isTiled(pixelEdge: 128, fullSide: 44.8, scale: 3))
    }

    // MARK: - Helpers

    /// An `.ico` whose frames are PNGs, as modern favicons are.
    private func icoData(frameSizes: [Int]) throws -> Data {
        let frames = try frameSizes.map { try pngData(side: $0) }
        var data = Data()
        func append16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)]) }
        func append32(_ value: Int) { append16(value & 0xFFFF); append16(value >> 16) }
        append16(0)
        append16(1)
        append16(frames.count)
        var offset = 6 + 16 * frames.count
        for (side, frame) in zip(frameSizes, frames) {
            data.append(contentsOf: [UInt8(side % 256), UInt8(side % 256), 0, 0])
            append16(1)
            append16(32)
            append32(frame.count)
            append32(offset)
            offset += frame.count
        }
        for frame in frames { data.append(frame) }
        return data
    }

    private func pngData(side: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelEdge(of data: Data) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return max(image.width, image.height)
    }
}
