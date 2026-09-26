import AVFoundation
import AppKit

/// Listens to the default microphone alongside VoxType (CoreAudio lets several clients capture the
/// same input) and reports a smoothed level from 0 to 1 about thirty times a second. Audio never
/// leaves the callback: only the RMS number is passed on.
final class LevelMeter {
    private var engine: AVAudioEngine?
    private var smoothed: Float = 0
    var onLevel: ((Float) -> Void)?

    func start() {
        guard engine == nil else { return }
        // A fresh engine for every recording. A long-lived one keeps describing the input device it
        // first saw, and once the default microphone changes, installing a tap with that stale
        // format raises an uncatchable "format mismatch" exception that takes the whole app down.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = (sum / Float(frames)).squareRoot()
            // Map −50 dBFS (room tone) to −10 dBFS (loud speech) onto 0…1, with a quick attack and slower decay.
            let db = 20 * log10(max(rms, 1e-7))
            let level = min(max((db + 50) / 40, 0), 1)
            self.smoothed = level > self.smoothed ? level : self.smoothed * 0.75 + level * 0.25
            let value = self.smoothed
            DispatchQueue.main.async { self.onLevel?(value) }
        }
        do { try engine.start(); self.engine = engine } catch { input.removeTap(onBus: 0) }
    }

    func stop() {
        guard let engine = engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil; smoothed = 0
    }
}

/// A row of thin bars showing the last second or so of microphone level, newest on the right.
final class LevelView: NSView {
    private var history = [Float](repeating: 0, count: 14)
    func push(_ level: Float) { history.removeFirst(); history.append(level); needsDisplay = true }
    func reset() { history = [Float](repeating: 0, count: history.count); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 3, gap: CGFloat = 2
        let x0 = bounds.midX - (CGFloat(history.count) * (width + gap) - gap) / 2
        for (i, level) in history.enumerated() {
            let height = max(2, CGFloat(level) * bounds.height)
            let rect = NSRect(x: x0 + CGFloat(i) * (width + gap), y: bounds.midY - height / 2, width: width, height: height)
            NSColor.labelColor.withAlphaComponent(0.35 + 0.65 * CGFloat(level)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}
