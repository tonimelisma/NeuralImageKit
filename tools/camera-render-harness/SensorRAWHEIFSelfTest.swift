import Darwin
import Foundation

private enum SensorSelfTestError: Error { case failed(String) }

func sensorRAWHEIFSelfTest() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "camera-sensor-self-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    let media = root.appending(path: "media", directoryHint: .isDirectory)
    let exports = root.appending(path: "exports", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let raw = media.appending(path: "invalid.arw")
    let bytes = Data([0x49, 0x49, 0x2A, 0, 8, 0, 0, 0])
    try bytes.write(to: raw)
    func fails(_ expected: CameraSensorRAWHEIFRenderer.Failure,
               at output: URL, roots: [URL]) -> Bool
    {
        do {
            _ = try CameraSensorRAWHEIFRenderer.render(
                rawURL: raw, destinationURL: output, mediaRoots: roots
            )
            return false
        } catch let error as CameraSensorRAWHEIFRenderer.Failure {
            switch (expected, error) {
            case (.invalidDestination, .invalidDestination),
                 (.destinationExists, .destinationExists),
                 (.unsupportedOriginal, .unsupportedOriginal): return true
            default: return false
            }
        } catch { return false }
    }
    let outside = exports.appending(path: "candidate.heic")
    let inside = media.appending(path: "candidate.heic")
    guard fails(.invalidDestination, at: inside, roots: [media]),
          fails(.invalidDestination, at: outside, roots: [exports]),
          fails(.unsupportedOriginal, at: outside, roots: [media]),
          try Data(contentsOf: raw) == bytes
    else { throw SensorSelfTestError.failed("destination or original safety") }
    try Data([1, 2, 3]).write(to: outside)
    guard fails(.destinationExists, at: outside, roots: [media]),
          try Data(contentsOf: outside) == Data([1, 2, 3])
    else { throw SensorSelfTestError.failed("no overwrite") }
    // A real cancelled Swift task must reject before attempting the malformed
    // original. The semaphore owns this short CLI fixture's task lifetime.
    let finished = DispatchSemaphore(value: 0)
    let cancelledRender = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            _ = try CameraSensorRAWHEIFRenderer.render(
                rawURL: raw, destinationURL: exports.appending(path: "cancelled.heic"),
                mediaRoots: [media]
            )
            print("Cancelled sensor render unexpectedly succeeded")
            exit(1)
        } catch is CancellationError {
            finished.signal()
        } catch {
            print("Cancelled sensor render returned a non-cancellation error")
            exit(1)
        }
    }
    defer { cancelledRender.cancel() }
    guard finished.wait(timeout: .now() + 10) == .success,
          !FileManager.default.fileExists(atPath: exports.appending(path: "cancelled.heic").path),
          try Data(contentsOf: raw) == bytes
    else { throw SensorSelfTestError.failed("cancelled task published output or changed original") }
    print("Sensor HEIF destination, original safety and cancellation fixtures: pass")
}
