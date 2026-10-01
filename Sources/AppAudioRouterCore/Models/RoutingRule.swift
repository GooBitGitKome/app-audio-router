import Foundation

/// Per-application routing configuration rule.
public struct RoutingRule: Codable, Sendable {
    public var bundleIdentifier: String?
    public var appName: String
    public var volume: Float
    public var isMuted: Bool
    public var targetDeviceUID: String?
    public var routeToMic: Bool

    public init(
        bundleIdentifier: String? = nil,
        appName: String,
        volume: Float = 1.0,
        isMuted: Bool = false,
        targetDeviceUID: String? = nil,
        routeToMic: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.volume = volume
        self.isMuted = isMuted
        self.targetDeviceUID = targetDeviceUID
        self.routeToMic = routeToMic
    }
}
