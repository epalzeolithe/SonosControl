import Darwin
import Foundation

enum SonosDiscoveryError: LocalizedError {
    case socketCreationFailed
    case socketConfigurationFailed
    case searchFailed

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            "Impossible d’ouvrir la connexion de découverte."
        case .socketConfigurationFailed:
            "Impossible de configurer la découverte réseau."
        case .searchFailed:
            "La recherche Sonos a échoué."
        }
    }
}

enum SonosDiscoveryService {
    static func discover() async throws -> [SonosDevice] {
        let locations = try await Task.detached {
            try discoverLocations()
        }.value

        return await withTaskGroup(of: SonosDevice.self) { group in
            for location in locations {
                group.addTask {
                    await loadDevice(at: location)
                }
            }

            var devices: [SonosDevice] = []
            for await device in group {
                devices.append(device)
            }

            return devices.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    nonisolated private static func discoverLocations() throws -> Set<URL> {
        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketDescriptor >= 0 else {
            throw SonosDiscoveryError.socketCreationFailed
        }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 500_000)
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw SonosDiscoveryError.socketConfigurationFailed
        }

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_port = 0
        localAddress.sin_addr.s_addr = in_addr_t(INADDR_ANY)

        let bindResult = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(
                    socketDescriptor,
                    address,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw SonosDiscoveryError.socketConfigurationFailed
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(1900).bigEndian
        guard inet_pton(AF_INET, "239.255.255.250", &destination.sin_addr) == 1 else {
            throw SonosDiscoveryError.socketConfigurationFailed
        }

        let searchTargets = [
            "urn:schemas-upnp-org:device:ZonePlayer:1",
            "urn:schemas-upnp-org:device:MediaRenderer:1",
            "ssdp:all"
        ]

        for searchTarget in searchTargets {
            let request = [
                "M-SEARCH * HTTP/1.1",
                "HOST: 239.255.255.250:1900",
                "MAN: \"ssdp:discover\"",
                "MX: 2",
                "ST: \(searchTarget)",
                "",
                ""
            ].joined(separator: "\r\n")

            let sent = request.withCString { bytes in
                withUnsafePointer(to: &destination) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        sendto(
                            socketDescriptor,
                            bytes,
                            strlen(bytes),
                            0,
                            address,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            guard sent >= 0 else {
                throw SonosDiscoveryError.searchFailed
            }
        }

        var locations = Set<URL>()
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while true {
            let byteCount = recv(socketDescriptor, &buffer, buffer.count, 0)
            guard byteCount > 0 else { break }

            let response = String(decoding: buffer.prefix(byteCount), as: UTF8.self)
            let normalizedResponse = response.lowercased()
            guard normalizedResponse.contains("sonos")
                    || normalizedResponse.contains("rincon_")
                    || normalizedResponse.contains("zoneplayer") else {
                continue
            }

            if let location = header(named: "location", in: response),
               let url = URL(string: location) {
                locations.insert(url)
            }
        }

        return locations
    }

    nonisolated private static func header(named name: String, in response: String) -> String? {
        let prefix = name.lowercased() + ":"

        for line in response.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.lowercased().hasPrefix(prefix) else { continue }
            return String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func loadDevice(at location: URL) async -> SonosDevice {
        let fallbackName = location.host.map { "Sonos (\($0))" } ?? "Enceinte Sonos"
        let fallbackDevice = SonosDevice(
            id: location.absoluteString,
            name: fallbackName,
            modelName: "Sonos",
            locationURL: location
        )

        var request = URLRequest(url: location)
        request.timeoutInterval = 4

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return fallbackDevice
        }

        let parserDelegate = DeviceDescriptionParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else { return fallbackDevice }

        return SonosDevice(
            id: parserDelegate.udn ?? location.absoluteString,
            name: parserDelegate.roomName ?? parserDelegate.friendlyName ?? fallbackName,
            modelName: parserDelegate.modelName ?? "Sonos",
            locationURL: location
        )
    }
}

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""

    private(set) var roomName: String?
    private(set) var friendlyName: String?
    private(set) var modelName: String?
    private(set) var udn: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        switch currentElement {
        case "roomname":
            roomName = value
        case "friendlyname":
            friendlyName = value
        case "modelname":
            modelName = value
        case "udn":
            udn = value
        default:
            break
        }
    }
}
