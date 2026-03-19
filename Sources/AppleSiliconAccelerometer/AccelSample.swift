import Foundation

/// A single accelerometer reading with X, Y, Z axes in g-force units.
public struct AccelSample {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}
