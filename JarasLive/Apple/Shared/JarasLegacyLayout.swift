import SwiftUI

enum JarasDrawingCompatibility {
    static let forceLegacy = ProcessInfo.processInfo.arguments.contains("--catlive-test-macos12")
}

private struct JarasPlacementKey: EnvironmentKey { static let defaultValue: [CGRect] = [] }
extension EnvironmentValues {
    var jarasPlacementFrames: [CGRect] {
        get { self[JarasPlacementKey.self] }
        set { self[JarasPlacementKey.self] = newValue }
    }
}
/// Positions are supplied by the same geometry model as Layout on newer OSes.
/// Children keep their identity; a zero-size control moves outside the clip.
struct JarasFixedPlacement<Content: View>: View {
    let size: CGSize
    let frames: [CGRect]
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading, content: content)
            .environment(\.jarasPlacementFrames, frames)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .alignmentGuide(.leading) { _ in 0 }
            .alignmentGuide(.top) { _ in 0 }
    }
}
private struct JarasPlacedView: ViewModifier {
    let index: Int
    @Environment(\.jarasPlacementFrames) private var frames
    @ViewBuilder func body(content: Content) -> some View {
        if frames.indices.contains(index) {
            let frame = frames[index]
            content.frame(width: max(0, frame.width), height: max(0, frame.height))
                .offset(x: frame.width <= 0 || frame.height <= 0 ? 100_000 : frame.minX, y: frame.minY)
                .alignmentGuide(.leading) { _ in 0 }
                .alignmentGuide(.top) { _ in 0 }
        } else { content }
    }
}
extension View {
    @ViewBuilder func jarasPlaced(at index: Int) -> some View {
        if #available(macOS 13, *), !JarasDrawingCompatibility.forceLegacy { self }
        else { modifier(JarasPlacedView(index: index)) }
    }
}
