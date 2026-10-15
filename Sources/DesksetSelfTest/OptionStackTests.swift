import Foundation
@testable import DesksetCore

func runOptionStackTests(_ t: TestRunner) {
    t.suite("Engine: option stack: raw readers retain empty sources and legacy alias boundaries") {
        // These public readers intentionally answer different questions: value fallback ignores empty text,
        // whereas origin lookup identifies the first definition, even when that definition is empty.
        let ini = """
        [Rainmeter]
        Update=-1
        [Early]
        Tag=early
        OnlyEmpty=
        ValueReminder=9
        [Late]
        Tag=
        OnlyEmpty=
        [Reader]
        Meter=Image
        MeterStyle=Early|Late
        Tag=
        W=1
        H=1
        """
        let (skin, _) = try makeSkin(t, ini)
        defer { skin.close() }
        guard let reader = skin.meter(named: "Reader") else { return t.check(false, "reader") }
        let own = OptionOrigin.own(IniSourceLocation(file: skin.fileURL, line: 13))
        let lastStyle = OptionOrigin.style("Late", IniSourceLocation(file: skin.fileURL, line: 8))
        t.equal(reader.rawOption("Tag"), "early")
        t.equal(reader.fileOption("Tag"), "early")
        t.equal(reader.styleFileOption("TAG"), "early")
        t.equal(reader.fileOrigin("Tag"), own)
        t.equal(reader.optionOrigin("Tag"), own, "presence, not the nonempty fallback's source")
        t.equal(reader.rawOption("OnlyEmpty"), "")
        t.equal(reader.fileOption("OnlyEmpty"), "")
        t.equal(reader.styleFileOption("OnlyEmpty"), "")
        t.equal(reader.rawOption("Missing"), nil)
        t.equal(reader.fileOption("Missing"), nil)
        t.equal(reader.styleFileOption("Missing"), nil)

        skin.perform(Bang(name: "setoption", args: ["Reader", "Tag", "runtime"]))
        t.equal(reader.rawOption("Tag"), "runtime")
        t.equal(reader.optionOrigin("Tag"), .setOption)
        t.equal(reader.fileOption("Tag"), "early", "runtime overrides do not alter the file view")
        t.equal(reader.styleFileOption("Tag"), "early")
        t.equal(reader.fileOrigin("Tag"), own)
        skin.perform(Bang(name: "setoption", args: ["Reader", "Tag", ""]))
        t.equal(reader.rawOption("Tag"), "early")
        t.equal(reader.optionOrigin("Tag"), lastStyle, "removed own key exposes the last defined style source")
        t.equal(reader.fileOrigin("Tag"), own, "the source file still contains its empty own definition")

        t.equal(reader.rawOption("ValueRemainder"), "9", "raw lookup has the existing legacy alias fallback")
        t.equal(reader.fileOption("ValueRemainder"), nil, "file readers report only the requested spelling")
        t.equal(reader.styleFileOption("ValueRemainder"), nil)
        t.equal(reader.optionOrigin("ValueRemainder"), nil)
        skin.perform(Bang(name: "setoption", args: ["Reader", "ValueRemainder", "11"]))
        t.equal(reader.rawOption("ValueRemainder"), "11")
        skin.perform(Bang(name: "setoption", args: ["Reader", "ValueRemainder", ""]))
        t.equal(reader.rawOption("ValueRemainder"), "9", "a missing canonical result still tries its alias")
    }
}
