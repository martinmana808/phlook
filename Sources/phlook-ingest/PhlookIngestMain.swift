import Foundation
import PhlookCore

@main
struct PhlookIngestCLI {
    static func main() async {
        let args = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser
        let staging = args.count > 1
            ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            : home.appendingPathComponent("Pictures/PHLOOK_staging")
        let library = args.count > 2
            ? URL(fileURLWithPath: (args[2] as NSString).expandingTildeInPath)
            : home.appendingPathComponent("Pictures/PHLOOK")

        print("phlook-ingest: \(staging.path) → \(library.path)")
        do {
            let report = try await IngestService(staging: staging, library: library).ingest()
            print(report.summaryText)
            exit(report.isClean ? 0 : 1)
        } catch let IngestError.moveFailed(file, reason, partial) {
            print(partial.summaryText)
            FileHandle.standardError.write(
                Data("phlook-ingest: STOPPED — failed moving '\(file)': \(reason)\nAlready-moved files stay moved; fix the cause and re-run (safe).\n".utf8))
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("phlook-ingest: error: \(error)\n".utf8))
            exit(2)
        }
    }
}
