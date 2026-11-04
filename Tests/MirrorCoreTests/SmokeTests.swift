import Testing
@testable import MirrorCore

@Test func bundleIdentifier() {
    #expect(MirrorCore.bundleID == "com.shaikjaleel.mirror")
}
