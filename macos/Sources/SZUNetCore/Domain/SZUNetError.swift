import Foundation

public enum SZUNetError: LocalizedError, Equatable {
    case configuration(String)
    case credential(String)
    case network(String)
    case portal(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .configuration(let message),
             .credential(let message),
             .network(let message),
             .portal(let message),
             .fileSystem(let message):
            return message
        }
    }
}
