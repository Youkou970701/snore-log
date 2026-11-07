import Foundation
import AVFAudio
import SoundAnalysis
import CoreMedia

@main struct Probe {
    static func main() throws {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 16_000)
        print("actualWindowSec=\(request.windowDuration.seconds)")
        let classifier = AppleSnoreClassifier()
        for frequency in [0.0, 120.0, 440.0] {
            let pcm: [Float] = (0..<16_000).map { i in frequency == 0 ? 0 : Float(0.1 * sin(2 * .pi * frequency * Double(i) / 16_000)) }
            let value = try classifier.classify(samples: pcm, second: 0)
            print("frequency=\(frequency), snoring=\(value.snoring), breathing=\(value.breathing)")
        }
    }
}
