import CoreFoundation
import Foundation

/// The deliberately small, read-only protocol shared by Tachyon.app and its
/// bundled command-line client. It carries cached UI state only: no provider
/// request, credential, account identifier, or configuration operation exists
/// on this boundary.
public enum TachyonStatusProtocol {
    public static let schemaVersion = 1
    public static let portName = "dev.gonzih.tachyon.status.v1"
    public static let statusMessageID: Int32 = 1
    public static let maximumRequestBytes = 4 * 1024
    public static let maximumResponseBytes = 256 * 1024

    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct TachyonStatusRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let command: String

    public init(schemaVersion: Int = TachyonStatusProtocol.schemaVersion, command: String = "status") {
        self.schemaVersion = schemaVersion
        self.command = command
    }

    public var isSupported: Bool {
        schemaVersion == TachyonStatusProtocol.schemaVersion && command == "status"
    }
}

public enum TachyonProviderPresence: String, Codable, Equatable, Sendable {
    case ready
    case notInstalled
    case notSignedIn
}

public enum TachyonProviderState: String, Codable, Equatable, Sendable {
    case current
    case stale
    case authError
    case unavailable
}

/// A raw usage window plus the two compact strings Tachyon already uses in
/// its popover. Automation should prefer the numeric fields; the strings make
/// the terminal view precisely match the app without inventing reset times.
public struct TachyonUsageWindow: Codable, Equatable, Sendable {
    public let label: String
    public let percentUsed: Double?
    public let spendUSD: Double?
    public let budgetUSD: Double?
    public let count: Int?
    public let countUnit: String?
    public let resetsAt: String?
    public let windowSeconds: Double?
    public let displayValue: String
    public let resetText: String?

    public init(
        label: String,
        percentUsed: Double?,
        spendUSD: Double?,
        budgetUSD: Double?,
        count: Int?,
        countUnit: String?,
        resetsAt: String?,
        windowSeconds: Double?,
        displayValue: String,
        resetText: String?
    ) {
        self.label = label
        self.percentUsed = percentUsed
        self.spendUSD = spendUSD
        self.budgetUSD = budgetUSD
        self.count = count
        self.countUnit = countUnit
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.displayValue = displayValue
        self.resetText = resetText
    }
}

public struct TachyonProviderStatus: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let source: String?
    public let presence: TachyonProviderPresence
    public let state: TachyonProviderState
    public let updatedAt: String?
    public let detail: String?
    public let windows: [TachyonUsageWindow]

    public init(
        id: String,
        name: String,
        source: String?,
        presence: TachyonProviderPresence,
        state: TachyonProviderState,
        updatedAt: String?,
        detail: String?,
        windows: [TachyonUsageWindow]
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.presence = presence
        self.state = state
        self.updatedAt = updatedAt
        self.detail = detail
        self.windows = windows
    }
}

public struct TachyonStatusResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let appVersion: String
    public let providers: [TachyonProviderStatus]

    public init(
        schemaVersion: Int = TachyonStatusProtocol.schemaVersion,
        generatedAt: String,
        appVersion: String,
        providers: [TachyonProviderStatus]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.providers = providers
    }

}

public enum TachyonStatusClientError: Error, Equatable, LocalizedError {
    case appNotRunning
    case timedOut
    case transport
    case malformedResponse
    case unsupportedProtocol

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "Tachyon isn’t running. Open Tachyon and try again."
        case .timedOut:
            return "Tachyon did not answer in time. Try again."
        case .transport:
            return "Tachyon could not be reached. Restart Tachyon and try again."
        case .malformedResponse:
            return "Tachyon returned an unreadable status response. Restart Tachyon and try again."
        case .unsupportedProtocol:
            return "Tachyon and this command-line tool are different versions. Update Tachyon and try again."
        }
    }
}

/// Client for the app's named, same-machine Core Foundation message port.
/// It has no provider dependencies and cannot cause a provider refresh.
public struct TachyonStatusClient: Sendable {
    public let portName: String

    public init(portName: String = TachyonStatusProtocol.portName) {
        self.portName = portName
    }

    public func status(timeout: TimeInterval = 1) throws -> TachyonStatusResponse {
        guard let port = CFMessagePortCreateRemote(kCFAllocatorDefault, portName as CFString),
              CFMessagePortIsValid(port)
        else {
            throw TachyonStatusClientError.appNotRunning
        }

        let request: Data
        do {
            request = try TachyonStatusProtocol.encode(TachyonStatusRequest())
        } catch {
            throw TachyonStatusClientError.transport
        }

        var reply: Unmanaged<CFData>?
        let result = CFMessagePortSendRequest(
            port,
            TachyonStatusProtocol.statusMessageID,
            request as CFData,
            timeout,
            timeout,
            CFRunLoopMode.defaultMode.rawValue as CFString,
            &reply
        )

        guard result == kCFMessagePortSuccess else {
            switch result {
            case kCFMessagePortIsInvalid:
                throw TachyonStatusClientError.appNotRunning
            case kCFMessagePortSendTimeout, kCFMessagePortReceiveTimeout:
                throw TachyonStatusClientError.timedOut
            default:
                throw TachyonStatusClientError.transport
            }
        }
        guard let reply else { throw TachyonStatusClientError.malformedResponse }

        let responseData = reply.takeRetainedValue() as Data
        guard responseData.count <= TachyonStatusProtocol.maximumResponseBytes else {
            throw TachyonStatusClientError.malformedResponse
        }
        let response: TachyonStatusResponse
        do {
            response = try TachyonStatusProtocol.decode(TachyonStatusResponse.self, from: responseData)
        } catch {
            throw TachyonStatusClientError.malformedResponse
        }
        guard response.schemaVersion == TachyonStatusProtocol.schemaVersion else {
            throw TachyonStatusClientError.unsupportedProtocol
        }
        return response
    }
}
