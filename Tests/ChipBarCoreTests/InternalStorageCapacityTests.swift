import Foundation
import Testing
@testable import ChipBarCore

struct InternalStorageCapacityTests {
    @Test func rejectsInvalidOrDuplicatedCapacity() {
        #expect(InternalStorageCapacity(totalBytes: 0, availableBytes: 0) == nil)
        #expect(InternalStorageCapacity(totalBytes: -1, availableBytes: 0) == nil)
        #expect(InternalStorageCapacity(totalBytes: 1_000, availableBytes: -1) == nil)
        #expect(InternalStorageCapacity(totalBytes: 1_000, availableBytes: 1_001) == nil)
    }

    @Test func calculatesUsedFractionFromOneFilesystemVolume() {
        let capacity = InternalStorageCapacity(totalBytes: 1_000_000_000_000,
                                               availableBytes: 350_000_000_000)
        #expect(capacity?.usedFraction == 0.65)
        #expect(capacity?.totalBytes == 1_000_000_000_000)
        #expect(capacity?.availableBytes == 350_000_000_000)
    }

    @Test func emptyAndFullAreValid() {
        #expect(InternalStorageCapacity(totalBytes: 512_000_000_000,
                                        availableBytes: 512_000_000_000)?.usedFraction == 0)
        #expect(InternalStorageCapacity(totalBytes: 512_000_000_000,
                                        availableBytes: 0)?.usedFraction == 1)
    }

    @Test func formatsNonemptyDecimalDiskSizes() {
        let capacity = InternalStorageCapacity(totalBytes: 1_000_000_000_000,
                                               availableBytes: 480_000_000_000)
        #expect(capacity != nil)
        #expect(!(capacity?.availableText.isEmpty ?? true))
        #expect(!(capacity?.totalText.isEmpty ?? true))
    }
}
