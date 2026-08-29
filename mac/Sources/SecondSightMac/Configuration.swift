import Foundation

struct AppConfiguration: Sendable {
    let supabaseURL: URL
    let supabaseAnonKey: String

    enum ConfigurationError: LocalizedError {
        case missing
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .missing: "还没有配置 Supabase。请复制 Config.template.plist 为 Config.plist 并填写两个公开配置值。"
            case .invalidURL: "SUPABASE_URL 不是有效网址。"
            }
        }
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) throws -> AppConfiguration {
        let plist = bundle.url(forResource: "Config", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }
        let rawURL = environment["SUPABASE_URL"] ?? plist?["SUPABASE_URL"] as? String
        let key = environment["SUPABASE_ANON_KEY"] ?? plist?["SUPABASE_ANON_KEY"] as? String
        guard let rawURL, !rawURL.contains("<"), let key, !key.contains("<"), !key.isEmpty else {
            throw ConfigurationError.missing
        }
        guard let url = URL(string: rawURL), let scheme = url.scheme, ["https", "http"].contains(scheme) else {
            throw ConfigurationError.invalidURL
        }
        return AppConfiguration(supabaseURL: url, supabaseAnonKey: key)
    }
}
