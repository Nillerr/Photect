import CoreGraphics

extension CGPoint {
    internal func scaled(to size: CGSize) -> CGPoint {
        return CGPoint(
            x: self.x * size.width,
            y: self.y * size.height
        )
    }
}
