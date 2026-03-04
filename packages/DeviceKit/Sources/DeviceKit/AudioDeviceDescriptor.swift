import CoreAudio
import Foundation

public typealias AudioDeviceID = AudioObjectID

public struct AudioDeviceDescriptor: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isDefaultOutput: Bool

    public init(id: AudioDeviceID, uid: String, name: String, isDefaultOutput: Bool) {
        self.id = id
        self.uid = uid
        self.name = name
        self.isDefaultOutput = isDefaultOutput
    }
}
