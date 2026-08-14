// Sources/Daemon/WindowBackend.swift
import Foundation

protocol WindowBackend {
    /// nil = the query FAILED (backend error/timeout) — the caller must not
    /// treat it as "no windows". An empty array is a trustworthy, genuinely
    /// window-less desktop. Conflating the two let a transient yabai failure
    /// either freeze stale windows into the model forever or trigger a
    /// duplicate reopen.
    func queryAllWindows(completion: @escaping ([WindowInfo]?) -> Void)
    func focusedWindow(completion: @escaping (WindowInfo?) -> Void)
    func focusWindow(id: Int, completion: @escaping (Bool) -> Void)
    func focusSpace(index: Int, completion: @escaping (Bool) -> Void)
}
