import Testing

@Suite("Download size limit (SEC-027)")
struct DownloadLimitsTests {
    @Test func withinDeclaredSize() {
        #expect(!DownloadLimits.exceeds(written: 0, expectedSize: 100, isExport: false))
        #expect(!DownloadLimits.exceeds(written: 100, expectedSize: 100, isExport: false))
    }

    @Test func endlessStreamIsStopped() {
        #expect(DownloadLimits.exceeds(written: 101, expectedSize: 100, isExport: false))
        #expect(DownloadLimits.exceeds(written: .max, expectedSize: 1, isExport: false))
    }

    @Test func unknownSizeAndExportsAreNotLimited() {
        #expect(!DownloadLimits.exceeds(written: 1_000_000, expectedSize: 0, isExport: false))
        #expect(!DownloadLimits.exceeds(written: 1_000_000, expectedSize: 10, isExport: true))
    }
}
