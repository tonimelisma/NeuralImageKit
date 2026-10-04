import Foundation
import Metal
import simd

/// A compact, controllable look. Input is extended linear BT.2020, output encoded
/// sRGB. Exposure/WB normalization, tone, creative colour and gamut are explicit.
struct AuthoredLook: Codable {
    enum ToneMode: String, Codable { case rgbRatio, perChannel }
    enum GamutPolicy: String, Codable { case smoothRadial, radialProjection }
    let formatVersion: Int
    let decoder: String
    let input: NativeRAWRecipe
    let exposureEV: Double
    let whiteBalanceRGB: [Double]
    let contrast: Double
    let tonePivot: Double
    let skew: Double
    let toneMode: ToneMode
    let huePreservation: Double
    let saturation: Double
    let colourCorrection: CreativeColour?
    let gamutPolicy: GamutPolicy

    init(json: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: json)
        try validate()
    }

    func validate() throws {
        guard formatVersion == 5, decoder == "9", input != .appleDefault,
              exposureEV.isFinite, (-3 ... 3).contains(exposureEV),
              whiteBalanceRGB.count == 3, whiteBalanceRGB.allSatisfy({ $0.isFinite && (0.5 ... 2).contains($0) }),
              contrast.isFinite, (0.5 ... 2.5).contains(contrast),
              tonePivot.isFinite, (0.01 ... 8).contains(tonePivot),
              skew.isFinite, (0.3 ... 3).contains(skew),
              huePreservation.isFinite, (0 ... 1).contains(huePreservation),
              saturation.isFinite, (0.5 ... 1.5).contains(saturation)
        else { throw ReferenceError.unsupportedModel }
        try colourCorrection?.validate()
    }

    /// Independent stage ablations use the same implementation and final gamut.
    struct Stages {
        var normalization = true
        var tone = true
        var creative = true
        var colourResidual = true
    }

    func displayLinear(_ rgb: SIMD3<Double>, stages: Stages = Stages()) -> SIMD3<Double> {
        let gain = stages.normalization ? pow(2, exposureEV) : 1
        let wb = stages.normalization ? SIMD3(whiteBalanceRGB[0], whiteBalanceRGB[1], whiteBalanceRGB[2]) : SIMD3(repeating: 1)
        let wide = rgb * wb * gain
        var x = SIMD3(
            1.660491002108434 * wide.x - 0.58764113878855 * wide.y - 0.072849863319884 * wide.z,
            -0.12455047452159 * wide.x + 1.13289989712596 * wide.y - 0.008349422604371 * wide.z,
            -0.018150763354905 * wide.x - 0.100578898008008 * wide.y + 1.118729661362913 * wide.z
        )
        let luma = SIMD3(0.2126, 0.7152, 0.0722)
        let y = max(0, simd_dot(x, luma))
        if stages.tone {
            func sigmoid(_ v: Double) -> Double {
                v <= 0 ? 0 : pow(1 / (1 + pow(tonePivot / v, contrast)), skew)
            }
            if toneMode == .rgbRatio {
                x = y > 1e-12 ? x * (sigmoid(y) / y) : .zero
            } else {
                let channel = SIMD3(sigmoid(x.x), sigmoid(x.y), sigmoid(x.z))
                // Preserve RGB hue by interpolating within the mapped endpoint
                // interval. Dividing by luminance is unstable for mixed-sign RGB:
                // cancellation can amplify a dark pixel into arbitrarily bright colour.
                let low = min(x.x, min(x.y, x.z)), high = max(x.x, max(x.y, x.z))
                let span = high - low
                let preserved = span > 0 ? SIMD3(repeating: sigmoid(low)) +
                    (x - SIMD3(repeating: low)) / span * (sigmoid(high) - sigmoid(low)) : channel
                x = channel * (1 - huePreservation) + preserved * huePreservation
            }
        }
        let grey = min(1, max(0, simd_dot(x, luma)))
        if stages.creative {
            x = SIMD3(repeating: grey) + (x - SIMD3(repeating: grey)) * saturation
        }
        return x
    }

    func evaluate(_ rgb: SIMD3<Double>, stages: Stages = Stages()) -> SIMD3<Double> {
        var x = displayLinear(rgb, stages: stages)
        if stages.colourResidual, let colourCorrection {
            x += colourCorrection.residual(x)
        }
        return prepareDisplay(x)
    }

    func prepareDisplay(_ linear: SIMD3<Double>) -> SIMD3<Double> {
        var x = linear
        let grey = min(1, max(0, simd_dot(x, SIMD3(0.2126, 0.7152, 0.0722))))
        let chroma = x - SIMD3(repeating: grey)
        var boundary = 0.0
        for c in 0 ..< 3 {
            boundary = max(boundary, chroma[c] >= 0 ? chroma[c] / max(1e-12, 1 - grey) : -chroma[c] / max(1e-12, grey))
        }
        // Smooth radial compression. Neutrals stay fixed; colours approach the
        // sRGB cube boundary continuously, instead of independently clipping RGB.
        let scale = gamutPolicy == .radialProjection ? 1 / max(1, boundary) :
            (boundary > 1 ? (1 / boundary) / pow(1 + pow(1 / boundary, 8), 1.0 / 8) : 1 / pow(1 + pow(boundary, 8), 1.0 / 8))
        x = SIMD3(repeating: grey) + chroma * scale
        func encoded(_ value: Double) -> Double {
            let v = min(1, max(0, value))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return SIMD3(encoded(x.x), encoded(x.y), encoded(x.z))
    }
}

final class MetalAuthoredLook {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var parameters: [Float]
    private let colourBuffer: MTLBuffer

    init(_ look: AuthoredLook, stages: AuthoredLook.Stages = .init()) throws {
        try look.validate()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ReferenceError.unsupportedModel
        }
        self.device = device
        self.queue = queue
        parameters = [Float(stages.normalization ? pow(2, look.exposureEV) : 1)]
        parameters += stages.normalization ? look.whiteBalanceRGB.map(Float.init) : [1, 1, 1]
        parameters += [Float(look.contrast), Float(look.tonePivot), look.toneMode == .rgbRatio ? 0 : 1,
                       Float(look.huePreservation), Float(stages.creative ? look.saturation : 1), stages.tone ? 1 : 0, Float(look.skew)]
        let colourValues = (look.colourCorrection?.coefficients ?? [Double](repeating: 0, count: 375)).map(Float.init)
        guard let colourBuffer = device.makeBuffer(bytes: colourValues, length: colourValues.count * 4, options: .storageModeShared) else { throw ReferenceError.unsupportedModel }
        self.colourBuffer = colourBuffer
        parameters += [stages.colourResidual && look.colourCorrection != nil ? 1 : 0, look.gamutPolicy == .radialProjection ? 1 : 0]
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        float curve(float x,constant float *p) { return x<=0 ? 0 : pow(1/(1+pow(p[5]/x,p[4])),p[10]); }
        float encode(float x) { x=clamp(x,0.0f,1.0f);return x<=0.0031308f ? 12.92f*x : 1.055f*pow(x,1.0f/2.4f)-0.055f; }
        \(CreativeColour.metalSource)
        kernel void authored(device const float4 *src [[buffer(0)]],device float4 *dst [[buffer(1)]],constant float *p [[buffer(2)]],constant uint &count [[buffer(3)]],device const float *colour [[buffer(4)]],uint i [[thread_position_in_grid]]) {
            if(i>=count)return;
            float3 w=src[i].rgb*float3(p[1],p[2],p[3])*p[0];
            float3 x=float3(dot(w,float3(1.660491002108434f,-0.58764113878855f,-0.072849863319884f)),dot(w,float3(-0.12455047452159f,1.13289989712596f,-0.008349422604371f)),dot(w,float3(-0.018150763354905f,-0.100578898008008f,1.118729661362913f)));
            float3 l=float3(0.2126f,0.7152f,0.0722f);float y=max(0.0f,dot(x,l));
            if(p[9]>0) {
                if(p[6]==0) x=y>1e-12f ? x*(curve(y,p)/y) : float3(0);
                else {float3 c=float3(curve(x.r,p),curve(x.g,p),curve(x.b,p));float lo=min(x.r,min(x.g,x.b)),hi=max(x.r,max(x.g,x.b));float span=hi-lo;float3 h=span>0 ? curve(lo,p)+(x-lo)/span*(curve(hi,p)-curve(lo,p)) : c;x=mix(c,h,p[7]);}
            }
            float grey=clamp(dot(x,l),0.0f,1.0f);x=grey+(x-grey)*p[8];
            if(p[11]>0) x+=colourLookup(x,colour)-colourLookup(float3(clamp(dot(x,l),0.0f,1.0f)),colour);
            grey=clamp(dot(x,l),0.0f,1.0f);float3 c=x-grey;float b=0;
            for(uint k=0;k<3;k++) b=max(b,c[k]>=0 ? c[k]/max(1e-12f,1-grey) : -c[k]/max(1e-12f,grey));
            // Compute the smooth boundary factor without overflowing b^8.
            float scale=p[12]>0 ? 1/max(1.0f,b) : b>1 ? (1/b)/pow(1+pow(1/b,8.0f),1.0f/8.0f) : 1/pow(1+pow(b,8.0f),1.0f/8.0f);
            x=grey+c*scale;dst[i]=float4(encode(x.r),encode(x.g),encode(x.b),1);
        }
        """
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "authored") else { throw ReferenceError.unsupportedModel }
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func apply(_ pixels: [Float]) throws -> [Float] {
        guard pixels.count % 4 == 0, pixels.allSatisfy(\.isFinite), pixels.count / 4 <= Int(UInt32.max) else {
            throw ReferenceError.invalidPixels
        }
        guard !pixels.isEmpty else { return [] }
        guard let source = device.makeBuffer(bytes: pixels, length: pixels.count * 4, options: .storageModeShared),
              let output = device.makeBuffer(length: pixels.count * 4, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw ReferenceError.unsupportedModel }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(colourBuffer, offset: 0, index: 4)
        parameters.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
        var count = UInt32(pixels.count / 4)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        let result = Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: pixels.count))
        guard result.allSatisfy(\.isFinite) else { throw ReferenceError.invalidPixels }
        return result
    }
}
