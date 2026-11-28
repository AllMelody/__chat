import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import ImageIO
import QuartzCore

/// An animated GIF's frames, every one drawn at the size it shows at, for a layer to play.
///
/// Drawn once, up front, because a GIF frame costs more to decode the bigger the GIF is, and
/// decoding one for every frame shown keeps a core busy for as long as a big GIF is in view.
/// Core Animation plays frames it's handed without the app doing anything more. The price is
/// memory, all the frames at once, which `memoryBudget` bounds.
nonisolated struct AnimationFrames {
    /// A surface a frame: a layer shows a surface as it is, where it would copy an image.
    let surfaces: [IOSurface]
    /// How long each frame shows, in seconds.
    let durations: [Double]

    /// What the frames of one animation may take. A longer one's frames are drawn smaller, and
    /// show softer. Enough for about 100 frames at the Mac log's size on a 2x screen.
    static let memoryBudget = 48 * 1024 * 1024

    /// The frames of the GIF in `file`, no bigger than `maxPixelSize` either way. Nil if they
    /// can't be had, if the task is cancelled first, and for a GIF that's see-through anywhere:
    /// the still thumbnail a log plays this over would show through it.
    @concurrent
    static func load(from file: URL, maxPixelSize: Int) async -> AnimationFrames? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }

        // A thumbnail of each frame is the whole picture at that point: ImageIO puts together
        // the frames before it, which a GIF's frame only records the changes from.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize(width: width, height: height, frames: count, atMost: maxPixelSize)
        ]
        var surfaces: [IOSurface] = []
        var durations: [Double] = []
        for index in 0..<count {
            guard !Task.isCancelled,
                  let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary),
                  let surface = opaqueSurface(drawing: frame) else { return nil }
            surfaces.append(surface)
            // ImageIO's delay is the browsers': a GIF asking for 10 ms or less gets 100.
            let gif = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            durations.append(gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1)
        }
        return AnimationFrames(surfaces: surfaces, durations: durations)
    }

    /// The longest side to draw the frames of a `width` × `height` animation at: `maxPixelSize`,
    /// or the animation's own size if that's smaller, or smaller still, to fit the budget.
    static func pixelSize(width: Int, height: Int, frames: Int, atMost maxPixelSize: Int) -> Int {
        let longest = min(max(width, height), maxPixelSize)
        let scale = Double(longest) / Double(max(width, height))
        let bytes = Double(width) * scale * Double(height) * scale * 4 * Double(frames)
        guard bytes > Double(memoryBudget) else { return longest }
        return max(1, Int(Double(longest) * (Double(memoryBudget) / bytes).squareRoot()))
    }

    /// `frame` drawn into a surface of its own size, or nil if any of it is see-through.
    private static func opaqueSurface(drawing frame: CGImage) -> IOSurface? {
        // What a GIF's colors are in. A surface that doesn't say is shown in the screen's own
        // colors, which on a wide-gamut screen are more saturated than the still thumbnail's.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let surface = IOSurface(properties: [.width: frame.width, .height: frame.height, .bytesPerElement: 4,
                                                   .pixelFormat: kCVPixelFormatType_32BGRA]) else { return nil }
        surface.setAttachment(colorSpace.copyICCData()! as Data, forKey: kIOSurfaceICCProfile as String)

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(data: surface.baseAddress, width: frame.width, height: frame.height, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setBlendMode(.copy)
        context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))

        // Blue, green, red, alpha: every fourth byte of a row's pixels says how opaque one is.
        for row in 0..<frame.height {
            let pixels = UnsafeRawBufferPointer(start: surface.baseAddress + row * surface.bytesPerRow, count: frame.width * 4)
            for alpha in stride(from: 3, to: pixels.count, by: 4) where pixels[alpha] != 0xFF { return nil }
        }
        return surface
    }

    /// Shows the frames as a layer's contents, each for its own time, over and over.
    var animation: CAKeyframeAnimation {
        let total = durations.reduce(0, +)
        var elapsed = 0.0
        let animation = CAKeyframeAnimation(keyPath: #keyPath(CALayer.contents))
        animation.values = surfaces
        // When each frame starts, and when the last one ends, as fractions of the whole.
        animation.keyTimes = [0] + durations.map { duration in
            elapsed += duration
            return NSNumber(value: elapsed / total)
        }
        animation.calculationMode = .discrete
        animation.duration = total
        animation.repeatCount = .infinity
        return animation
    }
}
