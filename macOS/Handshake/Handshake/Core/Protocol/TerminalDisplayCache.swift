import Foundation

nonisolated enum CoreDisplayCacheOperation: Sendable {
    case read(key: UInt64)
    case write(key: UInt64, sourceOffset: UInt64, bytes: Data)
}
