import Foundation
@testable import DesksetCore

// The Core values a scene is made of cross threads (the runtime design: a skin's thread builds the scene, others draw
// and compare it), so they are Sendable. This is checked when the tests compile: `sendable` only accepts a Sendable
// type, so taking the conformance away from any of them breaks the build.

private func sendable<T: Sendable>(_ type: T.Type) -> String { String(reflecting: type) }

func runSendableTests(_ t: TestRunner) {
    t.suite("Seams: the scene's Core values are Sendable") {
        let geometry = [sendable(SkinRect.self), sendable(SkinSize.self), sendable(SkinInsets.self),
                        sendable(SkinScreen.self), sendable(PositionValue.self), sendable(PositionValue.Mode.self)]
        let color = [sendable(RGBA.self)]
        let glass = [sendable(GlassRegion.self), sendable(GlassStyle.self), sendable(GlassOptions.self)]
        let text = [sendable(TextStyle.self), sendable(HorizontalTextAlign.self), sendable(VerticalTextAlign.self),
                    sendable(StringEffect.self), sendable(InlineSpan.self), sendable(InlineSetting.self),
                    sendable(InlineGradient.self), sendable(GradientStop.self), sendable(InlineCase.self)]
        let shape = [sendable(ShapeItem.self), sendable(ShapeGeometry.self), sendable(ShapePath.self),
                     sendable(ShapeSubpath.self), sendable(ShapeSegment.self), sendable(ShapeSegmentKind.self),
                     sendable(ShapePoint.self), sendable(ShapeRect.self), sendable(ShapeRectangle.self),
                     sendable(ShapeTransform.self), sendable(ShapePaint.self), sendable(ShapeLinearGradient.self),
                     sendable(ShapeRadialGradient.self), sendable(ShapeGradientStop.self),
                     sendable(ShapeStrokeStyle.self), sendable(ShapeStrokePlan.self), sendable(ShapeStrokeRun.self),
                     sendable(ShapeStrokePlacement.self), sendable(ShapeLineCap.self), sendable(ShapeLineJoin.self),
                     sendable(ShapeFillRule.self), sendable(ShapeCombineMode.self), sendable(ShapeCombineStep.self)]
        let images = [sendable(ImageOptions.self), sendable(ImageOptions.Flip.self), sendable(ImageOptions.Crop.self),
                      sendable(MacSymbol.self), sendable(MacSymbol.Style.self), sendable(MacSymbol.Weight.self),
                      sendable(MacSymbol.Rendering.self), sendable(RotatorMeter.ImageProcessing.self),
                      sendable(RotatorMeter.Crop.self)]
        let meters = [sendable(RoundlineMeter.Options.self), sendable(RoundlineMeter.Shape.self),
                      sendable(RoundMeterMath.Transform.self), sendable(HistogramMeter.HistogramImage.self),
                      sendable(HistogramMeter.Part.self), sendable(GraphDirection.self), sendable(GraphGeometry.self),
                      sendable(BitmapMeter.Align.self), sendable(ButtonMeter.State.self)]
        let actions = [sendable(Bang.self), sendable(SkinAction.self), sendable(ParsedAction.self),
                       sendable(ArgumentQuoting.self)]
        let input = [sendable(MouseEventKind.self), sendable(MouseButton.self), sendable(PointerEvent.self),
                     sendable(MouseActionState.self), sendable(OutsidePointerNeeds.self), sendable(ToolTipInfo.self),
                     sendable(ContextMenuItem.self), sendable(SkinLogLevel.self), sendable(JSONValue.self)]
        let all = geometry + color + glass + text + shape + images + meters + actions + input
        t.equal(Set(all).count, all.count, "each type once")
        t.check(all.count >= 60, "\(all.count) types")
    }
}
