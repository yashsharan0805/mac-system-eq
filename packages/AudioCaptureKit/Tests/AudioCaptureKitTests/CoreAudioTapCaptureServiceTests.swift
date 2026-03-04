import AVFAudio
import Testing
@testable import AudioCaptureKit

@Suite("CoreAudioTapCaptureService")
struct CoreAudioTapCaptureServiceTests {
    @Test("has a default captured format")
    func hasDefaultFormat() {
        let service = CoreAudioTapCaptureService()
        #expect(service.capturedFormat.channelCount == 2)
        #expect(service.capturedFormat.sampleRate > 0)
    }
}
