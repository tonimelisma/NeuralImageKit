import Darwin
import Foundation

/// Deliberate research provisioning, separate from the evaluation byte-read path.
/// `request` issues File Provider downloads without faulting on media bytes;
/// `status` observes only inode flags. Neither command opens originals for writing.
private struct Item: Decodable {
    let id: String
    let raw: String
    let target: String?
}

private struct Manifest: Decodable { let pairs: [Item] }

private struct Report: Encodable {
    let files: Int
    let localFiles: Int
    let datalessFiles: Int
    let unknownFiles: Int
    let localLogicalBytes: Int64
    let requestedFiles: Int
    let requestErrors: Int
}

private enum ErrorKind: Error { case usage, unavailableManifest, invalidOutput }

@main
private struct Materialize {
    static func main() {
        do { try run() }
        catch {
            fputs("Camera materialization: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let args = CommandLine.arguments
        guard args.count == 4, args[1] == "request" || args[1] == "status" else {
            throw ErrorKind.usage
        }
        let manifestURL = URL(fileURLWithPath: args[2])
        var manifestInfo = stat()
        guard lstat(manifestURL.path(percentEncoded: false), &manifestInfo) == 0,
              manifestInfo.st_mode & S_IFMT == S_IFREG, manifestInfo.st_flags & 0x4000_0000 == 0
        else { throw ErrorKind.unavailableManifest }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let reportURL = URL(fileURLWithPath: args[3]).standardizedFileURL.resolvingSymlinksInPath()
        let originalPaths = manifest.pairs.flatMap { [$0.raw] + ($0.target.map { [$0] } ?? []) }
        guard !originalPaths.isEmpty, args[3].hasPrefix("/"),
              !FileManager.default.fileExists(atPath: reportURL.path),
              originalPaths.allSatisfy({ path in
                  let root = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
                  return reportURL.path != root && !reportURL.path.hasPrefix(root + "/")
              }) else { throw ErrorKind.invalidOutput }
        var files = 0, local = 0, dataless = 0, unknown = 0, requested = 0, errors = 0
        var localBytes: Int64 = 0
        for pair in manifest.pairs {
            let paths = [("raw", pair.raw)] + (pair.target.map { [("target", $0)] } ?? [])
            for (kind, path) in paths {
                files += 1
                let url = URL(fileURLWithPath: path)
                var info = stat()
                guard lstat(url.path(percentEncoded: false), &info) == 0,
                      info.st_mode & S_IFMT == S_IFREG
                else {
                    unknown += 1
                    continue
                }
                if info.st_flags & 0x4000_0000 == 0 {
                    local += 1
                    localBytes += info.st_size
                    continue
                }
                dataless += 1
                if args[1] == "request" {
                    do {
                        try FileManager.default.startDownloadingUbiquitousItem(at: url)
                        requested += 1
                    } catch {
                        errors += 1
                        fputs("request failed \(pair.id) \(kind): \((error as NSError).code)\n", stderr)
                    }
                    // Avoid a rapid burst of requests into one provider domain.
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
        }
        let report = Report(files: files, localFiles: local,
                            datalessFiles: dataless, unknownFiles: unknown,
                            localLogicalBytes: localBytes, requestedFiles: requested,
                            requestErrors: errors)
        let encoded = try JSONEncoder().encode(report)
        try encoded.write(to: reportURL, options: .withoutOverwriting)
        print(String(data: encoded, encoding: .utf8)!)
    }
}
