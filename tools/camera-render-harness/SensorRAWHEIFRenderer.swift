import CoreImage
import Darwin
import Foundation
import ImageIO

/// Standalone sensor-RAW development. Apple's version-9 decoder supplies the
/// sensor development and native lens correction. Our saved look follows
/// development; camera-rendered images are not inputs to this renderer.
enum SensorRenderingLook {
    case nativeDefault
    case saved(LookModel)
    case conditional(ConditionalProfile)
    case authored(AuthoredLook, stages: AuthoredLook.Stages = .init())

    var recipe: NativeRAWRecipe {
        switch self {
        case .nativeDefault: .appleDefault
        case .saved, .conditional: .mapped
        case let .authored(look, _): look.input
        }
    }

    var name: String {
        switch self {
        case .nativeDefault: "apple-raw9-default-baseline"
        case .saved: "saved-raw9-model-baseline"
        case .conditional: "raw-wb-iso-field-prototype"
        case .authored: "authored-raw9-v5"
        }
    }
}

nonisolated enum CameraSensorRAWHEIFRenderer {
    enum Failure: Error {
        case unavailableOriginal
        case unsupportedOriginal
        case unsupportedDecoder
        case invalidDestination
        case destinationExists
        case decodeFailed
        case invalidSourceSupport
        case modelApplyFailed(String)
        case encodeFailed(String)
    }

    struct Result: Encodable {
        let contractVersion: Int
        let decoderVersion: String
        let width: Int
        let height: Int
        let lensModel: String?
        let focalLengthMM: Double?
        let nativeLensCorrectionSupported: Bool
        let nativeLensCorrectionEnabled: Bool
        let outputBitsPerComponent: Int
        let look: String
        let nativeRecipe: String
        let nativeTemperature: Float
        let nativeTint: Float
        let nativeBaselineExposure: Float
        let nativeShadowBias: Float
        let nativeGamutMappingEnabled: Bool
    }

    static let contractVersion = 5
    private static let datalessFlag: UInt32 = 0x4000_0000
    private static let maximumRAWBytes: Int64 = 256 * 1024 * 1024

    static func render(rawURL: URL, destinationURL: URL, mediaRoots: [URL],
                       look: SensorRenderingLook = .nativeDefault) throws -> Result
    {
        let span = RenderingSignpost.rendering.beginInterval("SensorHEIF")
        defer { RenderingSignpost.rendering.endInterval("SensorHEIF", span) }
        let started = Date()
        try Task.checkCancellation()
        if case let .authored(recipe, _) = look {
            try recipe.validate()
        }
        let input = rawURL.standardizedFileURL
        let output = destinationURL.standardizedFileURL
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath()
        let roots = mediaRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard !roots.isEmpty,
              roots.contains(where: { input.path.hasPrefix($0.path + "/") }),
              roots.allSatisfy({ parent.path != $0.path && !parent.path.hasPrefix($0.path + "/") }),
              input != output,
              input.deletingLastPathComponent() != output.deletingLastPathComponent(),
              output.pathExtension.lowercased() == "heic",
              FileManager.default.fileExists(atPath: parent.path)
        else { throw Failure.invalidDestination }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw Failure.destinationExists
        }

        var info = stat()
        guard lstat(input.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & datalessFlag == 0
        else { throw Failure.unavailableOriginal }
        guard input.pathExtension.lowercased() == "arw",
              info.st_size > 0, info.st_size <= maximumRAWBytes
        else { throw Failure.unsupportedOriginal }
        // The Camera type hint keeps camera metadata available from this one
        // guarded read. Subsequent Image I/O/Core Image work uses these bytes,
        // so metadata extraction cannot start another original-file read.
        let bytes = try Data(contentsOf: input)
        try Task.checkCancellation()
        let development = try NativeRAWDevelopment.develop(bytes, recipe: look.recipe)
        let outputProperties = exportProperties(from: development.properties)
        try Task.checkCancellation()
        var normalized = development.image
        let lookSpan = RenderingSignpost.rendering.beginInterval("ApplyLook")
        do {
            defer { RenderingSignpost.rendering.endInterval("ApplyLook", lookSpan) }
            switch look {
            case .nativeDefault: break
            case .saved, .conditional:
                let model: LookModel
                switch look {
                case let .saved(fixed): model = fixed
                case let .conditional(conditioned): model = try conditioned.model(development: development)
                default: throw Failure.decodeFailed
                }
                let encoded = try encodedImage(normalized)
                let pixels = frame(encoded, width: Int(encoded.extent.width), height: Int(encoded.extent.height))
                guard isFiniteOpaqueNativeFrame(pixels) else {
                    RenderingLog.rendering.noticeOperation("sensor.sourceSupport", phase: "rejected",
                                                      fields: ["reason": "nonfiniteOrNonopaque"])
                    throw Failure.invalidSourceSupport
                }
                try Task.checkCancellation()
                let transformed = try MetalLook(model: model).apply(pixels.rgba)
                try Task.checkCancellation()
                normalized = image(RGBFrame(width: pixels.width, height: pixels.height, rgba: transformed))
            case let .authored(recipe, stages):
                let pixels = try development.linearFrame()
                try Task.checkCancellation()
                let transformed = try MetalAuthoredLook(recipe, stages: stages).apply(pixels.rgba)
                try Task.checkCancellation()
                normalized = image(RGBFrame(width: pixels.width, height: pixels.height, rgba: transformed))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw Failure.modelApplyFailed(String(describing: error)) }
        RenderingLog.rendering.noticeOperation("sensor.development", phase: "complete", fields: [
            "look": look.name, "input": look.recipe.rawValue,
            "width": String(Int(normalized.extent.width)), "height": String(Int(normalized.extent.height)),
            "elapsedMs": String(Date().timeIntervalSince(started) * 1000),
        ])

        try Task.checkCancellation()
        normalized = normalized.settingProperties(outputProperties)
        let temporary = parent.appendingPathComponent(".camera-sensor-render-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Both look families emit encoded sRGB numbers. Their output is tagged
        // without another linear-to-encoded transfer. Native output is managed.
        let context = if case .nativeDefault = look {
            CIContext(options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                .cacheIntermediates: false,
            ])
        } else {
            CIContext(options: [
                .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                .cacheIntermediates: false,
            ])
        }
        let encodingStarted = Date()
        do {
            let span = RenderingSignpost.rendering.beginInterval("EncodeHEIF")
            defer { RenderingSignpost.rendering.endInterval("EncodeHEIF", span) }
            try context.writeHEIF10Representation(
                of: normalized, to: temporary,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [
                    CIImageRepresentationOption(
                        rawValue: kCGImageDestinationLossyCompressionQuality as String
                    ): 0.95,
                ]
            )
        } catch { throw Failure.encodeFailed(String(describing: error)) }
        RenderingLog.rendering.noticeOperation("sensor.encoding", phase: "complete", fields: [
            "look": look.name, "elapsedMs": String(Date().timeIntervalSince(encodingStarted) * 1000),
        ])
        // Synchronous framework work finishes before cancellation is observed.
        // A cancelled task may consume that work, but never publishes its result.
        try Task.checkCancellation()
        // Publish only the complete HEIF, without replacing an existing file.
        do {
            try FileManager.default.linkItem(at: temporary, to: output)
        } catch {
            if FileManager.default.fileExists(atPath: output.path) {
                throw Failure.destinationExists
            }
            throw Failure.encodeFailed(String(describing: error))
        }
        RenderingLog.rendering.noticeOperation("sensor.heif", phase: "published", fields: ["look": look.name, "elapsedMs": String(Date().timeIntervalSince(started) * 1000)])
        return Result(
            contractVersion: contractVersion, decoderVersion: "9",
            width: Int(normalized.extent.width), height: Int(normalized.extent.height),
            lensModel: development.lensModel, focalLengthMM: development.focalLengthMM,
            nativeLensCorrectionSupported: development.lensCorrectionSupported,
            nativeLensCorrectionEnabled: development.lensCorrectionEnabled,
            outputBitsPerComponent: 10,
            look: look.name, nativeRecipe: look.recipe.rawValue,
            nativeTemperature: development.temperature, nativeTint: development.tint,
            nativeBaselineExposure: development.baselineExposure, nativeShadowBias: development.shadowBias,
            nativeGamutMappingEnabled: development.gamutMappingEnabled
        )
    }

    /// Preserve capture facts from Image I/O, excluding RAW container geometry,
    /// camera software and proprietary processing tags that would misdescribe
    /// the newly developed HEIF. Pixel orientation is already normalized.
    private static func exportProperties(from source: [String: Any]) -> [String: Any] {
        var result = [String: Any]()
        if let tiff = source[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            let fields = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                          kCGImagePropertyTIFFDateTime]
            let kept = Dictionary(uniqueKeysWithValues: fields.compactMap { key -> (String, Any)? in
                let name = key as String
                return tiff[name].map { (name, $0) }
            })
            if !kept.isEmpty {
                result[kCGImagePropertyTIFFDictionary as String] = kept
            }
        }
        if let exif = source[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            let fields = [
                kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                kCGImagePropertyExifExposureTime, kCGImagePropertyExifFNumber,
                kCGImagePropertyExifISOSpeedRatings, kCGImagePropertyExifFocalLength,
                kCGImagePropertyExifLensModel, kCGImagePropertyExifExposureBiasValue,
                kCGImagePropertyExifExposureProgram, kCGImagePropertyExifMeteringMode,
                kCGImagePropertyExifWhiteBalance,
            ]
            let kept = Dictionary(uniqueKeysWithValues: fields.compactMap { key -> (String, Any)? in
                let name = key as String
                return exif[name].map { (name, $0) }
            })
            if !kept.isEmpty {
                result[kCGImagePropertyExifDictionary as String] = kept
            }
        }
        if let gps = source[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            result[kCGImagePropertyGPSDictionary as String] = gps
        }
        return result
    }
}
