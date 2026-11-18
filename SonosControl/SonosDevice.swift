import Foundation

struct SonosDevice: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let modelName: String
    let locationURL: URL

    var host: String {
        locationURL.host ?? locationURL.absoluteString
    }
}
