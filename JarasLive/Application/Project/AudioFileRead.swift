import AVFoundation

/// Some MP3 gapless headers overstate the final decoded sample count by a
/// fraction of one packet. AVAudioFile then reports EOF (sometimes nilError)
/// after successfully decoding all samples. Other errors remain errors.
enum AudioFileRead {
    static func hasMP3Padding(_ file: AVAudioFile) -> Bool {
        let format = file.fileFormat.streamDescription.pointee
        let remaining = file.length - file.framePosition
        return format.mFormatID == kAudioFormatMPEGLayer3 && format.mFramesPerPacket > 0 &&
            file.framePosition > 0 && remaining > 0 && remaining < Int64(format.mFramesPerPacket)
    }
    static func toleratesEnd(_ error: Error, file: AVAudioFile, buffer: AVAudioPCMBuffer) -> Bool {
        let error = error as NSError
        let eof = error.domain == NSOSStatusErrorDomain && error.code == -39
        let decoderEOF = error.domain == "Foundation._GenericObjCError" && error.code == 0
        return (eof || decoderEOF) && buffer.frameLength == 0 && hasMP3Padding(file)
    }
    @discardableResult static func read(_ file: AVAudioFile, into buffer: AVAudioPCMBuffer,
                                       frameCount: AVAudioFrameCount? = nil) throws -> Bool {
        buffer.frameLength = 0
        do { try file.read(into: buffer, frameCount: frameCount ?? buffer.frameCapacity) }
        catch {
            guard toleratesEnd(error, file: file, buffer: buffer) else { throw error }
            return false
        }
        if buffer.frameLength == 0, file.framePosition < file.length, !hasMP3Padding(file) {
            throw NSError(domain: NSOSStatusErrorDomain, code: -39)
        }
        return buffer.frameLength > 0
    }
}
