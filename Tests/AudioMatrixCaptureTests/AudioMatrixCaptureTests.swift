import AudioMatrixCapture
import AudioMatrixCore
import XCTest

final class ProcessEnumeratorTests: XCTestCase {
    func testListAudioProcessesDoesNotThrow() throws {
        _ = try ProcessEnumerator.listAudioProcesses()
    }
}
