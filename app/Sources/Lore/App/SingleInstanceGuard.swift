import Foundation

/// One Mac lore at a time (#193). Two `com.lore.app` processes each hold
/// their own Fn event tap, mic subscription and menu-bar mark, so a
/// hold-to-talk is heard twice.
///
/// The one that holds an exclusive `flock` on a file in lore's Application
/// Support folder is the one. The kernel grants it to exactly one open file,
/// so two launches can't both win, and drops it when the holder exits or
/// crashes, so it is never stale. The iPhone lore in the Simulator has its own
/// home under CoreSimulator and never opens this file.
enum SingleInstanceGuard {
    enum Lock: Equatable {
        /// This process holds the lock as long as `fd` stays open.
        case acquired(fd: Int32)
        /// Another Mac lore holds it: this launch defers.
        case heldElsewhere
        /// The file can't be opened or locked. Run anyway: two copies beat none.
        case unavailable
    }

    static func acquire(at url: URL) -> Lock {
        // O_CLOEXEC: a child process lore starts must not inherit the lock.
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Only "already locked" is another lore; a home whose file system
            // can't lock (network, FUSE) must not quit lore at every launch.
            let held = errno == EWOULDBLOCK
            close(fd)
            return held ? .heldElsewhere : .unavailable
        }
        return .acquired(fd: fd)
    }
}
