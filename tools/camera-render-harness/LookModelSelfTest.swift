import Foundation

private struct LookVectors: Decodable {
    struct Vector: Decodable {
        let input: [Double]
        let expected: [Double]
    }

    let formatVersion: Int
    let vectors: [Vector]
}

func lookModelSelfTest(modelPath: String, vectorsPath: String) throws {
    let modelData = try Data(contentsOf: URL(fileURLWithPath: modelPath))
    let model = try LookModel(json: modelData)
    let fixture = try JSONDecoder().decode(
        LookVectors.self, from: Data(contentsOf: URL(fileURLWithPath: vectorsPath))
    )
    guard fixture.formatVersion == 2, fixture.vectors.count >= 500 else {
        fatalError("Invalid RAW 9 look vectors")
    }
    var input = [Float]()
    var cpuError = 0.0
    for vector in fixture.vectors {
        let actual = try model.evaluateRGB(vector.input)
        guard vector.expected.count == 3 else { fatalError("Invalid expected RGB") }
        for channel in 0 ..< 3 {
            cpuError = max(cpuError, abs(actual[channel] - vector.expected[channel]))
        }
        input.append(contentsOf: vector.input.map(Float.init))
        input.append(1)
    }
    let gpu = try MetalLook(model: model).apply(input)
    var gpuError = 0.0
    for (index, vector) in fixture.vectors.enumerated() {
        for channel in 0 ..< 3 {
            gpuError = max(gpuError, abs(Double(gpu[index * 4 + channel]) -
                    vector.expected[channel]))
        }
        guard gpu[index * 4 + 3] == 1 else { fatalError("Look changed alpha") }
    }
    guard cpuError <= 1e-12, gpuError <= 2e-6 else {
        fatalError("RAW 9 look CPU/GPU numerical mismatch")
    }
    for invalid in [[Double.nan, 0, 0], [Double.infinity, 0, 0], [0, 0]] {
        do {
            _ = try model.evaluateRGB(invalid)
            fatalError("Look accepted invalid RGB")
        } catch ReferenceError.invalidPixels {}
    }
    var object = try JSONSerialization.jsonObject(with: modelData) as! [String: Any]
    object["formatVersion"] = 999
    do {
        _ = try LookModel(json: JSONSerialization.data(withJSONObject: object))
        fatalError("Look accepted future format")
    } catch ReferenceError.unsupportedModel {}
    object["formatVersion"] = 2
    object["decoder"] = "8"
    do {
        _ = try LookModel(json: JSONSerialization.data(withJSONObject: object))
        fatalError("Look accepted wrong decoder")
    } catch ReferenceError.unsupportedModel {}
    object["decoder"] = "9"
    object["residualLUT"] = []
    do {
        _ = try LookModel(json: JSONSerialization.data(withJSONObject: object))
        fatalError("Look accepted malformed cube")
    } catch ReferenceError.unsupportedModel {}
    print("op=look.verify vectors=\(fixture.vectors.count) cpuMaxError=\(cpuError) " +
        "gpuMaxError=\(gpuError) invalidInputs=rejected futureFormat=rejected " +
        "wrongDecoder=rejected malformedCube=rejected")
}
