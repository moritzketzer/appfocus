// Sources/Daemon/CommandSource.swift
import Foundation

protocol CommandSource {
    func start() throws
    func stop()
}
