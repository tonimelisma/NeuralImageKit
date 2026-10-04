// The standalone RAW 9 Camera VV2 look. RGB is encoded extended sRGB, never
// linear light. GPU waits belong off the UI thread.
import Foundation
import Metal

enum ReferenceError: Error { case unsupportedModel, invalidPixels }

struct LookModel: Decodable {
    let formatVersion: Int
    let curveKnots: [Double]
    let curvesRGB: [[Double]]
    let residualLUT: [[[[Double]]]]
    let domain: [Double]
    let dimension: Int
    let decoder: String
    let neutralSettings: [String: Double]

    init(json: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: json)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, curveKnots, curvesRGB, residualLUT, domain, dimension, decoder, neutralSettings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        curveKnots = try values.decode([Double].self, forKey: .curveKnots)
        curvesRGB = try values.decode([[Double]].self, forKey: .curvesRGB)
        residualLUT = try values.decode([[[[Double]]]].self, forKey: .residualLUT)
        domain = try values.decode([Double].self, forKey: .domain)
        dimension = try values.decode(Int.self, forKey: .dimension)
        self.decoder = try values.decode(String.self, forKey: .decoder)
        neutralSettings = try values.decode([String: Double].self, forKey: .neutralSettings)
        let controls = ["boostAmount", "localToneMapAmount", "contrastAmount", "sharpnessAmount"]
        guard formatVersion == 2, self.decoder == "9", dimension == 9, domain == [0, 1.25],
              curveKnots.count == 49, curvesRGB.count == 3,
              curvesRGB.allSatisfy({ $0.count == 49 && $0.allSatisfy(\.isFinite) }),
              residualLUT.count == 9,
              residualLUT.allSatisfy({ plane in plane.count == 9 && plane.allSatisfy { row in
                  row.count == 9 && row.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isFinite) }
              }}), controls.allSatisfy({ neutralSettings[$0] == 0 })
        else {
            throw ReferenceError.unsupportedModel
        }
        for index in 0 ..< 49 {
            guard curveKnots[index].isFinite,
                  abs(curveKnots[index] - Double(index) * 1.25 / 48) < 1e-12
            else {
                throw ReferenceError.unsupportedModel
            }
        }
    }

    func evaluateRGB(_ input: [Double], clampOutput: Bool = true) throws -> [Double] {
        guard input.count == 3, input.allSatisfy(\.isFinite) else {
            throw ReferenceError.invalidPixels
        }
        return value(input, clampOutput: clampOutput)
    }

    private func value(_ input: [Double], clampOutput: Bool = true) -> [Double] {
        let x = input.map { min(domain[1], max(domain[0], $0)) }
        var result = [Double](repeating: 0, count: 3)
        for c in 0 ..< 3 {
            let q = (x[c] - domain[0]) / (domain[1] - domain[0]) * Double(curveKnots.count - 1)
            let i = min(curveKnots.count - 2, Int(q))
            let f = q - Double(i)
            result[c] = curvesRGB[c][i] * (1 - f) + curvesRGB[c][i + 1] * f
        }
        let q = x.map { ($0 - domain[0]) / (domain[1] - domain[0]) * Double(dimension - 1) }
        let lo = q.map { min(dimension - 2, Int($0)) }
        let f = zip(q, lo).map { $0 - Double($1) }
        for r in 0 ... 1 {
            for g in 0 ... 1 {
                for b in 0 ... 1 {
                    let weight = (r == 0 ? 1 - f[0] : f[0]) * (g == 0 ? 1 - f[1] : f[1]) * (b == 0 ? 1 - f[2] : f[2])
                    let node = residualLUT[lo[0] + r][lo[1] + g][lo[2] + b]
                    for c in 0 ..< 3 {
                        result[c] += weight * node[c]
                    }
                }
            }
        }
        return clampOutput ? result.map { min(1, max(0, $0)) } : result
    }
}

final class MetalLook {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let curves: MTLBuffer
    private let residual: MTLBuffer
    private let domain: Float
    init(model: LookModel) throws {
        guard model.formatVersion == 2, model.dimension == 9, model.curveKnots.count == 49,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw NSError(domain: "unsupportedModelOrMetal", code: 1) }
        self.device = device
        self.queue = queue
        domain = Float(model.domain[1])
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void applyLook(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], device const float *curves [[buffer(2)]], device const float4 *lut [[buffer(3)]], constant uint &count [[buffer(4)]], constant float &domain [[buffer(5)]], uint i [[thread_position_in_grid]]) {
            if (i >= count) return;
            float3 x=clamp(src[i].rgb,0.0f,domain);
            float3 q=x*(48.0f/domain); int3 lo=min(int3(q),int3(47));float3 f=q-float3(lo);
            float3 out;
            for (uint c=0;c<3;c++) out[c]=mix(curves[c*49+lo[c]],curves[c*49+lo[c]+1],f[c]);
            q=x*(8.0f/domain);lo=min(int3(q),int3(7));f=q-float3(lo);
            for(int r=0;r<2;r++) for(int g=0;g<2;g++) for(int b=0;b<2;b++) {
                float weight=(r?f.x:1-f.x)*(g?f.y:1-f.y)*(b?f.z:1-f.z);
                uint index=(lo.x+r)*81+(lo.y+g)*9+lo.z+b;
                out += weight * lut[index].rgb;
            }
            dst[i]=float4(clamp(out,0.0f,1.0f),src[i].a);
        }
        """
        let options = MTLCompileOptions()
        options.mathMode = .safe
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "applyLook") else {
            throw NSError(domain: "lookMetalFunctionUnavailable", code: 1)
        }
        pipeline = try device.makeComputePipelineState(function: function)
        let c = model.curvesRGB.flatMap(\.self).map(Float.init)
        var l = [Float]()
        for r in 0 ..< 9 {
            for g in 0 ..< 9 {
                for b in 0 ..< 9 {
                    l.append(contentsOf: model.residualLUT[r][g][b].map(Float.init))
                    l.append(0)
                }
            }
        }
        guard let curvesBuffer = device.makeBuffer(bytes: c, length: c.count * 4,
                                                   options: .storageModeShared),
            let residualBuffer = device.makeBuffer(bytes: l, length: l.count * 4,
                                                   options: .storageModeShared)
        else { throw NSError(domain: "lookMetalAllocationFailed", code: 1) }
        curves = curvesBuffer
        residual = residualBuffer
    }

    func apply(_ pixels: [Float]) throws -> [Float] {
        guard pixels.count % 4 == 0, pixels.allSatisfy(\.isFinite) else { throw NSError(domain: "invalidPixels", code: 1) }
        if pixels.isEmpty {
            return []
        }
        guard let source = device.makeBuffer(bytes: pixels, length: pixels.count * 4,
                                             options: .storageModeShared),
            let output = device.makeBuffer(length: pixels.count * 4,
                                           options: .storageModeShared),
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeComputeCommandEncoder()
        else { throw NSError(domain: "lookMetalAllocationFailed", code: 2) }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(curves, offset: 0, index: 2)
        encoder.setBuffer(residual, offset: 0, index: 3)
        var count = UInt32(pixels.count / 4)
        var d = domain
        encoder.setBytes(&count, length: 4, index: 4)
        encoder.setBytes(&d, length: 4, index: 5)
        encoder.dispatchThreads(MTLSize(width: Int(count), height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
            throw error
        }
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: Float.self), count: pixels.count))
    }
}
