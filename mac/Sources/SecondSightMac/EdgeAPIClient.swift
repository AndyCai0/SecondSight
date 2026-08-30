import Foundation
import SecondSightCore

final class EdgeAPIClient: @unchecked Sendable {
    enum ClientError: LocalizedError {
        case invalidResponse
        case server(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                localized(
                    "服务器返回了无法识别的数据。",
                    "The server returned an invalid response.",
                    for: .savedOrSystemDefault
                )
            case let .server(status, message):
                localized(
                    "服务器错误（\(status)）：\(message)",
                    "Server error (\(status)): \(message)",
                    for: .savedOrSystemDefault
                )
            }
        }
    }

    private let configuration: AppConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: AppConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func createSession() async throws -> CreateSessionResponse {
        try await post(path: "create-session", body: EmptyRequest(), response: CreateSessionResponse.self)
    }

    func setSessionBroadcast(_ request: BroadcastSessionRequest) async throws -> BroadcastSessionResponse {
        let response = try await post(
            path: "broadcast-session",
            body: request,
            response: BroadcastSessionResponse.self
        )
        guard response.ok else { throw ClientError.invalidResponse }
        return response
    }

    func requestGuide(
        _ request: AIGuideRequest,
        elderCredential: String
    ) async throws -> AIGuideResponse {
        try await post(
            path: "ai-guide",
            body: request,
            response: AIGuideResponse.self,
            additionalHeaders: ["x-secondsight-elder-token": elderCredential]
        )
    }

    func analyzeSafety(
        _ request: AISafetyAnalysisRequest,
        elderCredential: String
    ) async throws -> AISafetyAnalysisResponse {
        try await post(
            path: "ai-referee",
            body: request,
            response: AISafetyAnalysisResponse.self,
            additionalHeaders: ["x-secondsight-elder-token": elderCredential]
        )
    }

    func createAssemblyAIStreamingCredential(
        sessionID: UUID,
        elderCredential: String
    ) async throws -> AssemblyAIStreamingCredential {
        try await post(
            path: "assemblyai-token",
            body: AssemblyAITokenRequest(sessionID: sessionID),
            response: AssemblyAIStreamingCredential.self,
            additionalHeaders: ["x-secondsight-elder-token": elderCredential]
        )
    }

    func recordRiskEvent(
        _ request: RiskEventRequest,
        elderCredential: String
    ) async throws -> RiskEventResponse {
        try await post(
            path: "risk-event",
            body: request,
            response: RiskEventResponse.self,
            additionalHeaders: ["x-secondsight-elder-token": elderCredential]
        )
    }

    func logEvent(_ request: LogEventRequest) async {
        _ = try? await post(path: "log-event", body: request, response: LogEventResponse.self)
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        response: Response.Type,
        additionalHeaders: [String: String] = [:]
    ) async throws -> Response {
        var url = configuration.supabaseURL
        url.append(path: "functions")
        url.append(path: "v1")
        url.append(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try encoder.encode(body)
        request.timeoutInterval = 15

        let (data, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? decoder.decode(APIErrorResponse.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? localized("未知错误", "Unknown error", for: .savedOrSystemDefault)
            throw ClientError.server(status: http.statusCode, message: message)
        }
        do { return try decoder.decode(Response.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }
}

private struct EmptyRequest: Encodable {}
private struct LogEventResponse: Decodable { let ok: Bool }
