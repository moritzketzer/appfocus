// Sources/Daemon/WindowBackend.swift
import Foundation

protocol WindowBackend {
    func queryAllWindows(completion: @escaping ([WindowInfo]) -> Void)
    func focusedWindow(completion: @escaping (WindowInfo?) -> Void)
    func focusWindow(id: Int, completion: @escaping (Bool) -> Void)
    func focusSpace(index: Int, completion: @escaping (Bool) -> Void)
}
