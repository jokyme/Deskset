import Foundation
@testable import DesksetCore

// Tests for DesksetCore/Formula/OptionValue.swift (docs.rainmeter.net/manual/skins/option-types/ and
// /manual/meters/general-options/).

func runOptionValueTests(_ t: TestRunner) {
    let red = RGBA(r: 255, g: 0, b: 0, a: 255)

    t.suite("OptionValue: color — manual examples") {
        // "The following lines are equivalent to solid opaque red"
        t.equal(OptionValue.color("255,0,0,255"), red)
        t.equal(OptionValue.color("255,0,0"), red)                     // alpha defaults to 255
        t.equal(OptionValue.color("(200 + 55),(2 - 2),0"), red)        // formulas in place of numbers
        t.equal(OptionValue.color("FF0000FF"), red)
        t.equal(OptionValue.color("FF0000"), red)
        // Formulas page: FontColor=(255 * 0.5),255,255,255
        t.equal(OptionValue.color("(255 * 0.5),255,255,255"), RGBA(r: 127.5, g: 255, b: 255, a: 255))
        // Defaults quoted in the manual
        t.equal(OptionValue.color("0,0,0,0"), RGBA.clear)
        t.equal(OptionValue.color("0,0,0,255"), RGBA.black)
        t.equal(OptionValue.color("0,0,0,1"), RGBA(r: 0, g: 0, b: 0, a: 1))   // "invisible" but clickable
        t.equal(OptionValue.color("128,128,128,255"), RGBA(r: 128, g: 128, b: 128))
        t.equal(OptionValue.color("255,255,255,255"), RGBA.white)
    }

    t.suite("OptionValue: color — details") {
        t.equal(OptionValue.color("ff0000"), red)                      // hex is case-insensitive
        t.equal(OptionValue.color("Ff0000fF"), red)
        t.equal(OptionValue.color("00ff0080"), RGBA(r: 0, g: 255, b: 0, a: 128))
        t.equal(OptionValue.color("123456"), RGBA(r: 0x12, g: 0x34, b: 0x56))
        t.equal(OptionValue.color("  FF0000  "), red)
        t.equal(OptionValue.color(" 255 , 0 , 0 , 128 "), RGBA(r: 255, g: 0, b: 0, a: 128))
        t.equal(OptionValue.color("300,-5,0,999"), red)                // clamped to 0…255
        t.equal(OptionValue.color("(300),(-5),0"), red)
        t.equal(OptionValue.color("255,255,255,"), RGBA.white)         // trailing comma
        t.equal(OptionValue.color("255,255,255,,"), RGBA.white)
        t.equal(OptionValue.color("255,,0"), red)                      // empty middle component → 0
        t.equal(OptionValue.color("(Clamp(300,0,255)),0,0"), red)      // commas inside a formula
        t.equal(OptionValue.color("(Max(1,2)),3,4"), RGBA(r: 2, g: 3, b: 4))
        t.equal(OptionValue.color("(1 ? 255 : 0),(Min(0, 5)),0"), red)
        t.equal(OptionValue.color("1,2,3,4,5"), RGBA(r: 1, g: 2, b: 3, a: 4))   // extras ignored
        t.equal(OptionValue.color("(1/0),0,0"), RGBA(r: 0, g: 0, b: 0))
        t.equal(OptionValue.color("12.5,0,0"), RGBA(r: 12.5, g: 0, b: 0))
        t.equal(OptionValue.color("0x10,0,0"), RGBA(r: 16, g: 0, b: 0))
        // Invalid → nil (caller uses its default)
        for bad in ["", "   ", "red", "FF00", "FF00001", "FF0000FF00", "GG0000", "#FF0000", "0xFF00", "255",
                    "255,0", "255,", ",,,", "255,abc,0", "(Foo),0,0", "(1,0,0", "FF 00 00", "٣٣٣٣٣٣"] {
            t.equal(OptionValue.color(bad), nil, String(reflecting: bad))
        }
    }

    t.suite("OptionValue: position") {
        // General Meter Options examples
        t.equal(OptionValue.position("150"), PositionValue(value: 150, mode: .absolute))
        t.equal(OptionValue.position("75"), PositionValue(value: 75))
        t.equal(OptionValue.position("10R"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("0r"), PositionValue(value: 0, mode: .relativeToPreviousStart))
        // Formulas with the suffix (version history: r/R with formulas)
        t.equal(OptionValue.position("(5+5)R"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("(5+5)r"), PositionValue(value: 10, mode: .relativeToPreviousStart))
        t.equal(OptionValue.position("(3*2)"), PositionValue(value: 6))            // (#A#*2) after substitution
        t.equal(OptionValue.position("(2 > 1 ? 42 : 666)r"), PositionValue(value: 42, mode: .relativeToPreviousStart))
        // Negative values
        t.equal(OptionValue.position("-5"), PositionValue(value: -5))
        t.equal(OptionValue.position("-5r"), PositionValue(value: -5, mode: .relativeToPreviousStart))
        t.equal(OptionValue.position("-5R"), PositionValue(value: -5, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("(-5)R"), PositionValue(value: -5, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("(0-12)r"), PositionValue(value: -12, mode: .relativeToPreviousStart))
        // Whitespace, fractions, bare suffix
        t.equal(OptionValue.position("  20r  "), PositionValue(value: 20, mode: .relativeToPreviousStart))
        t.equal(OptionValue.position("10 R"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("12.5"), PositionValue(value: 12.5))
        t.equal(OptionValue.position("R"), PositionValue(value: 0, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("r"), PositionValue(value: 0, mode: .relativeToPreviousStart))
        // Invalid
        t.equal(OptionValue.position(""), nil)
        t.equal(OptionValue.position("  "), nil)
        t.equal(OptionValue.position("abc"), nil)
        t.equal(OptionValue.position("abcr"), nil)
        t.equal(OptionValue.position("(Foo)R"), nil)
        t.equal(OptionValue.position("(1+"), nil)
    }

    t.suite("OptionValue: number / int / bool") {
        t.equal(OptionValue.number("42"), 42)
        t.equal(OptionValue.number("(40 + 2)"), 42)
        t.equal(OptionValue.number("x"), nil)
        t.equal(OptionValue.int("3.9"), 3)
        t.equal(OptionValue.int("-3.9"), -3)
        t.equal(OptionValue.int("(7/2)"), 3)
        t.equal(OptionValue.int("1000"), 1000)
        t.equal(OptionValue.int("-1"), -1)                              // e.g. UpdateDivider=-1
        t.equal(OptionValue.int("1e300"), Int.max)                      // saturates, no trap
        t.equal(OptionValue.int("-1e300"), Int.min)
        t.equal(OptionValue.int("9223372036854775807"), Int.max)
        t.equal(OptionValue.int("x"), nil)
        t.equal(OptionValue.int(""), nil)
        t.equal(OptionValue.bool("1"), true)
        t.equal(OptionValue.bool("0"), false)
        t.equal(OptionValue.bool("0.0"), false)
        t.equal(OptionValue.bool("2"), true)
        t.equal(OptionValue.bool("-1"), true)
        t.equal(OptionValue.bool("(1-1)"), false)
        t.equal(OptionValue.bool("(1 = 1)"), true)
        t.equal(OptionValue.bool(" 1 "), true)
        t.equal(OptionValue.bool("yes"), nil)
        t.equal(OptionValue.bool(""), nil)
    }

    t.suite("OptionValue: numbers") {
        t.equal(OptionValue.numbers("5,10,5,10"), [5, 10, 5, 10])        // Padding=5,10,5,10
        t.equal(OptionValue.numbers("0,-100,0,0"), [0, -100, 0, 0])      // DragMargins=0,-100,0,0
        t.equal(OptionValue.numbers("(Max(1,2)),3"), [2, 3])
        t.equal(OptionValue.numbers("(Clamp(5,0,3)),(Min(1,2))"), [3, 1])
        t.equal(OptionValue.numbers(" 1 , (2*3) , -4 "), [1, 6, -4])
        t.equal(OptionValue.numbers("7"), [7])
        t.equal(OptionValue.numbers(""), [])
        t.equal(OptionValue.numbers("   "), [])
        t.equal(OptionValue.numbers("5,,5"), [5, 0, 5])
        t.equal(OptionValue.numbers("5,5,"), [5, 5])
        t.equal(OptionValue.numbers("a,1"), [0, 1])
        t.equal(OptionValue.numbers("(1,2"), [0])                        // unbalanced: one bad item
        t.equal(OptionValue.numbers("1),2"), [1, 2])
        // TransformationMatrix examples (semicolon separated)
        t.equal(OptionValue.numbers("-1; 0; 0; 1; 40; 0", separator: ";"), [-1, 0, 0, 1, 40, 0])
        t.equal(OptionValue.numbers("1; 0; 0; -1; 0; 100", separator: ";"), [1, 0, 0, -1, 0, 100])
        t.equal(OptionValue.numbers("0.5; 0; 0; 1; 25; 0", separator: ";"), [0.5, 0, 0, 1, 25, 0])
        t.equal(OptionValue.numbers("(Cos(0)); (1;2)", separator: ";"), [1, 0])
        t.equal(OptionValue.numbers("1,2", separator: "é"), [])
    }

    t.suite("OptionValue: list and split") {
        t.equal(OptionValue.list("A | B | C"), ["A", "B", "C"])
        t.equal(OptionValue.list("StyleA|StyleB"), ["StyleA", "StyleB"])
        t.equal(OptionValue.list(" A |  | B "), ["A", "B"])
        t.equal(OptionValue.list("Single"), ["Single"])
        t.equal(OptionValue.list(""), [])
        t.equal(OptionValue.list(" | "), [])
        t.equal(OptionValue.list("(1 || 0) | B"), ["(1 || 0)", "B"])      // || inside a formula does not split
        t.equal(OptionValue.list("A || B"), ["A", "B"])
        t.equal(OptionValue.list("Grüße | 组"), ["Grüße", "组"])
        t.equal(OptionValue.split("a, (b,c) ,d", separator: ","), ["a", "(b,c)", "d"])
        t.equal(OptionValue.split("a,,b,", separator: ","), ["a", "", "b", ""])
        t.equal(OptionValue.split("", separator: ","), [""])
        t.equal(OptionValue.split(" x ", separator: "é"), ["x"])
    }

    t.suite("OptionValue: path") {
        let skin = "/Users/me/Skins/Root/Clock/"
        // Option Types examples: relative, parent folder, absolute, #CURRENTPATH#, #@#
        t.equal(OptionValue.path("lolcat.png", relativeTo: skin), "/Users/me/Skins/Root/Clock/lolcat.png")
        t.equal(OptionValue.path("..\\lolcat.png", relativeTo: skin), "/Users/me/Skins/Root/lolcat.png")
        t.equal(OptionValue.path("C:\\lolcats\\lolcat.png", relativeTo: skin), nil)
        t.equal(OptionValue.path(skin + "lolcat.png", relativeTo: "/elsewhere"), "/Users/me/Skins/Root/Clock/lolcat.png")
        t.equal(OptionValue.path("/Users/me/Skins/Root/@Resources/Images\\lolcat.png", relativeTo: skin),
                "/Users/me/Skins/Root/@Resources/Images/lolcat.png")
        // Details
        t.equal(OptionValue.path("Images\\", relativeTo: skin), "/Users/me/Skins/Root/Clock/Images/")
        t.equal(OptionValue.path("a/./b//c", relativeTo: "/base"), "/base/a/b/c")
        t.equal(OptionValue.path("../../../../../x", relativeTo: "/a/"), "/x")
        t.equal(OptionValue.path("..", relativeTo: "/"), "/")
        t.equal(OptionValue.path(" img.png ", relativeTo: "C:\\Skins\\X"), nil)   // Windows base is unusable
        t.equal(OptionValue.path("img.png", relativeTo: "rel\\dir"), "rel/dir/img.png")
        t.equal(OptionValue.path("../img.png", relativeTo: ""), "../img.png")
        t.equal(OptionValue.path("\\\\server\\share\\x.png", relativeTo: skin), nil)
        t.equal(OptionValue.path("d:/x.png", relativeTo: skin), nil)
        t.equal(OptionValue.path("", relativeTo: skin), nil)
        t.equal(OptionValue.path("   ", relativeTo: skin), nil)
        t.equal(OptionValue.path("~/Pictures/a.png", relativeTo: skin), NSHomeDirectory() + "/Pictures/a.png")
        t.equal(OptionValue.path("~", relativeTo: skin), NSHomeDirectory())
        t.equal(OptionValue.path("Bilder/Grüße.png", relativeTo: "/x"), "/x/Bilder/Grüße.png")
    }

    // ---------------------------------------------------------------------------------------------------------
    // Adversarial review (core/formula-review): corner cases pinned down and regressions for confirmed defects.

    t.suite("OptionValue: review — color corner cases") {
        t.equal(OptionValue.color("255, 0, 0, 50%"), RGBA(r: 255, g: 0, b: 0, a: 50))   // strtod-style component
        t.equal(OptionValue.color(",255,255"), RGBA(r: 0, g: 255, b: 255))             // empty leading component → 0
        t.equal(OptionValue.color("255,0,0,-1"), RGBA(r: 255, g: 0, b: 0, a: 0))        // clamped
        t.equal(OptionValue.color("255.9,0,0"), red)
        t.equal(OptionValue.color("1e2,0,0"), RGBA(r: 100, g: 0, b: 0))
        t.equal(OptionValue.color("255,0,0;"), red)                                     // "0;" reads as 0
        t.equal(OptionValue.color("255,255,255,(0/0)"), RGBA(r: 255, g: 255, b: 255, a: 0))
        t.equal(OptionValue.color("(255 * 0.5), 255, 255, (2 > 1 ? 128 : 0)"), RGBA(r: 127.5, g: 255, b: 255, a: 128))
        // Zero-width characters from copy-pasted text are ignored like whitespace.
        t.equal(OptionValue.color("\u{200B}255,0,0\u{FEFF}"), red)
        t.equal(OptionValue.color("255,\u{200B}0\u{200B},0"), red)
        t.equal(OptionValue.color("\u{FEFF}FF0000"), red)
        t.equal(OptionValue.color("255,(0*-1),0").map { $0.g.sign }, .plus)             // no -0 component
        // 0x-prefixed hex is accepted (docs/compat/engine.md, "Hex colors with a 0x prefix").
        t.equal(OptionValue.color("0xFF0000"), red)
        t.equal(OptionValue.color("0X0000FF80"), RGBA(r: 0, g: 0, b: 255, a: 128))
        for bad in ["255 0 0", "FFF", "FFFF", "#FFFFFF", "0xFFF", "0x", "0xGG0000", "FF0000FF;", "(Max(1,2),3,4", "255,(1,0", "ÿÿÿ",
                    "\u{200B}", "FF00\u{200B}00", "(255)", "255;0;0"] {
            t.equal(OptionValue.color(bad), nil, String(reflecting: bad))
        }
    }

    t.suite("OptionValue: review — position corner cases") {
        t.equal(OptionValue.position("10.5R"), PositionValue(value: 10.5, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("1e1R"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("(5+5) R"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("10r\r\n"), PositionValue(value: 10, mode: .relativeToPreviousStart))
        t.equal(OptionValue.position("10\u{200B}R\u{200B}"), PositionValue(value: 10, mode: .relativeToPreviousEnd))
        t.equal(OptionValue.position("-0r").map { $0.value.sign }, .plus)
        t.equal(OptionValue.position("(0*-1)R").map { $0.value.sign }, .plus)
        t.equal(OptionValue.position("R10"), nil)                                       // suffix must be last
        t.equal(OptionValue.position("-R"), nil)
        t.equal(OptionValue.position("+r"), nil)
        t.equal(OptionValue.position("10ŕ"), PositionValue(value: 10))                  // r + combining accent ≠ r
    }

    t.suite("OptionValue: review — numbers / list / path corner cases") {
        t.equal(OptionValue.numbers(",5"), [0, 5])
        t.equal(OptionValue.numbers("5, ,5,"), [5, 0, 5])
        t.equal(OptionValue.numbers("(1,2),3"), [0, 3])                                  // not a formula
        t.equal(OptionValue.numbers("(Clamp(1,0,2)),x,(Max(1,2))"), [1, 0, 2])
        t.equal(OptionValue.numbers("\u{FEFF}5,\u{200B}10"), [5, 10])
        t.equal(OptionValue.numbers("-0,-0").map { $0.sign }, [.plus, .plus])
        t.equal(OptionValue.list("A||B|(C|D)|  "), ["A", "B", "(C|D)"])
        t.equal(OptionValue.list("\u{200B}StyleA\u{200B} | StyleB\u{FEFF}"), ["StyleA", "StyleB"])
        t.equal(OptionValue.path("\u{FEFF}img.png", relativeTo: "/x/"), "/x/img.png")
        t.equal(OptionValue.int("-0"), 0)
        t.equal(OptionValue.bool("\u{200B}1"), true)
    }
}
