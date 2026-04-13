import Foundation
import RemoteDevCore

public struct TokenRefreshResult: Sendable {
    public let apiKey: String
    public let refreshToken: String
}

/// Refresh an API key using the relay's /auth/refresh endpoint.
///
/// Retries all non-200 responses (including 401) with capped exponential
/// backoff. CF KV reads can transiently return null, causing the relay to
/// reply 401 even though the token is still valid.
///
/// Returns nil if all retries are exhausted or the Task is cancelled.
public func refreshAPIKey(
    serverURL: String,
    refreshToken: String,
    configDir: String,
    sandboxKey: String? = nil,
    maxAttempts: Int = 10
) async -> TokenRefreshResult? {
    let httpURL = serverURL
        .replacingOccurrences(of: "wss://", with: "https://")
        .replacingOccurrences(of: "ws://", with: "http://")
    guard let url = URL(string: "\(httpURL)/auth/refresh") else { return nil }

    // ~5 min with 60s cap: 1+2+4+8+16+32+60+60+60+60
    for attempt in 1...maxAttempts {
        guard !Task.isCancelled else { break }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let sandboxKey, !sandboxKey.isEmpty {
            request.setValue(sandboxKey, forHTTPHeaderField: "X-Sandbox-Key")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else { continue }

            guard httpResp.statusCode == 200 else {
                let delay = min(pow(2.0, Double(attempt - 1)), 60)
                log("[auth] refresh attempt \(attempt) got HTTP \(httpResp.statusCode), retrying in \(Int(delay))s")
                try await Task.sleep(for: .seconds(delay))
                continue
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newApiKey = json["api_key"] as? String,
                  let newRefreshToken = json["refresh_token"] as? String else {
                return nil
            }

            // Save new tokens to disk
            let fm = FileManager.default
            if !fm.fileExists(atPath: configDir) {
                try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
            }
            do {
                try newApiKey.write(toFile: configDir + "/api_key", atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configDir + "/api_key")
                try newRefreshToken.write(toFile: configDir + "/refresh_token", atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configDir + "/refresh_token")
            } catch {
                log("[auth] refresh succeeded but failed to persist tokens: \(error.localizedDescription)")
                return nil
            }
            log("[auth] saved refreshed tokens to \(configDir)")
            return TokenRefreshResult(apiKey: newApiKey, refreshToken: newRefreshToken)
        } catch {
            if Task.isCancelled { break }
            let delay = min(pow(2.0, Double(attempt - 1)), 60)
            log("[auth] refresh attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription), retrying in \(Int(delay))s")
            try? await Task.sleep(for: .seconds(delay))
        }
    }
    if Task.isCancelled {
        log("[auth] refresh loop cancelled")
    } else {
        log("[auth] all \(maxAttempts) refresh attempts exhausted")
    }
    return nil
}
