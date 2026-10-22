import Darwin
import Foundation

public enum MaintenanceLockMode: Sendable {
    case shared
    case exclusive
}

public enum MaintenanceLockError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case openFailed
    case timedOut
    case lockFailed

    public var description: String {
        switch self {
        case .openFailed: return "无法打开维护锁"
        case .timedOut: return "等待维护锁超时"
        case .lockFailed: return "无法取得维护锁"
        }
    }
}

/// The maintenance lock coordinates production stores with offline backup and
/// restore. Normal store operations take a shared lock; restore takes the
/// exclusive lock. The lock file is deliberately separate from data files so
/// replacing a history/audit set never replaces the coordination inode.
public enum MaintenanceLock {
    public static let fileName = ".maintenance.lock"

    public static func url(root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func acquire(
        root: URL,
        mode: MaintenanceLockMode,
        timeoutSeconds: TimeInterval = 2
    ) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
        } catch {
            throw MaintenanceLockError.openFailed
        }

        let path = url(root: root).path
        let descriptor = path.withCString {
            open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw MaintenanceLockError.openFailed
        }
        var releaseOnFailure = true
        defer {
            if releaseOnFailure {
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }

        let operation = mode == .shared ? LOCK_SH : LOCK_EX
        let clock = ContinuousClock()
        let timeout = timeoutSeconds.isFinite && timeoutSeconds >= 0
            ? timeoutSeconds
            : 0
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while true {
            if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                throw CancellationError()
            }
            if flock(descriptor, operation | LOCK_NB) == 0 {
                break
            }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw MaintenanceLockError.lockFailed
            }
            guard clock.now < deadline else {
                throw MaintenanceLockError.timedOut
            }
            usleep(10_000)
        }
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
        } catch {
            throw MaintenanceLockError.lockFailed
        }
        releaseOnFailure = false
        return descriptor
    }

    public static func release(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum MaintenanceTransaction {
    public static let fileName = ".memory-monitor-restore.json"

    public static func url(root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    public static func exists(root: URL) -> Bool {
        var info = stat()
        return lstat(url(root: root).path, &info) == 0
    }
}
