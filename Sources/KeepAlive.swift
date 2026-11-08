import AVFoundation
import Foundation

/// Keeps the process alive while backgrounded by looping a silent audio
/// file (the standard sideloaded-utility trick). Without it, iOS suspends
/// the app seconds after it leaves the foreground; a suspended app's
/// NWListener can no longer accept connections and dies with
/// -65569 (DefunctConnection), which is exactly what killed the pairing
/// attempts on 2026-11-08: the Settings pairing sheet tapped a stale
/// Bonjour entry whose listener was already gone.
final class KeepAlive {
    static let shared = KeepAlive()

    private var player: AVAudioPlayer?
    private(set) var isActive = false

    func start(logger: @escaping (String) -> Void) {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let url = try Self.silentWavURL()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            self.player = player
            isActive = true
            logger("Keep-alive started (silent audio, background-safe)")
        } catch {
            logger("Keep-alive failed to start: \(error)")
        }
    }

    func stop(logger: @escaping (String) -> Void) {
        guard player != nil else { return }
        player?.stop()
        player = nil
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        logger("Keep-alive stopped")
    }

    /// Writes a 1-second silent WAV (44.1 kHz, mono, 16-bit PCM) into the
    /// caches directory and returns its URL. Generated at runtime so the
    /// repo carries no binary asset.
    private static func silentWavURL() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("pokirelay-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate = 44100
        let frames = sampleRate // 1 second of silence
        var data = Data()
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [UInt8]("RIFF".utf8))
        appendLE(UInt32(36 + frames * 2))
        data.append(contentsOf: [UInt8]("WAVE".utf8))
        data.append(contentsOf: [UInt8]("fmt ".utf8))
        appendLE(UInt32(16))             // fmt chunk size
        appendLE(UInt16(1))              // PCM
        appendLE(UInt16(1))              // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)) // byte rate
        appendLE(UInt16(2))              // block align
        appendLE(UInt16(16))             // bits per sample
        data.append(contentsOf: [UInt8]("data".utf8))
        appendLE(UInt32(frames * 2))
        data.append(Data(count: frames * 2)) // all-zero samples = silence
        try data.write(to: url, options: [.atomic])
        return url
    }
}
