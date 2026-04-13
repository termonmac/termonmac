import Testing
import Foundation
@testable import RemoteDevCore

@Suite("Messages")
struct MessagesTests {

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    // MARK: - ServerMessage decode

    @Test("Decode room_registered")
    func decodeRoomRegistered() throws {
        let json = #"{"type":"room_registered","room_id":"ABC123"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .roomRegistered(let roomId, _) = msg else {
            Issue.record("Expected roomRegistered"); return
        }
        #expect(roomId == "ABC123")
    }

    @Test("Decode peer_joined")
    func decodePeerJoined() throws {
        let json = #"{"type":"peer_joined","public_key":"pk123","session_nonce":"n1","ephemeral_key":"ek1"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .peerJoined(let pk, let nonce, let ek) = msg else {
            Issue.record("Expected peerJoined"); return
        }
        #expect(pk == "pk123")
        #expect(nonce == "n1")
        #expect(ek == "ek1")
    }

    @Test("Decode peer_joined without session_nonce defaults to empty")
    func decodePeerJoinedNoNonce() throws {
        let json = #"{"type":"peer_joined","public_key":"pk"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .peerJoined(_, let nonce, let ek) = msg else {
            Issue.record("Expected peerJoined"); return
        }
        #expect(nonce == "")
        #expect(ek == "")
    }

    @Test("Decode relay")
    func decodeRelay() throws {
        let json = #"{"type":"relay","payload":"encrypted_data"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .relay(let payload) = msg else {
            Issue.record("Expected relay"); return
        }
        #expect(payload == "encrypted_data")
    }

    @Test("Decode relay_batch")
    func decodeRelayBatch() throws {
        let json = #"{"type":"relay_batch","payloads":["a","b","c"]}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .relayBatch(let payloads) = msg else {
            Issue.record("Expected relayBatch"); return
        }
        #expect(payloads == ["a", "b", "c"])
    }

    @Test("Decode peer_disconnected")
    func decodePeerDisconnected() throws {
        let json = #"{"type":"peer_disconnected","reason":"timeout"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .peerDisconnected(let reason) = msg else {
            Issue.record("Expected peerDisconnected"); return
        }
        #expect(reason == "timeout")
    }

    @Test("Decode heartbeat_ack")
    func decodeHeartbeatAck() throws {
        let json = #"{"type":"heartbeat_ack","mac_connected":true}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .heartbeatAck(let connected, let accountMatch, let accountDeleted) = msg else {
            Issue.record("Expected heartbeatAck"); return
        }
        #expect(connected == true)
        #expect(accountMatch == nil)
        #expect(accountDeleted == nil)
    }

    @Test("Decode heartbeat_ack with account_match")
    func decodeHeartbeatAckWithAccountMatch() throws {
        let json = #"{"type":"heartbeat_ack","mac_connected":true,"account_match":"mismatch"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .heartbeatAck(let connected, let accountMatch, let accountDeleted) = msg else {
            Issue.record("Expected heartbeatAck"); return
        }
        #expect(connected == true)
        #expect(accountMatch == "mismatch")
        #expect(accountDeleted == nil)
    }

    @Test("Decode heartbeat_ack with account_deleted")
    func decodeHeartbeatAckWithAccountDeleted() throws {
        let json = #"{"type":"heartbeat_ack","mac_connected":false,"account_deleted":true}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .heartbeatAck(let connected, _, let accountDeleted) = msg else {
            Issue.record("Expected heartbeatAck"); return
        }
        #expect(connected == false)
        #expect(accountDeleted == true)
    }

    @Test("Decode error")
    func decodeError() throws {
        let json = #"{"type":"error","code":"AUTH_FAILED","message":"bad secret"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .error(let code, let message, let macEmail, let iosEmail) = msg else {
            Issue.record("Expected error"); return
        }
        #expect(code == "AUTH_FAILED")
        #expect(message == "bad secret")
        #expect(macEmail == nil)
        #expect(iosEmail == nil)
    }

    @Test("Decode error with emails")
    func decodeErrorWithEmails() throws {
        let json = #"{"type":"error","code":"ACCOUNT_MISMATCH","message":"mismatch","mac_email":"mac@test.com","ios_email":"ios@test.com"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .error(let code, _, let macEmail, let iosEmail) = msg else {
            Issue.record("Expected error"); return
        }
        #expect(code == "ACCOUNT_MISMATCH")
        #expect(macEmail == "mac@test.com")
        #expect(iosEmail == "ios@test.com")
    }

    @Test("Unknown ServerMessage type throws")
    func unknownServerMessage() {
        let json = #"{"type":"never_seen_before","foo":"bar"}"#
        #expect(throws: DecodingError.self) {
            try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        }
    }

    // MARK: - AppMessage encode/decode round-trip

    @Test("challenge round-trip")
    func challengeRoundTrip() throws {
        let msg = AppMessage.challenge(nonce: "abc123")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .challenge(let nonce) = decoded else {
            Issue.record("Expected challenge"); return
        }
        #expect(nonce == "abc123")
    }

    @Test("challengeResponse round-trip")
    func challengeResponseRoundTrip() throws {
        let msg = AppMessage.challengeResponse(hmac: "hmac_value")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .challengeResponse(let hmac) = decoded else {
            Issue.record("Expected challengeResponse"); return
        }
        #expect(hmac == "hmac_value")
    }

    @Test("authOk round-trip")
    func authOkRoundTrip() throws {
        let msg = AppMessage.authOk
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .authOk = decoded else {
            Issue.record("Expected authOk"); return
        }
    }

    @Test("ptyData round-trip")
    func ptyDataRoundTrip() throws {
        let msg = AppMessage.ptyData(data: "base64data", sessionId: "s1", offset: 42)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .ptyData(let d, let sid, let offset) = decoded else {
            Issue.record("Expected ptyData"); return
        }
        #expect(d == "base64data")
        #expect(sid == "s1")
        #expect(offset == 42)
    }

    @Test("ptyInput round-trip")
    func ptyInputRoundTrip() throws {
        let msg = AppMessage.ptyInput(data: "input_b64", sessionId: "s2")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .ptyInput(let d, let sid) = decoded else {
            Issue.record("Expected ptyInput"); return
        }
        #expect(d == "input_b64")
        #expect(sid == "s2")
    }

    @Test("ptySessions round-trip")
    func ptySessionsRoundTrip() throws {
        let sessions = [
            PTYSessionInfo(sessionId: "s1", name: "zsh-1", cols: 80, rows: 24, cwd: "/tmp"),
            PTYSessionInfo(sessionId: "s2", name: "zsh-2", cols: 120, rows: 40)
        ]
        let msg = AppMessage.ptySessions(sessions: sessions)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .ptySessions(let s) = decoded else {
            Issue.record("Expected ptySessions"); return
        }
        #expect(s.count == 2)
        #expect(s[0].sessionId == "s1")
        #expect(s[0].cwd == "/tmp")
        #expect(s[1].cols == 120)
    }

    @Test("ptyCreate round-trip")
    func ptyCreateRoundTrip() throws {
        let msg = AppMessage.ptyCreate(sessionId: "s1", name: "zsh-1", cols: 100, rows: 50, workDir: "/home")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .ptyCreate(let sid, let name, let cols, let rows, let wd) = decoded else {
            Issue.record("Expected ptyCreate"); return
        }
        #expect(sid == "s1")
        #expect(name == "zsh-1")
        #expect(cols == 100)
        #expect(rows == 50)
        #expect(wd == "/home")
    }


    @Test("buildStatus round-trip with optional fields")
    func buildStatusRoundTrip() throws {
        let msg = AppMessage.buildStatus(
            status: "building", message: "Step 1/3",
            branch: "main", commit: "abc123",
            action: "build", pipelineSteps: ["build", "archive"], pipelineCurrentIndex: 0
        )
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .buildStatus(let status, let message, let branch, let commit, let action, let steps, let idx) = decoded else {
            Issue.record("Expected buildStatus"); return
        }
        #expect(status == "building")
        #expect(message == "Step 1/3")
        #expect(branch == "main")
        #expect(commit == "abc123")
        #expect(action == "build")
        #expect(steps == ["build", "archive"])
        #expect(idx == 0)
    }

    @Test("gitDetectResult round-trip")
    func gitDetectResultRoundTrip() throws {
        let info = GitDetectInfo(isGitRepo: true, isWorktree: false, branchName: "main", remoteUrl: nil, repoRootPath: "/repo")
        let msg = AppMessage.gitDetectResult(sessionId: "s1", info: info)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .gitDetectResult(let sid, let i) = decoded else {
            Issue.record("Expected gitDetectResult"); return
        }
        #expect(sid == "s1")
        #expect(i.isGitRepo == true)
        #expect(i.branchName == "main")
    }

    @Test("roomConfig round-trip")
    func roomConfigRoundTrip() throws {
        let config = RoomConfig(sessions: [
            RoomSessionConfig(sessionId: "s1", name: "zsh-1", selectedTab: 0)
        ], activeSessionId: "s1")
        let msg = AppMessage.roomConfig(config: config)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .roomConfig(let c) = decoded else {
            Issue.record("Expected roomConfig"); return
        }
        #expect(c.sessions.count == 1)
        #expect(c.activeSessionId == "s1")
    }

    // MARK: - Unknown AppMessage type

    @Test("Unknown AppMessage type decodes to .unknown")
    func unknownAppMessage() throws {
        let json = #"{"type":"future_feature_xyz","foo":"bar"}"#
        let msg = try decoder.decode(AppMessage.self, from: Data(json.utf8))
        guard case .unknown = msg else {
            Issue.record("Expected unknown"); return
        }
    }

    @Test("buildReplay round-trip with stepStatuses")
    func buildReplayWithStepStatuses() throws {
        let stepStatuses = ["build": "succeeded", "archive": "running", "upload": "pending"]
        let msg = AppMessage.buildReplay(
            data: "b64data", status: "running", message: "Archiving...",
            action: "archive", branch: "main", commit: "abc",
            pipelineSteps: ["build", "archive", "upload"],
            pipelineCurrentIndex: 1, stepStatuses: stepStatuses
        )
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .buildReplay(_, let status, _, _, _, _, let steps, let idx, let ss) = decoded else {
            Issue.record("Expected buildReplay"); return
        }
        #expect(status == "running")
        #expect(steps == ["build", "archive", "upload"])
        #expect(idx == 1)
        #expect(ss == stepStatuses)
    }

    @Test("buildReplay round-trip without stepStatuses")
    func buildReplayWithoutStepStatuses() throws {
        let msg = AppMessage.buildReplay(
            data: "b64data", status: "succeeded", message: "Done",
            action: "build", branch: nil, commit: nil,
            pipelineSteps: nil, pipelineCurrentIndex: nil
        )
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .buildReplay(_, _, _, _, _, _, _, _, let ss) = decoded else {
            Issue.record("Expected buildReplay"); return
        }
        #expect(ss == nil)
    }

    @Test("pipelineStateQuery round-trip")
    func pipelineStateQueryRoundTrip() throws {
        let msg = AppMessage.pipelineStateQuery
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .pipelineStateQuery = decoded else {
            Issue.record("Expected pipelineStateQuery"); return
        }
    }

    @Test("pipelineStateResponse round-trip with state")
    func pipelineStateResponseWithState() throws {
        let state = PipelineState(
            steps: ["build", "archive", "upload"],
            currentIndex: 1,
            overallStatus: "running",
            stepStatuses: ["build": "succeeded", "archive": "running", "upload": "pending"]
        )
        let msg = AppMessage.pipelineStateResponse(state: state)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .pipelineStateResponse(let s) = decoded else {
            Issue.record("Expected pipelineStateResponse"); return
        }
        #expect(s != nil)
        #expect(s?.steps == ["build", "archive", "upload"])
        #expect(s?.currentIndex == 1)
        #expect(s?.overallStatus == "running")
        #expect(s?.stepStatuses == ["build": "succeeded", "archive": "running", "upload": "pending"])
    }

    @Test("pipelineStateResponse round-trip with nil state")
    func pipelineStateResponseNil() throws {
        let msg = AppMessage.pipelineStateResponse(state: nil)
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .pipelineStateResponse(let s) = decoded else {
            Issue.record("Expected pipelineStateResponse"); return
        }
        #expect(s == nil)
    }

    @Test("PipelineState stepStatuses defaults to all pending")
    func pipelineStateDefaultStepStatuses() {
        let state = PipelineState(steps: ["build", "archive"], currentIndex: 0, overallStatus: "running")
        #expect(state.stepStatuses == ["build": "pending", "archive": "pending"])
    }

    @Test("PipelineState with explicit stepStatuses preserves them")
    func pipelineStateExplicitStepStatuses() {
        let statuses = ["build": "succeeded", "archive": "failed"]
        let state = PipelineState(steps: ["build", "archive"], currentIndex: 1, overallStatus: "failed", stepStatuses: statuses)
        #expect(state.stepStatuses == statuses)
    }

    @Test("PipelineState encode/decode round-trip preserves stepStatuses")
    func pipelineStateCodeableRoundTrip() throws {
        let state = PipelineState(
            steps: ["build", "archive", "upload"],
            currentIndex: 2,
            overallStatus: "succeeded",
            stepStatuses: ["build": "succeeded", "archive": "succeeded", "upload": "succeeded"]
        )
        let data = try encoder.encode(state)
        let decoded = try decoder.decode(PipelineState.self, from: data)
        #expect(decoded.steps == state.steps)
        #expect(decoded.currentIndex == state.currentIndex)
        #expect(decoded.overallStatus == state.overallStatus)
        #expect(decoded.stepStatuses == state.stepStatuses)
    }

    @Test("dirListResponse round-trip")
    func dirListResponseRoundTrip() throws {
        let msg = AppMessage.dirListResponse(path: "/home", dirs: ["a", "b", "c"])
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .dirListResponse(let path, let dirs) = decoded else {
            Issue.record("Expected dirListResponse"); return
        }
        #expect(path == "/home")
        #expect(dirs == ["a", "b", "c"])
    }

    @Test("ptyCreateFailed round-trip")
    func ptyCreateFailedRoundTrip() throws {
        let msg = AppMessage.ptyCreateFailed(sessionId: "s1", reason: "Session limit reached (4)")
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(AppMessage.self, from: data)
        guard case .ptyCreateFailed(let sid, let reason) = decoded else {
            Issue.record("Expected ptyCreateFailed"); return
        }
        #expect(sid == "s1")
        #expect(reason == "Session limit reached (4)")
    }

    @Test("Decode room_registered with max_sessions")
    func decodeRoomRegisteredWithMaxSessions() throws {
        let json = #"{"type":"room_registered","room_id":"R1","max_sessions":32}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .roomRegistered(let roomId, let maxSessions) = msg else {
            Issue.record("Expected roomRegistered"); return
        }
        #expect(roomId == "R1")
        #expect(maxSessions == 32)
    }

    @Test("Decode room_registered without max_sessions")
    func decodeRoomRegisteredWithoutMaxSessions() throws {
        let json = #"{"type":"room_registered","room_id":"R2"}"#
        let msg = try decoder.decode(ServerMessage.self, from: Data(json.utf8))
        guard case .roomRegistered(let roomId, let maxSessions) = msg else {
            Issue.record("Expected roomRegistered"); return
        }
        #expect(roomId == "R2")
        #expect(maxSessions == nil)
    }
}
