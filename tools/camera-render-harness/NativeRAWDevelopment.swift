import CoreImage
import Foundation
import ImageIO

/// The native decode contract shared by rendering and photographic calibration.
/// Lens geometry belongs to Apple's RAW stage, independently of our authored look.
enum NativeRAWRecipe: String, Codable {
    case appleDefault, mapped, unmapped
}

struct NativeRAWDevelopment {
    let image: CIImage
    let properties: [String: Any]
    let lensModel: String?
    let focalLengthMM: Double?
    let temperature: Float
    let tint: Float
    let baselineExposure: Float
    let shadowBias: Float
    let gamutMappingEnabled: Bool
    let lensCorrectionSupported: Bool
    let lensCorrectionEnabled: Bool

    static func develop(_ bytes: Data, recipe: NativeRAWRecipe) throws -> Self {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
              tiff[kCGImagePropertyTIFFModel as String] as? String == "ILCE-6700"
        else { throw CameraSensorRAWHEIFRenderer.Failure.unsupportedOriginal }
        guard let raw = CIRAWFilter(imageData: bytes, identifierHint: nil) else {
            throw CameraSensorRAWHEIFRenderer.Failure.decodeFailed
        }
        let decoder = CIRAWDecoderVersion(rawValue: "9")
        guard raw.supportedDecoderVersions.contains(decoder) else {
            throw CameraSensorRAWHEIFRenderer.Failure.unsupportedDecoder
        }
        raw.decoderVersion = decoder
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        if recipe != .appleDefault {
            raw.boostAmount = 0
            raw.localToneMapAmount = 0
            raw.contrastAmount = 0
            raw.sharpnessAmount = 0
            raw.isGamutMappingEnabled = recipe == .mapped
        }
        // An unsupported native lens profile does not make the sensor RAW
        // unsupported. Preserve the independent correction fact explicitly.
        raw.isLensCorrectionEnabled = raw.isLensCorrectionSupported
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let reportedLens = exif[kCGImagePropertyExifLensModel as String] as? String
        let lens = reportedLens.flatMap { $0.isEmpty ? nil : $0 }
        guard let output = raw.outputImage, output.colorSpace != nil,
              output.extent.width.isFinite, output.extent.height.isFinite, !output.extent.isEmpty
        else { throw CameraSensorRAWHEIFRenderer.Failure.decodeFailed }
        return Self(image: zeroOrigin(output), properties: properties, lensModel: lens,
                    focalLengthMM: (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue,
                    temperature: raw.neutralTemperature, tint: raw.neutralTint,
                    baselineExposure: raw.baselineExposure, shadowBias: raw.shadowBias,
                    gamutMappingEnabled: raw.isGamutMappingEnabled,
                    lensCorrectionSupported: raw.isLensCorrectionSupported,
                    lensCorrectionEnabled: raw.isLensCorrectionEnabled)
    }

    /// Force full sensor development before any reduction. The tagged native output
    /// is converted once to extended linear BT.2020; the untagged early tap is unused.
    func linearFrame() throws -> RGBFrame {
        let span = RenderingSignpost.rendering.beginInterval("NativeLinearPixels")
        defer { RenderingSignpost.rendering.endInterval("NativeLinearPixels", span) }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        // RAW 9 must develop in linear sRGB here. A P3 working context changes
        // sensor colours before the explicit BT.2020 output conversion.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf,
                                          .cacheIntermediates: false])
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBAf, colorSpace: space) else {
            throw CameraSensorRAWHEIFRenderer.Failure.decodeFailed
        }
        let pixels = frame(CIImage(cgImage: cg, options: [.colorSpace: NSNull()]),
                           width: cg.width, height: cg.height)
        guard pixels.rgba.allSatisfy(\.isFinite),
              stride(from: 3, to: pixels.rgba.count, by: 4).allSatisfy({ abs(pixels.rgba[$0] - 1) < 1e-6 })
        else { throw CameraSensorRAWHEIFRenderer.Failure.decodeFailed }
        return pixels
    }
}

/// Saved looks operate on opaque sensor RGB. Reject genuine transparency before
/// the numeric colour transform; converting it to opaque would conceal a source
/// defect and premultiplied RGB would masquerade as a brightness change. The
/// tolerance admits native half-float rounding of an otherwise opaque source.
func isFiniteOpaqueNativeFrame(_ pixels: RGBFrame) -> Bool {
    pixels.rgba.allSatisfy(\.isFinite)
        && stride(from: 3, to: pixels.rgba.count, by: 4).allSatisfy {
            pixels.rgba[$0] > 0.999 && pixels.rgba[$0] <= 1.001
        }
}
