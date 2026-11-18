import Foundation

enum SonosPlaybackState: Equatable, Sendable {
    case playing
    case paused
    case stopped
    case transitioning
    case unknown

    init(upnpValue: String) {
        switch upnpValue.uppercased() {
        case "PLAYING":
            self = .playing
        case "PAUSED_PLAYBACK":
            self = .paused
        case "STOPPED":
            self = .stopped
        case "TRANSITIONING":
            self = .transitioning
        default:
            self = .unknown
        }
    }

    var isPlaying: Bool {
        self == .playing
    }
}

struct SonosTrackInfo: Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let artworkURL: URL?
}

struct SonosPlayerStatus: Sendable {
    let playbackState: SonosPlaybackState
    let volume: Double
    let isMuted: Bool
    let track: SonosTrackInfo?
}

enum SonosControlError: LocalizedError {
    case invalidDeviceAddress
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDeviceAddress:
            "L’adresse de cette enceinte est invalide."
        case .invalidResponse:
            "L’enceinte a renvoyé une réponse inattendue."
        case .requestFailed(let statusCode):
            "La commande Sonos a échoué (HTTP \(statusCode))."
        }
    }
}

enum SonosControlService {
    static func status(for device: SonosDevice) async throws -> SonosPlayerStatus {
        async let playbackState = playbackState(for: device)
        async let volume = volume(for: device)
        async let isMuted = isMuted(device)
        async let currentTrack = currentTrack(for: device)

        let track = try? await currentTrack
        let muted = (try? await isMuted) ?? false
        return try await SonosPlayerStatus(
            playbackState: playbackState,
            volume: volume,
            isMuted: muted,
            track: track
        )
    }

    static func isPlaying(_ device: SonosDevice) async -> Bool {
        (try? await playbackState(for: device)) == .playing
    }

    static func play(_ device: SonosDevice) async throws {
        _ = try await send(
            action: "Play",
            service: "AVTransport",
            path: "/MediaRenderer/AVTransport/Control",
            arguments: [
                ("InstanceID", "0"),
                ("Speed", "1")
            ],
            to: device
        )
    }

    static func pause(_ device: SonosDevice) async throws {
        _ = try await send(
            action: "Pause",
            service: "AVTransport",
            path: "/MediaRenderer/AVTransport/Control",
            arguments: [("InstanceID", "0")],
            to: device
        )
    }

    static func deviceVolume(for device: SonosDevice) async throws -> Double {
        let values = try await send(
            action: "GetVolume",
            service: "RenderingControl",
            path: "/MediaRenderer/RenderingControl/Control",
            arguments: [
                ("InstanceID", "0"),
                ("Channel", "Master")
            ],
            to: device
        )

        guard let value = values["CurrentVolume"],
              let volume = Double(value) else {
            throw SonosControlError.invalidResponse
        }
        return volume
    }

    static func setDeviceVolume(_ volume: Double, on device: SonosDevice) async throws {
        let clampedVolume = min(max(Int(volume.rounded()), 0), 100)
        _ = try await send(
            action: "SetVolume",
            service: "RenderingControl",
            path: "/MediaRenderer/RenderingControl/Control",
            arguments: [
                ("InstanceID", "0"),
                ("Channel", "Master"),
                ("DesiredVolume", String(clampedVolume))
            ],
            to: device
        )
    }

    static func setVolume(_ volume: Double, on device: SonosDevice) async throws {
        let clampedVolume = min(max(Int(volume.rounded()), 0), 100)
        _ = try await send(
            action: "SetGroupVolume",
            service: "GroupRenderingControl",
            path: "/MediaRenderer/GroupRenderingControl/Control",
            arguments: [
                ("InstanceID", "0"),
                ("DesiredVolume", String(clampedVolume))
            ],
            to: device
        )
    }

    static func setMuted(_ isMuted: Bool, on device: SonosDevice) async throws {
        _ = try await send(
            action: "SetGroupMute",
            service: "GroupRenderingControl",
            path: "/MediaRenderer/GroupRenderingControl/Control",
            arguments: [
                ("InstanceID", "0"),
                ("DesiredMute", isMuted ? "1" : "0")
            ],
            to: device
        )
    }

    static func group(
        _ devices: [SonosDevice],
        with coordinator: SonosDevice
    ) async throws {
        let coordinatorID = normalizedIdentifier(coordinator.id)
        let devicesToJoin = devices.filter {
            normalizedIdentifier($0.id) != coordinatorID
                && $0.locationURL.host != coordinator.locationURL.host
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in devicesToJoin {
                group.addTask {
                    _ = try await send(
                        action: "SetAVTransportURI",
                        service: "AVTransport",
                        path: "/MediaRenderer/AVTransport/Control",
                        arguments: [
                            ("InstanceID", "0"),
                            ("CurrentURI", "x-rincon:\(coordinatorID)"),
                            ("CurrentURIMetaData", "")
                        ],
                        to: device
                    )
                }
            }

            try await group.waitForAll()
        }
    }

    static func ungroup(
        _ devices: [SonosDevice],
        keeping coordinator: SonosDevice
    ) async throws {
        let coordinatorID = normalizedIdentifier(coordinator.id)
        let devicesToSeparate = devices.filter {
            normalizedIdentifier($0.id) != coordinatorID
                && $0.locationURL.host != coordinator.locationURL.host
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in devicesToSeparate {
                group.addTask {
                    _ = try await send(
                        action: "BecomeCoordinatorOfStandaloneGroup",
                        service: "AVTransport",
                        path: "/MediaRenderer/AVTransport/Control",
                        arguments: [("InstanceID", "0")],
                        to: device
                    )
                }
            }

            try await group.waitForAll()
        }
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "uuid:", with: "", options: .caseInsensitive)
            .uppercased()
    }

    private static func playbackState(for device: SonosDevice) async throws -> SonosPlaybackState {
        let values = try await send(
            action: "GetTransportInfo",
            service: "AVTransport",
            path: "/MediaRenderer/AVTransport/Control",
            arguments: [("InstanceID", "0")],
            to: device
        )
        return SonosPlaybackState(upnpValue: values["CurrentTransportState"] ?? "")
    }

    private static func currentTrack(for device: SonosDevice) async throws -> SonosTrackInfo? {
        let values = try await send(
            action: "GetPositionInfo",
            service: "AVTransport",
            path: "/MediaRenderer/AVTransport/Control",
            arguments: [("InstanceID", "0")],
            to: device
        )

        guard let metadata = values["TrackMetaData"],
              !metadata.isEmpty,
              metadata != "NOT_IMPLEMENTED",
              let data = metadata.data(using: .utf8) else {
            return nil
        }

        let parserDelegate = TrackMetadataParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse(), let title = parserDelegate.title else {
            return nil
        }

        return SonosTrackInfo(
            title: title,
            artist: parserDelegate.artist,
            album: parserDelegate.album,
            artworkURL: artworkURL(
                from: parserDelegate.artworkPath,
                relativeTo: device.locationURL
            )
        )
    }

    private static func artworkURL(from path: String?, relativeTo deviceURL: URL) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absoluteURL = URL(string: path), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard var components = URLComponents(
            url: deviceURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.path = "/"
        components.query = nil
        guard let baseURL = components.url else { return nil }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    private static func volume(for device: SonosDevice) async throws -> Double {
        let values = try await send(
            action: "GetGroupVolume",
            service: "GroupRenderingControl",
            path: "/MediaRenderer/GroupRenderingControl/Control",
            arguments: [
                ("InstanceID", "0")
            ],
            to: device
        )

        guard let value = values["CurrentVolume"],
              let volume = Double(value) else {
            throw SonosControlError.invalidResponse
        }
        return volume
    }

    private static func isMuted(_ device: SonosDevice) async throws -> Bool {
        let values = try await send(
            action: "GetGroupMute",
            service: "GroupRenderingControl",
            path: "/MediaRenderer/GroupRenderingControl/Control",
            arguments: [("InstanceID", "0")],
            to: device
        )

        guard let value = values["CurrentMute"] else {
            throw SonosControlError.invalidResponse
        }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame
    }

    private static func send(
        action: String,
        service: String,
        path: String,
        arguments: [(String, String)],
        to device: SonosDevice
    ) async throws -> [String: String] {
        guard var components = URLComponents(url: device.locationURL, resolvingAgainstBaseURL: false) else {
            throw SonosControlError.invalidDeviceAddress
        }
        components.path = path
        components.query = nil

        guard let url = components.url else {
            throw SonosControlError.invalidDeviceAddress
        }

        let serviceType = "urn:schemas-upnp-org:service:\(service):1"
        let bodyArguments = arguments
            .map { "<\($0.0)>\(xmlEscaped($0.1))</\($0.0)>" }
            .joined()

        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceType)">\(bodyArguments)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = Data(envelope.utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SonosControlError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw SonosControlError.requestFailed(httpResponse.statusCode)
        }

        let parserDelegate = SOAPResponseParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SonosControlError.invalidResponse
        }

        return parserDelegate.values
    }

    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class TrackMetadataParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""

    private(set) var title: String?
    private(set) var artist: String?
    private(set) var album: String?
    private(set) var artworkPath: String?

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

        let element = currentElement.split(separator: ":").last.map(String.init) ?? currentElement
        switch element {
        case "title":
            title = title ?? value
        case "creator", "artist":
            artist = artist ?? value
        case "album":
            album = album ?? value
        case "albumarturi":
            artworkPath = artworkPath ?? value
        default:
            break
        }
    }
}

private final class SOAPResponseParser: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var currentText = ""

    private(set) var values: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
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
        if !value.isEmpty {
            values[elementName] = value
        }
        currentElement = ""
        currentText = ""
    }
}
