import Foundation
import SnoreLog
let args = Array(CommandLine.arguments.dropFirst())
do {
    guard let wav = args.first else { throw CocoaError(.fileReadNoSuchFile) }
    func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard let root = option("--output-root") else { throw CocoaError(.fileWriteInvalidFileName) }
    var gaps: [(Double,Double)] = []
    for i in args.indices where args[i] == "--gap-at" && i + 1 < args.count {
        let values = args[i+1].split(separator: ":").compactMap { Double($0) }
        guard values.count == 2 else { throw CocoaError(.fileReadCorruptFile) }; gaps.append((values[0],values[1]))
    }
    let result = try HostDemoAPI.run(wav: URL(fileURLWithPath: wav), labels: option("--labels").map { URL(fileURLWithPath: $0) }, root: URL(fileURLWithPath: root), gaps: gaps, alarmAt: option("--alarm-at").flatMap(Double.init))
    FileHandle.standardOutput.write(result); FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
