import Foundation
@testable import DesksetCore

private final class ProjectionEnvironment: SceneEnvironment {
    var stamp = EnvironmentStamp(scale: 1, fontGeneration: 1,
                                 appearance: AppearanceStamp(value: .light, name: "test-light"), imageGeneration: 0)
    var files: [String: ImageStamp] = [:]
    var queries: [String] = []

    func imageStamp(_ path: String) -> ImageStamp? {
        queries.append(path)
        return files[path]
    }
}

func runSceneProjectorTests(_ t: TestRunner) {
    t.suite("Scene: projection preserves layout, selection recipes and container order") {
        let (skin, host) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        SkinWidth=100
        SkinHeight=80
        MacGlass=Regular
        [Before]
        Meter=String
        Container=Mask
        Text=before
        X=3
        Y=4
        MacGlass=Clear
        [Top]
        Meter=String
        Text=top
        X=40
        Y=10
        StringAlign=Right
        LeftMouseUpAction=[!SetVariable Clicked 1]
        [Mask]
        Meter=Shape
        X=10
        Y=20
        Shape=Rectangle 0,0,60,40 | Fill Color 20,80,130,190 | StrokeWidth 0
        TransformationMatrix=1;0;0;1;5;7
        [Hidden]
        Meter=String
        Container=Mask
        Text=hidden
        Hidden=1
        [After]
        Meter=String
        Container=Mask
        Text=after
        X=6R
        Y=2r
        """)
        defer { withExtendedLifetime(host) { skin.close() } }
        skin.update()
        let environment = ProjectionEnvironment(), projector = SceneProjector()
        let scene = projector.project(skin, environment: environment)
        t.equal(scene.size, SkinSize(width: 100, height: 80))
        t.equal(scene.elements.map(\.id.name), ["before", "top", "mask", "hidden", "after"])
        t.equal(scene.elements.map(\.id.index), Array(0..<5))
        t.equal(scene.topLevelElements.map(\.id.name), ["top", "mask"])
        t.equal(scene.elements[3].visibility, .collapsed)
        t.equal(scene.elements.map(\.backing), Array(repeating: Backing.content, count: 5))
        t.equal(scene.elements[1].anchor, SkinPoint(x: 40, y: 10))
        t.check(scene.elements[1].frame.x != scene.elements[1].anchor.x, "StringAlign changes the frame, not the anchor")
        t.equal(scene.hitMap, skin.makeHitMap())
        t.equal(scene.glass, skin.currentGlassRegions())
        t.equal(scene.background.prefix(scene.glass.count), scene.glass.map(DrawItem.glass)[...])
        t.equal(scene.drawingRuns.count, 3, "base and two top-level compositions")
        let mask = scene.elements[2]
        t.equal(scene.elements[0].container, mask.id)
        t.equal(scene.elements[4].container, mask.id)
        guard case let .container(clip, maskItems, content) = scene.drawingRuns[2].first else {
            return t.check(false, "a container is a captured mask and content recipe")
        }
        t.equal(clip, mask.frame, "container clip is untransformed")
        t.equal(maskItems, mask.items, "only the mask carries the container matrix")
        t.equal(content, scene.elements[0].items + scene.elements[4].items, "visible children keep file order")
        guard let liveMask = skin.meter(named: "Mask") else { return t.check(false, "mask exists") }
        let selected = projector.projectElement(liveMask, index: 2, environment: environment)
        t.equal(selected, mask, "selection retains its own recipe rather than expanding its children")
        let again = projector.project(skin, environment: environment, glassSource: .published)
        t.equal(again.generation, scene.generation + 1)
        t.equal(again.elements, scene.elements)
        t.equal(again.glass, skin.glassRegions)
        skin.perform(Bang(name: "hidemeter", args: ["Mask"]))
        let hidden = projector.project(skin, environment: environment)
        t.equal(hidden.topLevelElements.map(\.id.name), ["top"])
        t.equal(scene.topLevelElements.map(\.id.name), ["top", "mask"], "the old scene is unchanged")
    }

    t.suite("Scene: every projection checks image dependencies including unavailable files") {
        let (skin, host) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        BackgroundMode=3
        Background=shared100x50.png
        [Image]
        Meter=Image
        ImageName=shared100x50.png
        MaskImageName=missing.png
        W=30
        H=20
        [Bars]
        Meter=Histogram
        MeasureName=Value
        PrimaryImage=first.png
        SecondaryImage=second.png
        BothImage=both.png
        W=10
        H=20
        [Value]
        Measure=Calc
        Formula=25
        MaxValue=100
        [Wheel]
        Meter=Rotator
        ImageName=rotator100x50.png
        W=20
        H=20
        [Button]
        Meter=Button
        ButtonImage=button100x50.png
        [Digits]
        Meter=Bitmap
        BitmapImage=bitmap100x50.png
        MeasureName=Value
        BitmapFrames=10
        """)
        defer { withExtendedLifetime(host) { skin.close() } }
        skin.update()
        let environment = ProjectionEnvironment(), projector = SceneProjector()
        let first = projector.project(skin, environment: environment)
        let image = first.elements[0]
        let paths = image.imageDependencies.map(\.path)
        t.equal(paths.map { ($0 as NSString).lastPathComponent }, ["shared100x50.png", "missing.png"])
        t.check(image.imageDependencies.allSatisfy { $0.stamp == nil }, "missing files keep their path")
        t.equal(Set(environment.queries).count, environment.queries.count, "one stat per path across background and elements")
        t.equal(first.elements[1].imageDependencies.map { ($0.path as NSString).lastPathComponent },
                ["first.png", "second.png", "both.png"])
        t.equal(first.elements[2].imageDependencies.map { ($0.path as NSString).lastPathComponent }, ["rotator100x50.png"])
        t.equal(first.elements[3].imageDependencies.map { ($0.path as NSString).lastPathComponent }, ["button100x50.png"])
        t.equal(first.elements[4].imageDependencies.map { ($0.path as NSString).lastPathComponent }, ["bitmap100x50.png"])
        let sourceStamp = ImageStamp(seconds: 1, nanoseconds: 2, size: 30, inode: 4)
        environment.files[paths[1]] = sourceStamp
        environment.queries = []
        let appeared = projector.project(skin, environment: environment)
        t.equal(appeared.elements[0].items, image.items, "no meter or layout change is needed")
        t.check(appeared.elements[0] != image, "the newly available resource changes the captured inputs")
        t.equal(appeared.elements[0].imageDependencies[1].stamp, sourceStamp)
        t.equal(Set(environment.queries).count, environment.queries.count)
        t.check(image.imageDependencies[1].stamp == nil, "the old resource observation remains missing")
        t.equal(appeared.backgroundImageDependencies, first.backgroundImageDependencies)
    }

    t.suite("Scene: range-only updates and owner release leave earlier scenes independent") {
        weak var releasedSkin: Skin?
        weak var releasedMeter: Meter?
        let environment = ProjectionEnvironment(), projector = SceneProjector()
        let old = try autoreleasepool { () throws -> WidgetScene in
            let (skin, host) = try makeSkin(t, """
            [Rainmeter]
            Update=-1
            [Value]
            Measure=Calc
            Formula=25
            MinValue=0
            MaxValue=100
            [Graph]
            Meter=Histogram
            MeasureName=Value
            W=8
            H=20
            """)
            defer { withExtendedLifetime(host) { skin.close() } }
            skin.update()
            releasedSkin = skin
            releasedMeter = skin.meter(named: "Graph")
            let captured = projector.project(skin, environment: environment)
            guard let value = skin.measure(named: "Value"), let graph = skin.meter(named: "Graph") else {
                throw CocoaError(.coderInvalidValue)
            }
            let generation = graph.drawGeneration
            value.maxValue = 50
            let ranged = projector.project(skin, environment: environment)
            t.equal(graph.drawGeneration, generation, "only the bound measure range changed")
            t.check(ranged.elements[0].items != captured.elements[0].items, "ranges are captured every projection")
            t.equal(ranged.elements[0].frame, captured.elements[0].frame)
            return captured
        }
        t.check(releasedSkin == nil && releasedMeter == nil, "the projector, drawing recipes and hit map retain no owner")
        guard case let .transformed(_, own) = old.elements[0].items.first,
              case let .graph(.histogram(graph)) = own.last else {
            return t.check(false, "the earlier histogram remains available")
        }
        t.close(graph.primary.maxValue, 100)
        t.close(graph.fraction(age: 0), 0.25)
        t.equal(old.environment, environment.stamp)
    }
}
