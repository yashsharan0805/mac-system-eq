@testable import DeviceKit
import Testing

struct AudioDeviceDescriptorTests {
    @Test("preserves assigned values")
    func valuesAreStored() {
        let descriptor = AudioDeviceDescriptor(id: 42, uid: "uid-42", name: "Speakers", isDefaultOutput: true)
        #expect(descriptor.id == 42)
        #expect(descriptor.uid == "uid-42")
        #expect(descriptor.name == "Speakers")
        #expect(descriptor.isDefaultOutput)
    }
}
