import Testing
@testable import ChipBar

struct InternalStorageSamplerTests {
    @Test func prefersUserAvailableIncludingPurgeableSpace() {
        let result = InternalStorageSampler.checkedCapacity(
            total: 512_000_000_000,
            important: 220_000_000_000,
            raw: 155_000_000_000)
        #expect(result?.availableBytes == 220_000_000_000)
    }

    @Test func fallsBackWhenImportantCapacityIsMissingOrInvalid() {
        #expect(InternalStorageSampler.checkedCapacity(
            total: 512, important: nil, raw: 120)?.availableBytes == 120)
        #expect(InternalStorageSampler.checkedCapacity(
            total: 512, important: 900, raw: 110)?.availableBytes == 110)
        #expect(InternalStorageSampler.checkedCapacity(
            total: 512, important: -1, raw: -2) == nil)
    }

    @Test func capacityIsValidWhenInternalSystemDiskIsAvailable() async {
        // CI Macs may use external/virtual boot storage. On such machines
        // the sampler must return nil rather than mislabel it "internal".
        if let capacity = await InternalStorageSampler().read() {
            #expect(capacity.totalBytes > 0)
            #expect(capacity.availableBytes >= 0)
            #expect(capacity.availableBytes <= capacity.totalBytes)
            #expect(capacity.usedFraction >= 0)
            #expect(capacity.usedFraction <= 1)
        }
    }
}
