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
    /// When the last optimistic focus update landed. Snapshot queries take
    /// 90-350ms while presses arrive every ~200-500ms during rapid
    /// switching, so a poll straddling a focus action is COMMON — an
    /// unfenced rebuild rolled focusedId back to the pre-switch value and
    /// produced wrong "already focused" no-ops and spurious focusSpace
    /// calls (observed live 2026-08-15).
    private var lastOptimisticAt: DispatchTime?

    func snapshot() -> WindowModel {
        lock.lock(); defer { lock.unlock() }
        return model
    }

    /// Full rebuild from a fresh queryAllWindows dump. focusedId is derived
    /// from yabai's has-focus flag, with two fences:
    /// 1. An optimistic update NEWER than the query's start wins — the dump
    ///    captured pre-switch focus and must not roll it back.
    /// 2. A dump with NO has-focus row (mid-Space-transition artifact)
    ///    keeps the prior focus while that window still exists.
    func replaceSnapshot(_ windows: [WindowInfo],
                         queryStartedAt: DispatchTime? = nil) {
        lock.lock(); defer { lock.unlock() }
        let prevFocusedId = model.focusedId
        let prevStillPresent = prevFocusedId.map { id in
            windows.contains(where: { $0.id == id })
        } ?? false
        model.windows = windows
        let dumpFocusedId = windows.first(where: { $0.hasFocus })?.id
        if let start = queryStartedAt, let opt = lastOptimisticAt,
           opt > start, prevStillPresent {
            // Fence 1: keep the newer optimistic focus.
        } else if let dumpId = dumpFocusedId {
            model.focusedId = dumpId
        } else if prevStillPresent {
            // Fence 2: transition dump without a focused row.
        } else {
            model.focusedId = nil
        }
        model.generation &+= 1
    }

    /// Optimistic read-your-writes update after appfocus committed a focus
    /// action: the next queued command must see the settled focus without a
    /// query, so serialized bursts compound one step per press.
    func noteFocused(id: Int) {
        lock.lock(); defer { lock.unlock() }
        model.focusedId = id
        lastOptimisticAt = .now()
    }

    /// The model's focused window, if it is still present in the snapshot.
    var focusedWindow: WindowInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let id = model.focusedId else { return nil }
        return model.windows.first(where: { $0.id == id })
    }
}
