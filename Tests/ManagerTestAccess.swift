// Appended to a temporary copy of NetworkDiscovery.swift for test compilation only.
extension NetworkDiscovery {
    func testStartBackupOSC() {
        runtimeRole = .backup
        cachedQLabPasscode = "1515"
        connectedWorkspace = "Fixture.qlab5"
        refreshLocalQLabState()
        startQLabOSCMonitoring(workspace: "Fixture")
    }
    func testCurrentClient() -> QLabOSCClient? { qlabOSCClient }
}
extension NetworkDiscovery {
    func testAttachBackup(_ connection: NWConnection) {
        activeConnection = connection
        connectedSessionID = "TEST-SESSION"
        connectedWorkspace = "Fixture.qlab5"
        isConnected = true
        workspaceTransferReady = true
        workspaceTransferInProgress = false
        let now = ProcessInfo.processInfo.systemUptime
        _ = eventClock.calibrate(sent: now - 0.001, received: now + 0.001, remote: now)
        receiveWelcome(on: connection)
    }
    func testAttachMaster(_ connection: NWConnection) {
        runtimeRole = .master; activeConnection = connection; isConnected = true
        masterSessionID = "TEST-SESSION"
        workspaceTransferReady = true
        receiveBackupMessages(on: connection)
        startHeartbeat(on: connection, sessionID: masterSessionID)
    }
    func testSendGo() { sendMasterEvent(type: "GO", cueID: "CAKE-ID") }
    func testFrame(_ frame: [String: Any]) { sendJSON(frame, on: activeConnection!) }
    func testDisconnect() { activeConnection?.cancel(); activeConnection = nil }
}
extension NetworkDiscovery {
    func testStartNamedBackupOSC(_ name: String, passcode: String = "1515") {
        runtimeRole = .backup; cachedQLabPasscode = passcode
        connectedWorkspace = name + ".qlab5"
        refreshLocalQLabState()
        startQLabOSCMonitoring(workspace: name)
    }
}
extension NetworkDiscovery {
    func testApplyInitial(_ connection: NWConnection, workspace: URL, manifest: MirrorManifest, mediaRoot: URL) {
        activeConnection = connection
        workspaceTransferID = UUID().uuidString
        workspaceTransferInProgress = true
        workspaceTransferReady = false
        confirmInitialWorkspaceApplication(workspaceURL: workspace, manifest: manifest, mediaRoot: mediaRoot)
    }
}

extension NetworkDiscovery {
    func testValidateIdentity(_ id: String) { validatedInitialWorkspaceID = id; refreshLocalQLabState() }
    func testInvalidateCachedMatch() { localQLabWorkspaceMatchesMaster = false }
}
extension NetworkDiscovery {
    func testMirrorGo(_ cueID: String) { mirrorHotStandbyEvent(eventType: "GO", cueID: cueID) }
}

extension NetworkDiscovery {
    func testMirrorCanReload() -> Bool { liveMirror.context().canReload }
    func testConfigureMirror(session: String, root: String, cache: URL, revisions: URL, playhead: String) -> LiveMirrorEngine {
        liveMirror.stop()
        isConnected = true
        connectedSessionID = session
        workspaceTransferDestinationPath = root
        backupTargetPlayheadID = playhead
        liveMirror.workspaceSignature = { try MirrorFiles.hashFile(URL(fileURLWithPath: $0)) }
        liveMirror.cacheOverride = cache
        liveMirror.revisionsOverride = revisions
        return liveMirror
    }
    func testLoseMaster() { markLinkLost(reason: "Test isolated peer loss") }
}

extension NetworkDiscovery {
    func testStartMasterOSC() {
        runtimeRole = .master; cachedQLabPasscode = "1515"
        startQLabOSCMonitoring(workspace: "Fixture")
    }
    func testRecoveryMonitoring() { recoveryIO.persist = false; startRecoveryMonitor() }
    func testObserveSelection(_ cue: String) { qlabOSCClient?.onPlayheadEvent?(cue) }
}

extension NetworkDiscovery {
    func testMatchSession(_ session: String) {
        masterSessionID = session
        if let connection = activeConnection { startHeartbeat(on: connection, sessionID: session) }
    }
}

extension NetworkDiscovery {
    func testReconnectBackup(_ connection: NWConnection) {
        activeConnection = connection; isConnected = false; receiveBuffer.removeAll()
        receiveWelcome(on: connection)
    }
}


extension NetworkDiscovery {
    func testHeartbeatMonitor(age: TimeInterval = 0, transferring: Bool = false) {
        runtimeRole = .backup; isConnected = true; connectedSessionID = "TEST"
        lastHeartbeatAt = Date().addingTimeInterval(-age)
        workspaceTransferInProgress = transferring
        startHeartbeatMonitor()
    }
}


extension NetworkDiscovery {
    func testNetworkParameters() throws -> NWParameters { try networkParameters() }
}

extension NetworkDiscovery {
    func testBinaryArchive(_ archive: URL, size: Int64, hash: String) {
        let id = UUID().uuidString
        workspaceTransferID = id; workspaceTransferCancelled = false
        workspaceTransferInProgress = true; workspaceTransferReady = false
        workspaceTransferArchiveURL = archive; workspaceTransferTotalBytes = size
        workspaceTransferError = nil
        startBinaryWorkspaceSend(archive: archive, size: size, sourceSize: size,
            hash: hash, projectName: "Temporary test only", transferID: id, connection: activeConnection!)
    }
}
