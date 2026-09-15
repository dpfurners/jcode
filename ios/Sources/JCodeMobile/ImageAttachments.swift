import Foundation
import JCodeKit
import UIKit

/// An image staged in the composer: the wire payload plus a thumbnail.
struct PendingImage: Identifiable, Equatable {
    let id = UUID()
    let attachment: ImageAttachment
    let thumbnail: UIImage

    static func == (lhs: PendingImage, rhs: PendingImage) -> Bool { lhs.id == rhs.id }
}

enum ImageEncoder {
    /// Longest edge the server needs; larger images only cost tokens.
    static let maxLongEdge: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.8

    /// Downscales to at most 1568 px on the long edge, JPEG q0.8, base64.
    static func encode(_ image: UIImage) -> PendingImage? {
        let scaled = downscale(image)
        guard let data = scaled.jpegData(compressionQuality: jpegQuality) else { return nil }
        let thumbSide: CGFloat = 160
        let thumb = downscale(scaled, to: thumbSide)
        return PendingImage(
            attachment: ImageAttachment(mimeType: "image/jpeg", base64: data.base64EncodedString()),
            thumbnail: thumb)
    }

    static func downscale(_ image: UIImage, to longEdge: CGFloat = maxLongEdge) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longEdge, longest > 0 else { return image.normalizedOrientation() }
        let scale = longEdge / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

extension UIImage {
    /// Camera captures carry EXIF orientation; bake it in so the server sees
    /// the pixels the user saw.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
