import CoreGraphics
import ImageIO
import XCTest
@testable import KeeForge

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The re-encode that stands between a downloaded favicon and the bytes written
/// into `Meta/CustomIcons`. Every contract here is what keeps a host's choice of
/// format and dimensions from deciding how large the vault gets.
final class FaviconIconEncoderTests: XCTestCase {

    // MARK: - Size

    func test_iconData_downscalesASourcePastTheMaximumEdge() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 129, height: 129))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 128))
    }

    func test_iconData_leavesASourceAtTheMaximumEdgeAtItsSize() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 128, height: 128))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 128))
    }

    func test_iconData_neverUpscalesASmallIcon() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 16, height: 16))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 16, height: 16))
    }

    func test_iconData_preservesTheAspectRatioOfAWideSource() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 512, height: 256))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 64))
    }

    func test_iconData_preservesTheAspectRatioOfATallSource() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 200, height: 400))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 64, height: 128))
    }

    func test_iconData_roundsAnEdgeThatDoesNotScaleToAWholePixel() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 300, height: 100))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 43))
    }

    // MARK: - Format

    func test_iconData_writesPNG() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(rgbaImage(width: 64, height: 64))))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    // MARK: - Byte Cap

    /// A 16-bit-per-channel source at the maximum edge is the one shape that
    /// reaches the cap: it needs no downscale, so nothing on the way to the
    /// encoder reduces it, and incompressible content puts the PNG past 100 KB.
    func test_iconData_refusesAnEncodePastTheByteCap() {
        let image = noiseImage(width: 128, height: 128, bitsPerComponent: 16)
        XCTAssertNil(FaviconIconEncoder.iconData(from: platformImage(image)))
    }

    func test_iconData_staysWithinTheByteCapWhenItReturnsBytes() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(noiseImage(width: 128, height: 128, bitsPerComponent: 8))))
        XCTAssertLessThanOrEqual(data.count, FaviconIconEncoder.maximumByteCount)
    }

    // MARK: - Exotic Sources

    // The fixed BGRA drawing context exists for these three: each is a source
    // format CoreGraphics will not open a matching context for.

    func test_iconData_redrawsAGrayscaleSource() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(grayscaleImage(width: 256, height: 256))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 128))
    }

    func test_iconData_redrawsAnIndexedSource() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(indexedImage(width: 256, height: 256))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 128))
    }

    func test_iconData_redrawsADeepColorSource() throws {
        let data = try XCTUnwrap(FaviconIconEncoder.iconData(from: platformImage(noiseImage(width: 256, height: 256, bitsPerComponent: 16))))
        XCTAssertEqual(try pixelSize(of: data), CGSize(width: 128, height: 128))
    }

    // MARK: - Helpers

    private func rgbaImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func grayscaleImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func indexedImage(width: Int, height: Int) -> CGImage {
        let colorTable: [UInt8] = [0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]
        let space = CGColorSpace(
            indexedBaseSpace: CGColorSpaceCreateDeviceRGB(),
            last: 3,
            colorTable: colorTable
        )!
        let provider = CGDataProvider(data: Data(repeating: 1, count: width * height) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    private func noiseImage(width: Int, height: Int, bitsPerComponent: Int) -> CGImage {
        let alphaInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitsPerComponent == 16
                ? alphaInfo | CGBitmapInfo.byteOrder16Little.rawValue
                : alphaInfo
        )!
        let byteCount = context.bytesPerRow * height
        let buffer = context.data!.bindMemory(to: UInt8.self, capacity: byteCount)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<byteCount {
            buffer[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return context.makeImage()!
    }

    private func platformImage(_ image: CGImage) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: image)
        #else
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #endif
    }

    private func pixelSize(of data: Data) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return CGSize(width: image.width, height: image.height)
    }
}
