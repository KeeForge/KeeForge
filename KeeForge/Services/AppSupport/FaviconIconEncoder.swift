import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Turns a downloaded favicon into bytes fit to live inside a KDBX file.
///
/// A favicon is fetched for display and thrown away; an icon stored in
/// `Meta/CustomIcons` is in the user's vault until they remove it, is copied on
/// every save, and syncs to every device. So it is re-encoded rather than stored
/// as received: the host decides what it serves, and neither its format nor its
/// dimensions should decide how large the database gets.
enum FaviconIconEncoder {
    /// Longest edge of a stored icon.
    ///
    /// 128 covers the largest size any KeeForge or KeePass surface draws an icon
    /// at, on a Retina display, with nothing left over. Icons are never scaled
    /// *up* to reach it — a 16px favicon stored at 16px stays crisp for what it
    /// is, and inflating it would only cost bytes.
    static let maximumEdge = 128

    /// Refuses anything this side of absurd. A 128px PNG lands far below it, so
    /// crossing it means the encode produced something unexpected, and an
    /// unexpected blob is not something to write into a vault.
    static let maximumByteCount = 64 * 1024

    /// PNG bytes for `image`, or nil when it cannot be encoded within the caps.
    ///
    /// PNG because it is the format KeePass clients write into `Meta/CustomIcons`
    /// and the one every reader is certain to decode, and because favicons are
    /// flat graphics with transparency, which is exactly what it is good at.
    static func iconData(from image: PlatformImage) -> Data? {
        guard let source = cgImage(from: image) else { return nil }
        guard let scaled = downscaled(source) else { return nil }
        guard let data = pngData(from: scaled), data.count <= maximumByteCount else { return nil }
        return data
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// Redraws the image at or below `maximumEdge`, preserving aspect ratio.
    ///
    /// Returns the original untouched when it already fits, so a favicon that
    /// arrives at a sane size is never put through a resampling pass that could
    /// only soften it.
    private static func downscaled(_ image: CGImage) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maximumEdge else { return image }

        let scale = Double(maximumEdge) / Double(longestEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        // A fixed 8-bit premultiplied-BGRA context rather than the source's own
        // format: favicons arrive as indexed, grayscale and 16-bit-per-channel
        // images too, and several of those are combinations CoreGraphics will
        // not open a context for.
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
