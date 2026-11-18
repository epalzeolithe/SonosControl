import AppKit
import SwiftUI

struct ContentView: View {
    @State private var groups: [SonosGroup] = []
    @State private var selectedGroupID: SonosGroup.ID?
    @State private var playbackState = SonosPlaybackState.unknown
    @State private var trackInfo: SonosTrackInfo?
    @State private var volume = 0.0
    @State private var isMuted = false
    @State private var memberVolumes: [SonosDevice.ID: Double] = [:]
    @State private var isSearching = false
    @State private var isLoadingPlayer = false
    @State private var isSendingCommand = false
    @State private var isChangingGroups = false
    @State private var discoveryError: String?
    @State private var controlError: String?
    @State private var launchAtLogin = false
    @State private var launchAtLoginRequiresApproval = false
    @State private var launchAtLoginError = ""
    @State private var showsLaunchAtLoginError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mainContent
            Divider()
            footer
        }
        .frame(width: 360)
        .task {
            refreshLaunchAtLoginStatus()
            await loadInitialState()
        }
        .alert(
            "Lancement à l’ouverture de session",
            isPresented: $showsLaunchAtLoginError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(launchAtLoginError)
        }
    }

    private var selectedGroup: SonosGroup? {
        groups.first { $0.id == selectedGroupID }
    }

    private var header: some View {
        HStack {
            Label("Sonos Control", systemImage: "hifispeaker.2.fill")
                .font(.headline)

            Spacer()

            if let selectedGroup {
                if isChangingGroups {
                    ProgressView()
                        .controlSize(.small)
                        .help("Modification des groupes en cours")
                } else {
                    if groups.count > 1 {
                        Button {
                            Task { await groupAll(into: selectedGroup) }
                        } label: {
                            Label("Tout regrouper", systemImage: "rectangle.3.group.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSendingCommand)
                        .help("Tout regrouper dans « \(selectedGroup.name) »")
                    }

                    if selectedGroup.members.count > 1 {
                        Button {
                            Task { await ungroup(selectedGroup) }
                        } label: {
                            Label("Dégrouper", systemImage: "arrow.up.left.and.arrow.down.right")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSendingCommand)
                        .help("Dégrouper « \(selectedGroup.name) »")
                    }
                }
            }

            if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await search() }
                } label: {
                    Label("Actualiser les groupes", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Actualiser les groupes")
            }
        }
        .padding()
    }

    @ViewBuilder
    private var mainContent: some View {
        if groups.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                groupList
                Divider()

                if let selectedGroup {
                    playerControls(for: selectedGroup)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                isSearching ? "Recherche en cours" : "Aucun groupe",
                systemImage: isSearching ? "wifi" : "wifi.slash"
            )
        } description: {
            if let discoveryError {
                Text(discoveryError)
            } else if !isSearching {
                Text("Vérifiez que le Mac et les enceintes Sonos utilisent le même réseau.")
            }
        } actions: {
            if !isSearching {
                Button("Rechercher") {
                    Task { await search() }
                }
            }
        }
        .frame(minHeight: 230)
        .padding(.horizontal)
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(groups) { group in
                    Button {
                        select(group)
                    } label: {
                        GroupRow(
                            group: group,
                            isSelected: group.id == selectedGroupID
                        )
                    }
                    .buttonStyle(.plain)

                    if group.id != groups.last?.id {
                        Divider()
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .frame(minHeight: 120, maxHeight: 260)
    }

    private func playerControls(for group: SonosGroup) -> some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline)
                    Text("Coordinateur : \(group.coordinator.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if isLoadingPlayer {
                ProgressView("Connexion au groupe…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                if let trackInfo {
                    NowPlayingView(track: trackInfo)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await togglePlayback(in: group) }
                    } label: {
                        Image(systemName: playbackState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(isSendingCommand || isChangingGroups)
                    .help(playbackState.isPlaying ? "Pause" : "Lecture")

                    VStack(spacing: 6) {
                        HStack {
                            Slider(
                                value: $volume,
                                in: 0...100,
                                step: 1,
                                onEditingChanged: { isEditing in
                                    if !isEditing {
                                        Task { await applyVolume(in: group) }
                                    }
                                }
                            )
                            .disabled(isSendingCommand || isChangingGroups)
                            .accessibilityLabel("Volume du groupe")

                            Text(volume, format: .number.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .frame(width: 28, alignment: .trailing)
                        }

                        HStack(spacing: 14) {
                            Button {
                                Task { await toggleMute(in: group) }
                            } label: {
                                Label(
                                    isMuted ? "Réactiver le son" : "Couper le son",
                                    systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                                )
                                .labelStyle(.iconOnly)
                                .frame(width: 12, height: 12)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.circle)
                            .controlSize(.small)
                            .disabled(isSendingCommand || isChangingGroups)
                            .help(isMuted ? "Réactiver le son" : "Couper le son")

                            Button {
                                adjustVolume(by: -1, in: group)
                            } label: {
                                Image(systemName: "minus")
                                    .frame(width: 24, height: 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .accessibilityLabel("Baisser le volume")
                            .disabled(isSendingCommand || isChangingGroups || volume <= 0)
                            .help("Baisser le volume")

                            Button {
                                adjustVolume(by: 1, in: group)
                            } label: {
                                Image(systemName: "plus")
                                    .frame(width: 24, height: 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .accessibilityLabel("Augmenter le volume")
                            .disabled(isSendingCommand || isChangingGroups || volume >= 100)
                            .help("Augmenter le volume")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if group.members.count > 1 {
                    Divider()
                    memberVolumeControls(for: group)
                }

                if let controlError {
                    Text(controlError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
    }

    private func memberVolumeControls(for group: SonosGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volumes individuels")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(group.members) { member in
                HStack(spacing: 8) {
                    Text(member.name)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(width: 88, alignment: .leading)

                    Slider(
                        value: memberVolumeBinding(for: member),
                        in: 0...100,
                        step: 1,
                        onEditingChanged: { isEditing in
                            if !isEditing {
                                Task { await applyVolume(to: member) }
                            }
                        }
                    )
                    .disabled(isSendingCommand || isChangingGroups)
                    .accessibilityLabel("Volume de \(member.name)")

                    Text(
                        memberVolumes[member.id] ?? volume,
                        format: .number.precision(.fractionLength(0))
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
                }
            }
        }
    }

    private func memberVolumeBinding(for member: SonosDevice) -> Binding<Double> {
        Binding(
            get: { memberVolumes[member.id] ?? volume },
            set: { memberVolumes[member.id] = $0 }
        )
    }

    private var footer: some View {
        HStack {
            Text(groupCountLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Menu {
                Button {
                    updateLaunchAtLogin(!launchAtLogin)
                } label: {
                    Text(
                        launchAtLogin
                            ? "✓  Lancer à l’ouverture de session"
                            : "   Lancer à l’ouverture de session"
                    )
                }

                if launchAtLoginRequiresApproval {
                    Divider()

                    Button("Autoriser dans Réglages Système…") {
                        LaunchAtLoginService.openSystemSettings()
                    }
                }
            } label: {
                Label("Options", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .help("Options")

            Button("Quitter") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
    }

    private var groupCountLabel: String {
        switch groups.count {
        case 0:
            "Réseau local"
        case 1:
            "1 groupe"
        default:
            "\(groups.count) groupes"
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLogin = LaunchAtLoginService.isEnabled
        launchAtLoginRequiresApproval = LaunchAtLoginService.requiresApproval
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        let previousValue = launchAtLogin
        launchAtLogin = enabled

        do {
            try LaunchAtLoginService.setEnabled(enabled)
            launchAtLoginRequiresApproval = LaunchAtLoginService.requiresApproval

            Task {
                try? await Task.sleep(for: .milliseconds(400))
                refreshLaunchAtLoginStatus()
            }
        } catch {
            launchAtLogin = previousValue
            refreshLaunchAtLoginStatus()
            launchAtLoginError = error.localizedDescription
            showsLaunchAtLoginError = true
        }
    }

    private func loadInitialState() async {
        let cachedDevices = SonosDeviceCache.load()
        guard !cachedDevices.isEmpty else {
            await search()
            return
        }

        isSearching = true
        do {
            let cachedGroups = try await SonosTopologyService.groups(from: cachedDevices)
            guard !cachedGroups.isEmpty else {
                throw SonosTopologyError.missingTopology
            }

            groups = cachedGroups
            SonosDeviceCache.save(cachedGroups.flatMap(\.members))

            if let groupToSelect = await preferredGroup(in: cachedGroups) {
                selectedGroupID = groupToSelect.id
                await refreshPlayer(for: groupToSelect)
            }
            isSearching = false
        } catch {
            isSearching = false
            await search()
        }
    }

    private func search() async {
        guard !isSearching else { return }

        isSearching = true
        discoveryError = nil
        controlError = nil

        do {
            let devices = try await SonosDiscoveryService.discover()

            if devices.isEmpty {
                groups = []
                selectedGroupID = nil
            } else {
                do {
                    groups = try await SonosTopologyService.groups(from: devices)
                } catch {
                    groups = devices.map {
                        SonosGroup(id: $0.id, coordinator: $0, members: [$0])
                    }
                    discoveryError = "Les enceintes sont visibles, mais leurs groupes n’ont pas pu être lus."
                }

                if groups.isEmpty {
                    groups = devices.map {
                        SonosGroup(id: $0.id, coordinator: $0, members: [$0])
                    }
                }

                SonosDeviceCache.save(groups.flatMap(\.members))

                if let groupToSelect = await preferredGroup(in: groups) {
                    selectedGroupID = groupToSelect.id
                    await refreshPlayer(for: groupToSelect)
                }
            }
        } catch {
            groups = []
            selectedGroupID = nil
            discoveryError = error.localizedDescription
        }

        isSearching = false
    }

    private func preferredGroup(in availableGroups: [SonosGroup]) async -> SonosGroup? {
        let playingGroupIDs = await withTaskGroup(of: SonosGroup.ID?.self) { taskGroup in
            for group in availableGroups {
                taskGroup.addTask {
                    await SonosControlService.isPlaying(group.coordinator)
                        ? group.id
                        : nil
                }
            }

            var identifiers = Set<SonosGroup.ID>()
            for await identifier in taskGroup {
                if let identifier {
                    identifiers.insert(identifier)
                }
            }
            return identifiers
        }

        if let playingGroup = availableGroups.first(where: {
            playingGroupIDs.contains($0.id)
        }) {
            return playingGroup
        }

        return availableGroups.first {
            $0.id == selectedGroupID
        } ?? availableGroups.first
    }

    private func select(_ group: SonosGroup) {
        guard selectedGroupID != group.id else { return }
        selectedGroupID = group.id
        Task { await refreshPlayer(for: group) }
    }

    private func refreshPlayer(for group: SonosGroup) async {
        isLoadingPlayer = true
        trackInfo = nil
        memberVolumes = [:]
        controlError = nil

        do {
            async let status = SonosControlService.status(for: group.coordinator)
            async let loadedMemberVolumes = loadMemberVolumes(for: group)

            let playerStatus = try await status
            let volumesByMember = await loadedMemberVolumes
            guard selectedGroupID == group.id else { return }

            playbackState = playerStatus.playbackState
            trackInfo = playerStatus.track
            volume = playerStatus.volume
            isMuted = playerStatus.isMuted
            memberVolumes = volumesByMember
        } catch {
            guard selectedGroupID == group.id else { return }
            controlError = error.localizedDescription
        }

        if selectedGroupID == group.id {
            isLoadingPlayer = false
        }
    }

    private func loadMemberVolumes(
        for group: SonosGroup
    ) async -> [SonosDevice.ID: Double] {
        await withTaskGroup(of: (SonosDevice.ID, Double?).self) { taskGroup in
            for member in group.members {
                taskGroup.addTask {
                    let volume = try? await SonosControlService.deviceVolume(for: member)
                    return (member.id, volume)
                }
            }

            var volumes: [SonosDevice.ID: Double] = [:]
            for await (identifier, volume) in taskGroup {
                if let volume {
                    volumes[identifier] = volume
                }
            }
            return volumes
        }
    }

    private func applyVolume(to member: SonosDevice) async {
        guard !isSendingCommand,
              let memberVolume = memberVolumes[member.id] else {
            return
        }

        isSendingCommand = true
        controlError = nil

        do {
            try await SonosControlService.setDeviceVolume(memberVolume, on: member)
        } catch {
            controlError = error.localizedDescription
        }

        isSendingCommand = false
    }

    private func togglePlayback(in group: SonosGroup) async {
        guard !isSendingCommand else { return }
        isSendingCommand = true
        controlError = nil

        do {
            if playbackState.isPlaying {
                try await SonosControlService.pause(group.coordinator)
                playbackState = .paused
            } else {
                try await SonosControlService.play(group.coordinator)
                playbackState = .playing
            }
        } catch {
            controlError = error.localizedDescription
        }

        isSendingCommand = false
    }

    private func adjustVolume(by amount: Double, in group: SonosGroup) {
        guard !isSendingCommand else { return }
        let adjustedVolume = min(max(volume + amount, 0), 100)
        volume = adjustedVolume
        Task { await applyVolume(adjustedVolume, in: group) }
    }

    private func toggleMute(in group: SonosGroup) async {
        guard !isSendingCommand else { return }
        isSendingCommand = true
        controlError = nil

        let newValue = !isMuted
        do {
            try await SonosControlService.setMuted(newValue, on: group.coordinator)
            isMuted = newValue
        } catch {
            controlError = error.localizedDescription
        }

        isSendingCommand = false
    }

    private func ungroup(_ group: SonosGroup) async {
        guard !isChangingGroups else { return }

        isChangingGroups = true
        controlError = nil

        do {
            try await SonosControlService.ungroup(
                group.members,
                keeping: group.coordinator
            )
            try? await Task.sleep(for: .milliseconds(1_500))
            isChangingGroups = false
            await search()
        } catch {
            controlError = error.localizedDescription
            isChangingGroups = false
        }
    }

    private func groupAll(into targetGroup: SonosGroup) async {
        guard !isChangingGroups else { return }

        isChangingGroups = true
        controlError = nil

        var devicesByID: [SonosDevice.ID: SonosDevice] = [:]
        for group in groups where group.id != targetGroup.id {
            for member in group.members {
                devicesByID[member.id] = member
            }
        }

        do {
            try await SonosControlService.group(
                Array(devicesByID.values),
                with: targetGroup.coordinator
            )
            try? await Task.sleep(for: .milliseconds(1_500))
            isChangingGroups = false
            await search()
        } catch {
            controlError = error.localizedDescription
            isChangingGroups = false
        }
    }

    private func applyVolume(_ requestedVolume: Double? = nil, in group: SonosGroup) async {
        guard !isSendingCommand else { return }
        isSendingCommand = true
        controlError = nil

        do {
            try await SonosControlService.setVolume(
                requestedVolume ?? volume,
                on: group.coordinator
            )
            try? await Task.sleep(for: .milliseconds(150))

            let updatedVolumes = await loadMemberVolumes(for: group)
            if selectedGroupID == group.id {
                memberVolumes = updatedVolumes
            }
        } catch {
            controlError = error.localizedDescription
        }

        isSendingCommand = false
    }
}

private struct NowPlayingView: View {
    let track: SonosTrackInfo

    private var artworkRequest: URLRequest? {
        guard let artworkURL = track.artworkURL else { return nil }
        var request = URLRequest(url: artworkURL)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 5
        return request
    }

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(request: artworkRequest) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 64, height: 64)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .clipShape(.rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)

                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let album = track.album {
                    Text(album)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artworkPlaceholder: some View {
        Image(systemName: "music.note")
            .font(.title2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GroupRow: View {
    let group: SonosGroup
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill")
                .font(.title2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(.rect)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

#Preview {
    ContentView()
}
