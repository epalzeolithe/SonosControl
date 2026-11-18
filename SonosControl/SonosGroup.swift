import Foundation

struct SonosGroup: Identifiable, Hashable, Sendable {
    let id: String
    let coordinator: SonosDevice
    let members: [SonosDevice]

    var name: String {
        let roomNames = members.map(\.name)
        guard !roomNames.isEmpty else { return coordinator.name }
        return roomNames.formatted(.list(type: .and, width: .short))
    }

    var subtitle: String {
        if members.count == 1 {
            return coordinator.modelName
        }
        return "\(members.count) pièces"
    }
}
