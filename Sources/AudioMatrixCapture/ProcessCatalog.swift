import AudioMatrixCore
import Foundation

public enum ProcessCatalog {
    public static func buildCatalog() throws -> SourceCatalogSnapshot {
        let rawProcesses = try ProcessEnumerator.listAudioProcesses()
        return buildCatalog(from: rawProcesses)
    }

    public static func buildCatalog(from rawProcesses: [AudioProcessInfo]) -> SourceCatalogSnapshot {
        SourceCatalogBuilder.build(from: rawProcesses)
    }
}
