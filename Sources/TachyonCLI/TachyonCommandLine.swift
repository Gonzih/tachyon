import Darwin
import Foundation
import TachyonIPC

public enum TachyonCommandLine {
    public static func run(arguments: [String]) -> Int32 {
        let command: TachyonCLICommand
        do {
            command = try TachyonCLIParser.parse(arguments)
        } catch {
            writeError("tachyon: \(error.localizedDescription)\n\n\(TachyonCLIParser.help)")
            return 64
        }

        switch command {
        case .help:
            print(TachyonCLIParser.help)
            return 0
        case .version:
            print("Tachyon CLI")
            return 0
        case .status(let json):
            return printStatus(json: json)
        }
    }

    private static func printStatus(json: Bool) -> Int32 {
        do {
            let response = try TachyonStatusClient().status()
            if json {
                let data = try TachyonStatusProtocol.encode(response)
                guard let output = String(data: data, encoding: .utf8) else {
                    throw TachyonStatusClientError.malformedResponse
                }
                print(output)
            } else {
                print(TachyonStatusRenderer.render(response, usesColor: TerminalStyle.usesColor))
            }
            return 0
        } catch let error as TachyonStatusClientError {
            writeError("tachyon: \(error.errorDescription ?? "Unknown error")")
            return 69
        } catch {
            writeError("tachyon: Could not print status. Try again.")
            return 70
        }
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum TachyonCLICommand: Equatable {
    case status(json: Bool)
    case help
    case version
}

enum TachyonCLIParserError: Error, LocalizedError, Equatable {
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "expected `tachyon status [--json]`"
        }
    }
}

enum TachyonCLIParser {
    static let help = """
    Usage: tachyon status [--json]

    Reads the running Tachyon app's cached usage state.
    The command never refreshes providers or changes configuration.
    """

    static func parse(_ arguments: [String]) throws -> TachyonCLICommand {
        switch arguments {
        case ["status"]:
            .status(json: false)
        case ["status", "--json"], ["--json", "status"]:
            .status(json: true)
        case ["help"], ["--help"], ["-h"]:
            .help
        case ["--version"], ["-V"]:
            .version
        default:
            throw TachyonCLIParserError.invalidArguments
        }
    }
}

enum TachyonStatusRenderer {
    static func render(_ response: TachyonStatusResponse, usesColor: Bool) -> String {
        var lines = [
            "\(TerminalStyle.brand("Tachyon", enabled: usesColor)) \(response.appVersion) · cached \(response.generatedAt)"
        ]
        guard !response.providers.isEmpty else {
            lines.append("\nNo active providers. Enable a source in Tachyon Settings.")
            return lines.joined(separator: "\n")
        }

        for provider in response.providers {
            lines.append("")
            lines.append(providerLine(provider, usesColor: usesColor))
            lines.append(contentsOf: windowLines(provider, usesColor: usesColor))
            if let detail = provider.detail, !detail.isEmpty {
                lines.append("  \(TerminalStyle.muted(detail, enabled: usesColor))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func providerLine(_ provider: TachyonProviderStatus, usesColor: Bool) -> String {
        let source = provider.source.map { " · \($0)" } ?? ""
        let label = "\(provider.name)\(source)"
        return "\(TerminalStyle.heading(label, enabled: usesColor))  \(stateText(provider, usesColor: usesColor))"
    }

    private static func windowLines(_ provider: TachyonProviderStatus, usesColor: Bool) -> [String] {
        var lines = provider.windows.map { window in
            let reset = window.resetText.map { " · \($0)" } ?? ""
            return "  \(window.label) — \(window.displayValue)\(TerminalStyle.muted(reset, enabled: usesColor))"
        }
        if provider.state == .stale, let updatedAt = provider.updatedAt {
            lines.append("  \(TerminalStyle.muted("as of \(updatedAt)", enabled: usesColor))")
        }
        return lines
    }

    private static func stateText(_ provider: TachyonProviderStatus, usesColor: Bool) -> String {
        let text: String
        let color: TerminalStyle.Color
        switch provider.presence {
        case .notInstalled:
            text = "not installed"
            color = .muted
        case .notSignedIn:
            text = "not signed in"
            color = .yellow
        case .ready:
            switch provider.state {
            case .current:
                text = "current"
                color = .green
            case .stale:
                text = "stale"
                color = .yellow
            case .authError:
                text = "needs sign-in"
                color = .yellow
            case .unavailable:
                text = "unavailable"
                color = .muted
            }
        }
        return TerminalStyle.color(text, color: color, enabled: usesColor)
    }
}

enum TerminalStyle {
    enum Color: String {
        case green = "32"
        case yellow = "33"
        case muted = "2"
        case heading = "1"
    }

    static var usesColor: Bool {
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    static func brand(_ value: String, enabled: Bool) -> String {
        color(value, color: .heading, enabled: enabled)
    }

    static func heading(_ value: String, enabled: Bool) -> String {
        color(value, color: .heading, enabled: enabled)
    }

    static func muted(_ value: String, enabled: Bool) -> String {
        color(value, color: .muted, enabled: enabled)
    }

    static func color(_ value: String, color: Color, enabled: Bool) -> String {
        guard enabled, !value.isEmpty else { return value }
        return "\u{001B}[\(color.rawValue)m\(value)\u{001B}[0m"
    }
}
