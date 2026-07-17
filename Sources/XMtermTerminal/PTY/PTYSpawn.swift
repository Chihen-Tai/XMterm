import CXMtermPTY
import Darwin
import XMtermCore

struct PTYSpawnHandles: Sendable {
    let masterFileDescriptor: Int32
    let childProcessIdentifier: pid_t
    let childProcessGroupIdentifier: pid_t
}

func spawnPTY(for configuration: PTYLaunchConfiguration) throws -> PTYSpawnHandles {
    let argumentVector = try configuration.validatedArgumentVector()
    let arguments = try OwnedCStringVector(argumentVector)
    let environment = try OwnedCStringVector(configuration.environmentVector())
    defer {
        arguments.release()
        environment.release()
    }

    var result = XMtermPTYSpawnResult(master_fd: -1, child_pid: -1, startup_errno: 0)
    let spawnResult = configuration.executablePath.withCString { executablePath in
        configuration.workingDirectoryPath.withCString { workingDirectoryPath in
            xmterm_pty_spawn(
                executablePath,
                arguments.pointer,
                environment.pointer,
                workingDirectoryPath,
                configuration.initialSize.columns,
                configuration.initialSize.rows,
                &result
            )
        }
    }

    guard spawnResult == 0 else {
        if result.startup_errno != 0 {
            throw PTYControllerError.launchFailed(errno: result.startup_errno)
        }
        throw PTYControllerError.ptyCreationFailed(errno: errno)
    }

    return PTYSpawnHandles(
        masterFileDescriptor: result.master_fd,
        childProcessIdentifier: result.child_pid,
        // Darwin forkpty(3) makes the child the new session and process-group
        // leader before returning in the child. Record that stable identity here
        // rather than racing getpgid(2) from the parent immediately after fork.
        childProcessGroupIdentifier: result.child_pid
    )
}

private final class OwnedCStringVector {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int
    private var isReleased = false

    init(_ strings: [String]) throws {
        count = strings.count
        pointer = .allocate(capacity: strings.count + 1)
        pointer.initialize(repeating: nil, count: strings.count + 1)

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                release()
                throw PTYControllerError.allocationFailed
            }
            pointer[index] = duplicated
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        for index in 0 ..< count {
            free(pointer[index])
            pointer[index] = nil
        }
        pointer.deinitialize(count: count + 1)
        pointer.deallocate()
    }

    deinit {
        release()
    }
}
