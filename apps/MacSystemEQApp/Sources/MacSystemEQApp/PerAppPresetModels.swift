import Foundation

struct RunningAppOption: Identifiable, Equatable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

struct PerAppPresetMapping: Codable, Identifiable, Equatable {
    let bundleIdentifier: String
    var appName: String
    var presetID: UUID

    var id: String { bundleIdentifier }
}
