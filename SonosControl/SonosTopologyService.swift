import Foundation

enum SonosTopologyError: LocalizedError {
    case invalidAddress
    case invalidResponse
    case requestFailed(Int)
    case missingTopology

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "L’adresse de l’enceinte Sonos est invalide."
        case .invalidResponse:
            "La topologie Sonos est illisible."
        case .requestFailed(let statusCode):
            "La topologie Sonos n’est pas disponible (HTTP \(statusCode))."
        case .missingTopology:
            "Aucune topologie de groupe n’a été renvoyée."
        }
    }
}

enum SonosTopologyService {
    static func groups(from devices: [SonosDevice]) async throws -> [SonosGroup] {
        guard !devices.isEmpty else { return [] }

        var descriptions: [GroupDescription]?
        for sourceDevice in devices {
            guard let topologyXML = try? await fetchTopology(from: sourceDevice),
                  let parsedDescriptions = try? parseTopology(topologyXML),
                  !parsedDescriptions.isEmpty else {
                continue
            }
            descriptions = parsedDescriptions
            break
        }

        guard let descriptions else {
            throw SonosTopologyError.missingTopology
        }

        return descriptions.compactMap { description in
            let members = description.members.map { member in
                matchingDevice(for: member, in: devices)
            }

            guard let coordinator = members.first(where: {
                normalizedIdentifier($0.id) == normalizedIdentifier(description.coordinatorID)
            }) ?? description.members
                .first(where: {
                    normalizedIdentifier($0.id) == normalizedIdentifier(description.coordinatorID)
                })
                .map({ matchingDevice(for: $0, in: devices) })
            else {
                return nil
            }

            return SonosGroup(
                id: description.id,
                coordinator: coordinator,
                members: members
            )
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func fetchTopology(from device: SonosDevice) async throws -> String {
        guard var components = URLComponents(
            url: device.locationURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw SonosTopologyError.invalidAddress
        }

        components.path = "/ZoneGroupTopology/Control"
        components.query = nil
        guard let url = components.url else {
            throw SonosTopologyError.invalidAddress
        }

        let serviceType = "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:GetZoneGroupState xmlns:u="\(serviceType)"></u:GetZoneGroupState>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "\"\(serviceType)#GetZoneGroupState\"",
            forHTTPHeaderField: "SOAPACTION"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonosTopologyError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SonosTopologyError.requestFailed(httpResponse.statusCode)
        }

        let parserDelegate = ZoneGroupStateResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(),
              let topologyXML = parserDelegate.zoneGroupState,
              !topologyXML.isEmpty else {
            throw SonosTopologyError.missingTopology
        }

        return topologyXML
    }

    private static func parseTopology(_ topologyXML: String) throws -> [GroupDescription] {
        guard let data = topologyXML.data(using: .utf8) else {
            throw SonosTopologyError.invalidResponse
        }

        let parserDelegate = ZoneGroupTopologyParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SonosTopologyError.invalidResponse
        }

        return parserDelegate.groups
    }

    private static func matchingDevice(
        for member: MemberDescription,
        in devices: [SonosDevice]
    ) -> SonosDevice {
        if let existingDevice = devices.first(where: {
            normalizedIdentifier($0.id) == normalizedIdentifier(member.id)
                || $0.locationURL.host == member.locationURL.host
        }) {
            return SonosDevice(
                id: member.id,
                name: member.name,
                modelName: existingDevice.modelName,
                locationURL: member.locationURL
            )
        }

        return SonosDevice(
            id: member.id,
            name: member.name,
            modelName: "Sonos",
            locationURL: member.locationURL
        )
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "uuid:", with: "", options: .caseInsensitive)
            .uppercased()
    }
}

private struct GroupDescription {
    let id: String
    let coordinatorID: String
    var members: [MemberDescription]
}

private struct MemberDescription {
    let id: String
    let name: String
    let locationURL: URL
}

private final class ZoneGroupStateResponseParser: NSObject, XMLParserDelegate {
    private var isReadingState = false
    private var stateText = ""

    private(set) var zoneGroupState: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "ZoneGroupState" {
            isReadingState = true
            stateText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isReadingState {
            stateText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "ZoneGroupState" {
            zoneGroupState = stateText
            isReadingState = false
        }
    }
}

private final class ZoneGroupTopologyParser: NSObject, XMLParserDelegate {
    private var currentGroupID: String?
    private var currentCoordinatorID: String?
    private var currentMembers: [MemberDescription] = []

    private(set) var groups: [GroupDescription] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let attributes = attributeDict

        switch elementName {
        case "ZoneGroup":
            currentGroupID = attributes["ID"]
            currentCoordinatorID = attributes["Coordinator"]
            currentMembers = []

        case "ZoneGroupMember":
            guard attributes["Invisible"] != "1",
                  let id = attributes["UUID"],
                  let location = attributes["Location"],
                  let locationURL = URL(string: location) else {
                return
            }

            currentMembers.append(
                MemberDescription(
                    id: id,
                    name: attributes["ZoneName"] ?? "Pièce Sonos",
                    locationURL: locationURL
                )
            )

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard elementName == "ZoneGroup",
              let id = currentGroupID,
              let coordinatorID = currentCoordinatorID,
              !currentMembers.isEmpty else {
            return
        }

        groups.append(
            GroupDescription(
                id: id,
                coordinatorID: coordinatorID,
                members: currentMembers
            )
        )
        currentGroupID = nil
        currentCoordinatorID = nil
        currentMembers = []
    }
}
