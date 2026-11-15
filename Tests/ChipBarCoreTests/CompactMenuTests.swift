import Testing
@testable import ChipBarCore

struct CompactMenuTests {
    @Test func transferUnitsKeepDirectionRowsShort() {
        #expect(MenuReadout.rate(nil) == "—")
        #expect(MenuReadout.rate(.nan) == "—")
        #expect(MenuReadout.rate(-1) == "—")
        #expect(MenuReadout.rate(0) == "0B/s")
        #expect(MenuReadout.rate(29_700) == "29.7K/s")
        #expect(MenuReadout.rate(250_000) == "250K/s")
        #expect(MenuReadout.rate(1_200_000) == "1.2M/s")
        #expect(MenuReadout.rate(3_400_000_000) == "3.4G/s")
    }
}
