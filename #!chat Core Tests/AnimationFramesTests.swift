import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import __chat

struct AnimationFramesTests {
    /// A 40 × 30 GIF in a temporary file, a frame for each delay, with a square that moves
    /// along. Its background is blue, or nothing at all.
    private func gif(delays: [Double], seeThrough: Bool = false) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if !seeThrough {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            }
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: index * 8, y: 5, width: 8, height: 8))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return file
    }

    @Test func `Every frame comes out, at the animation's own size when that's small enough`() async throws {
        let file = try gif(delays: [0.05, 0.2, 0.07])
        defer { try! FileManager.default.removeItem(at: file) }
        let frames = try #require(await AnimationFrames.load(from: file, maxPixelSize: 400))
        #expect(frames.surfaces.map(\.width) == [40, 40, 40])
        #expect(frames.surfaces.map(\.height) == [30, 30, 30])
        #expect(frames.durations == [0.05, 0.2, 0.07])
    }

    @Test func `Frames are drawn no bigger than they're asked for`() async throws {
        let file = try gif(delays: [0.1, 0.1])
        defer { try! FileManager.default.removeItem(at: file) }
        let frames = try #require(await AnimationFrames.load(from: file, maxPixelSize: 20))
        #expect(frames.surfaces.map(\.width) == [20, 20])
        #expect(frames.surfaces.map(\.height) == [15, 15])
    }

    @Test func `A frame that asks for next to no delay gets a tenth of a second`() async throws {
        let file = try gif(delays: [0, 0.01, 0.02])
        defer { try! FileManager.default.removeItem(at: file) }
        let frames = try #require(await AnimationFrames.load(from: file, maxPixelSize: 400))
        #expect(frames.durations == [0.1, 0.1, 0.02])
    }

    @Test func `The frames play in turn, each for its share of the whole, and start over`() async throws {
        let file = try gif(delays: [0.1, 0.3, 0.1])
        defer { try! FileManager.default.removeItem(at: file) }
        let animation = try #require(await AnimationFrames.load(from: file, maxPixelSize: 400)).animation
        #expect(animation.values?.count == 3)
        #expect(animation.keyTimes?.map(\.doubleValue) == [0, 0.2, 0.8, 1])
        #expect(animation.duration == 0.5)
        #expect(animation.calculationMode == .discrete)
        #expect(animation.repeatCount == .infinity)
    }

    @Test func `A see-through GIF has no frames to play`() async throws {
        let file = try gif(delays: [0.1, 0.1], seeThrough: true)
        defer { try! FileManager.default.removeItem(at: file) }
        #expect(await AnimationFrames.load(from: file, maxPixelSize: 400) == nil)
    }

    @Test func `A still image has no frames to play`() async throws {
        let file = try gif(delays: [0.1])
        defer { try! FileManager.default.removeItem(at: file) }
        #expect(await AnimationFrames.load(from: file, maxPixelSize: 400) == nil)
    }

    @Test func `A cancelled task gets no frames`() async throws {
        let file = try gif(delays: [0.1, 0.1])
        defer { try! FileManager.default.removeItem(at: file) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }     // before the first frame, for certain
            return await AnimationFrames.load(from: file, maxPixelSize: 400)
        }
        #expect(await task.value == nil)
    }

    @Test func `Frames are as big as asked, unless the animation is smaller`() {
        #expect(AnimationFrames.pixelSize(width: 800, height: 600, frames: 10, atMost: 400) == 400)
        #expect(AnimationFrames.pixelSize(width: 306, height: 408, frames: 72, atMost: 600) == 408)
    }

    @Test func `A long animation's frames are drawn smaller, to fit the memory budget`() {
        // 400 × 300 frames are 480,000 bytes each, so 104 fit in the budget.
        #expect(AnimationFrames.pixelSize(width: 800, height: 600, frames: 104, atMost: 400) == 400)
        // Four times as many frames fit at half the size, which is a quarter of the bytes.
        let longest = AnimationFrames.pixelSize(width: 800, height: 600, frames: 416, atMost: 400)
        #expect(longest == 200)
        #expect(longest * (longest * 3 / 4) * 4 * 416 <= AnimationFrames.memoryBudget)
    }
}
