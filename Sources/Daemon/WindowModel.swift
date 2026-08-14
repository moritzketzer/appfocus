// Sources/Daemon/WindowModel.swift
import Foundation

/// The daemon's in-memory picture of the desktop: a materialized view over
/// yabai's window state, rebuilt by the background snapshot poll and patched
/// optimistically when appfocus itself commits a focus change. Commands read
/// this instead of querying yabai, which is what keeps keypresses fast while
/// the WindowServer (and therefore yabai's query path) is stalled.
struct WindowModel {
    var windows: [WindowInfo] = []
    var focusedId: Int? = nil
    var generation: UInt64 = 0
}

/// Thread-safe holder. Writers: FocusPoller (snapshot rebuild) and
/// ActivationLogic (optimistic focus update, confirm-query rebuild).
/// Readers: ActivationLogic's command hot path.
final class WindowModelStore {
    private let lock = NSLock()
    private var model = WindowModel()

    func snapshot() -> WindowModel {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    /// Full rebuild from a fresh queryAllWindows dump. focusedId is derived
    /// from yabai's has-focus flag. Accepted race: a poll whose query
    /// straddles a focus action can briefly roll the optimistic focusedId
    /// back to the pre-action value (exposure = the query's duration; the
    /// next poll or press corrects it). Fencing this with timestamps is not
    /// worth the complexity for a tens-of-ms window.
    func replaceSnapshot(_ windows: [WindowInfo]) {
        lock.lock(); defer { lock.unlock() }
        model.windows = windows
        model.focusedId = windows.first(where: { $0.hasFocus })?.id
        model.generation &+= 1
    }

    /// Optimistic read-your-writes update after appfocus committed a focus
    /// action: the next queued command must see the settled focus without a
    /// query, so serialized bursts compound one step per press.
    func noteFocused(id: Int) {
        lock.lock(); defer { lock.unlock() }
        model.focusedId = id
    }

    /// The model's focused window, if it is still present in the snapshot.
    var focusedWindow: WindowInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let id = model.focusedId else { return nil }
        return model.windows.first(where: { $0.id == id })
    }
}
