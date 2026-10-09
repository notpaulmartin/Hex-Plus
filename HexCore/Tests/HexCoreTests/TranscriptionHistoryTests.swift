import Foundation
import Testing
@testable import HexCore

struct TranscriptionHistoryTests {
    @Test
    func preservesOriginalAndFinalTextAcrossHistoryReload() throws {
        let transcript = Transcript(
            timestamp: Date(),
            text: "Polished output.",
            audioPath: URL(fileURLWithPath: "/tmp/recording.wav"),
            duration: 2,
            originalText: "um original words"
        )
        let history = TranscriptionHistory(history: [transcript])
        let restored = try JSONDecoder().decode(
            TranscriptionHistory.self,
            from: JSONEncoder().encode(history)
        )

        #expect(restored == history)
        #expect(restored.history.first?.text == "Polished output.")
        #expect(restored.history.first?.originalText == "um original words")
    }

    @Test
    func loadsLegacyHistoryWithoutInventingOriginalText() throws {
        let json = """
        {"history":[{
            "id":"00000000-0000-0000-0000-000000000001",
            "timestamp":0,
            "text":"Previously processed output.",
            "audioPath":"file:///tmp/recording.wav",
            "duration":2
        }]}
        """
        let history = try JSONDecoder().decode(TranscriptionHistory.self, from: Data(json.utf8))

        #expect(history.history.count == 1)
        #expect(history.history.first?.text == "Previously processed output.")
        #expect(history.history.first?.originalText == nil)
    }
}
