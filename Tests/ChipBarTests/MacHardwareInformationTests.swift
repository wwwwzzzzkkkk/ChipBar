import Foundation
import Testing
@testable import ChipBar

struct MacHardwareInformationTests {
    @Test func readsNonPrivilegedCurrentMacFacts() {
        let info = MacHardwareInformation.current
        #expect(info.logicalCPUCount > 0)
        #expect(!info.macOSVersion.isEmpty)
        #expect(info.macOSVersion.hasPrefix("macOS "))
        #expect(!info.installedMemory.isEmpty)
        #expect(!info.modelIdentifier.isEmpty)
    }

    @Test func currentFactsAreStableAcrossPageTransitions() {
        let first = MacHardwareInformation.current
        let second = MacHardwareInformation.current
        #expect(first == second)
    }
}
