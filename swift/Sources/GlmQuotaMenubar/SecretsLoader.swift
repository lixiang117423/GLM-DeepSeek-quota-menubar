import Foundation

/// Load API tokens from ~/.config/zsh/ai-secrets.env
struct SecretsLoader {
    private static let secretsFile: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zsh/ai-secrets.env")
    }()

    /// Returns ["glm": token, "deepseek": token, "opencode": token] for any keys found
    static func load() -> [String: String] {
        var tokens: [String: String] = [:]
        guard let content = try? String(contentsOf: secretsFile, encoding: .utf8) else {
            return tokens
        }
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("export ") else { continue }
            let afterExport = String(trimmed.dropFirst(7))  // remove "export "
            let parts = afterExport.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if key == "ANTHROPIC_AUTH_TOKEN_GLM" {
                tokens["glm"] = value
            } else if key == "ANTHROPIC_AUTH_TOKEN_DEEPSEEK" {
                tokens["deepseek"] = value
            } else if key == "OPENCODE_API_KEY" {
                tokens["opencode"] = value
            }
        }
        return tokens
    }
}
