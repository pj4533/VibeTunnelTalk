import Foundation
import AVFoundation
import OSLog

// MARK: - Audio Management
extension OpenAIRealtimeManager {

    func setupAudioSession() {
        // AVAudioSession is not available on macOS
        // Audio permissions are handled at the system level
    }

    /// Start listening for voice input
    func startListening() {
        guard !isListening else { return }

        DispatchQueue.main.async {
            self.isListening = true
        }

        startAudioCapture()
    }

    /// Stop listening for voice input
    func stopListening() {
        guard isListening else { return }

        stopAudioCapture()

        // Send input audio buffer commit event
        let event: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        sendEvent(event)

        // Request response
        let responseEvent: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["text", "audio"]
            ]
        ]
        sendEvent(responseEvent)

        DispatchQueue.main.async {
            self.isListening = false
        }
    }

    func startAudioCapture() {
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Install tap to capture audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        do {
            try audioEngine.start()
        } catch {
            logger.error("[OPENAI-AUDIO] ❌ Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    func stopAudioCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let frameLength = Int(buffer.frameLength)

        // Convert Float32 samples to Int16
        var int16Data = [Int16]()
        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            let int16Sample = Int16(max(-32768, min(32767, sample * 32767)))
            int16Data.append(int16Sample)
        }

        let data = int16Data.withUnsafeBytes { Data($0) }

        // Send audio data to OpenAI
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
        sendEvent(event)
    }

    func handleAudioChunk(_ audioData: Data) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }

        // Buffer audio data
        audioQueue.async { [weak self] in
            self?.audioBufferData.append(audioData)
        }
    }

    func playBufferedAudio() {
        audioQueue.async { [weak self] in
            guard let self = self, !self.audioBufferData.isEmpty else { return }

            // Create WAV header for PCM16 data
            let wavData = self.createWAVData(from: self.audioBufferData)

            do {
                self.audioPlayer = try AVAudioPlayer(data: wavData)
                self.audioPlayer?.play()
            } catch {
                self.logger.error("[OPENAI-AUDIO] ❌ Failed to play audio: \(error.localizedDescription)")
            }

            // Clear buffer
            self.audioBufferData = Data()
        }
    }

    func createWAVData(from pcmData: Data) -> Data {
        var wavData = Data()

        // WAV header
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let dataSize = UInt32(pcmData.count)

        // RIFF chunk
        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(36 + dataSize).littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // PCM
        wavData.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt32(sampleRate * UInt32(channels) * UInt32(bitsPerSample/8)).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: UInt16(channels * bitsPerSample/8).littleEndian) { Data($0) })
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data chunk
        wavData.append("data".data(using: .ascii)!)
        wavData.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        wavData.append(pcmData)

        return wavData
    }
}