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

    /// The domain's favicon as bytes fit to store, or nil when there is none to
    /// store.
    ///
    /// `nonisolated` and `async` on purpose: the callers are main-actor view
    /// models, and both halves of this — the cache read's disk I/O and the
    /// decode of an image a host chose the dimensions of — are work the repo
    /// keeps off the main thread. Nothing but `Data` crosses back.
    ///
    /// Not `Task.detached`, which would sever cancellation: closing the icon
    /// picker has to stop the fetch in flight.
    ///
    /// A fetch does *not* add to the favicon disk cache. That cache is a
    /// plaintext per-domain fingerprint of the vault, and this image is about to
    /// live somewhere encrypted, so a second copy keyed by domain would widen
    /// the fingerprint for nothing.
    nonisolated static func downloadedIconData(for domain: String) async -> Data? {
        guard let image = await FaviconService.favicon(for: domain, cachingToDisk: false) else {
            return nil
        }
        return iconData(from: image)
    }

    /// PNG bytes for `image`, or nil when it cannot be encoded within the caps.
    ///
    /// PNG because it is the format KeePass clients write into `Meta/CustomIcons`
    /// and the one every reader is certain to decode, and because favicons are
    /// flat graphics with transparency, which is exactly what it is good at.
    static func iconData(from image: PlatformImage) -> Data? {
        guard let source = cgImage(from: image) else { return nil }
        guard let normalized = normalized(source) else { return nil }
        guard let data = pngData(from: normalized), data.count <= maximumByteCount else { return nil }
        return data
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return image.cgImage
        #else
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    /// Brings the image into 8-bit RGB at or below `maximumEdge`, preserving
    /// aspect ratio.
    ///
    /// Returns the original untouched only when it is *already* that — an
    /// ordinary 8-bit RGB image within the size limit — so a favicon that
    /// arrives sane is never put through a resampling pass that could only
    /// soften it. Size alone is not enough to skip on: a small 16-bit-per-
    /// channel or indexed source encodes to a PNG several times the size of the
    /// 8-bit redraw of the same picture, and a large enough one would cross
    /// `maximumByteCount` and be refused as unusable for a site that served a
    /// perfectly good icon.
    private static func normalized(_ image: CGImage) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        let scale = longestEdge > maximumEdge ? Double(maximumEdge) / Double(longestEdge) : 1
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        if width == image.width, height == image.height, isEightBitRGB(image) {
            return image
        }

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

    /// Bit depth and color model only. Channel order is not worth a redraw —
    /// PNG encodes RGBA and BGRA to the same bytes either way.
    private static func isEightBitRGB(_ image: CGImage) -> Bool {
        image.bitsPerComponent == 8 && image.colorSpace?.model == .rgb
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
