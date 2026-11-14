import AVFoundation
import Foundation

/// Keeps DingDing running in the background during the night by playing silent audio
/// (mixed with other apps, so it never interrupts music or videos).
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var isRunning: Bool { player?.isPlaying == true }

    func start() {
        guard player == nil else {
            if player?.isPlaying == false { player?.play() }
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV(seconds: 2))
            player.numberOfLoops = -1
            player.volume = 0.01
            player.prepareToPlay()
            player.play()
            self.player = player
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
                Task { @MainActor in KeepAlive.shared.resume() }
            }
            Log.add("Veille : maintien en arrière-plan activé")
        } catch {
            Log.add("⚠️ Veille : audio impossible (\(error.localizedDescription))")
        }
    }

    func resume() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.play()
        Log.add("Veille : audio relancé après interruption")
    }

    func stop() {
        player?.stop()
        player = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// 16-bit mono PCM WAV full of zeros.
    static func silentWAV(seconds: Double, sampleRate: Int = 8000) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        let dataSize = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
