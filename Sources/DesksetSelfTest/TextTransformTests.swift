import Foundation
@testable import DesksetCore

fileprivate func pair(_ pattern: String, _ replacement: String) -> SubstituteRules.Pair {
    SubstituteRules.Pair(pattern: pattern, replacement: replacement)
}

fileprivate func substitute(_ option: String, regex: Bool = false, _ text: String) -> String {
    SubstituteRules(option, regex: regex).apply(to: text)
}

func runTextTransformTests(_ t: TestRunner) {
    // MARK: Substitute

    t.suite("TextTransform: Substitute parsing") {
        t.equal(SubstituteRules(#""This":"That""#, regex: false).pairs, [pair("This", "That")])
        // The INI reader strips the quotes around the whole value.
        t.equal(SubstituteRules(#"This":"That"#, regex: false).pairs, [pair("This", "That")])
        t.equal(SubstituteRules(#""2012":"Twenty Twelve","2013":"Twenty Thirteen""#, regex: false).pairs,
                [pair("2012", "Twenty Twelve"), pair("2013", "Twenty Thirteen")])
        t.equal(SubstituteRules(#"2012":"Twenty Twelve","2013":"Twenty Thirteen"#, regex: false).pairs,
                [pair("2012", "Twenty Twelve"), pair("2013", "Twenty Thirteen")])
        // Single quotes around either side.
        t.equal(SubstituteRules(#"'"':"double quote""#, regex: false).pairs, [pair("\"", "double quote")])
        t.equal(SubstituteRules(#""None":'"'"#, regex: false).pairs, [pair("None", "\"")])
        t.equal(SubstituteRules(#"'"':"""#, regex: false).pairs, [pair("\"", "")])
        t.equal(SubstituteRules(#"'"':"","a":"b""#, regex: false).pairs, [pair("\"", ""), pair("a", "b")])
        t.equal(SubstituteRules(#"a":"b",'"':"c"#, regex: false).pairs, [pair("a", "b"), pair("\"", "c")])
        // Both single-quoted: documented as failing in Rainmeter, accepted here.
        t.equal(SubstituteRules("'red':'blue'", regex: false).pairs, [pair("red", "blue")])
        // Empty pattern / replacement.
        t.equal(SubstituteRules(#""":"No Moe!""#, regex: false).pairs, [pair("", "No Moe!")])
        t.equal(SubstituteRules(#"":"No Moe!"#, regex: false).pairs, [pair("", "No Moe!")])
        t.equal(SubstituteRules(#"":""#, regex: false).pairs, [pair("", "")])
        t.equal(SubstituteRules(#""a":"""#, regex: false).pairs, [pair("a", "")])
        t.equal(SubstituteRules(#"a":"#, regex: false).pairs, [pair("a", "")])
        // Whitespace and trailing comma.
        t.equal(SubstituteRules(#" "a" : "b" , "c":"d" , "#, regex: false).pairs, [pair("a", "b"), pair("c", "d")])
        // Edge whitespace of a quote-stripped value belongs to the pattern / replacement.
        t.equal(SubstituteRules(#"\s+":" "#, regex: true).pairs, [pair(#"\s+"#, " ")])
        t.equal(SubstituteRules(#" a":"b "#, regex: false).pairs, [pair(" a", "b ")])
        // Quotes protect separators.
        t.equal(SubstituteRules(#""a,b":"c:d","e":"f""#, regex: false).pairs, [pair("a,b", "c:d"), pair("e", "f")])
        // Regex patterns with quotes / commas / braces.
        t.equal(SubstituteRules(#"(\w+) (\w+) (\w+)":"\3, \1 \2","Rainy":"Yoda"#, regex: true).pairs,
                [pair(#"(\w+) (\w+) (\w+)"#, #"\3, \1 \2"#), pair("Rainy", "Yoda")])
        t.equal(SubstituteRules(#"^(\d{1,3}).(\d{1,3}).(\d{1,3}).\d{1,3}$":"\1.\2.\3.***"#, regex: true).pairs,
                [pair(#"^(\d{1,3}).(\d{1,3}).(\d{1,3}).\d{1,3}$"#, #"\1.\2.\3.***"#)])
        t.equal(SubstituteRules(#"'"(.*)"':"\1""#, regex: true).pairs, [pair(#""(.*)""#, #"\1"#)])
        // Lenient fallbacks.
        t.equal(SubstituteRules("a:b,c:d", regex: false).pairs, [pair("a", "b"), pair("c", "d")])
        t.equal(SubstituteRules(#""a":"b","c""#, regex: false).pairs, [pair("a", "b")])
        t.equal(SubstituteRules("", regex: false).pairs, [])
        t.equal(SubstituteRules("   ", regex: false).pairs, [])
        t.check(SubstituteRules("", regex: false).isEmpty)
        t.equal(SubstituteRules("x", regex: true).isRegex, true)
        t.equal(SubstituteRules(pairs: [pair("a", "b")], isRegex: false), SubstituteRules(#""a":"b""#, regex: false))
    }

    t.suite("TextTransform: Substitute plain") {
        // Manual examples
        t.equal(substitute(#""2012":"Twenty Twelve","2013":"Twenty Thirteen""#, "2012"), "Twenty Twelve")
        t.equal(substitute(#"2012":"Twenty Twelve","2013":"Twenty Thirteen"#, "2013"), "Twenty Thirteen")
        t.equal(substitute(#""This":"That","Here":"There""#, "This is Here, This"), "That is There, That")
        t.equal(substitute(#""1":"One","10":"Ten""#, "10"), "One0")
        t.equal(substitute(#""10":"Ten","1":"One""#, "10"), "Ten")
        t.equal(substitute(#""1":"One","10":"Ten""#, "1 10 11"), "One One0 OneOne")
        t.equal(substitute(#"'"':"double quote""#, #"say "x""#), "say double quotexdouble quote")
        t.equal(substitute(#"'"':"""#, #""quoted" text"#), "quoted text")
        t.equal(substitute(#""None":'"'"#, "None"), "\"")
        // Tip "Substituted values in a Calc"
        t.equal(substitute(#""2":"22","4":"7""#, "12345"), "122375")
        t.equal(substitute(#""Running":"1","Offline":"0""#, "Running"), "1")
        // Tip "Lookahead assertions": an empty value becomes the replacement.
        t.equal(substitute(#"":"No Moe!"#, ""), "No Moe!")
        t.equal(substitute(#"":"No Moe!"#, "Larry"), "Larry")
        // Case-sensitive, literal, empty replacement removes.
        t.equal(substitute(#""a":"b""#, "Aa"), "Ab")
        t.equal(substitute(#"".":"!""#, "a.b.c"), "a!b!c")
        t.equal(substitute(#""x":"""#, "axbxc"), "abc")
        t.equal(substitute(#""é":"e""#, "café é"), "cafe e")
        t.equal(substitute(#""ab":"b""#, "aabb"), "abb", "one pass, no re-scan of replaced text")
        t.equal(SubstituteRules(pairs: [], isRegex: false).apply(to: "same"), "same")
    }

    t.suite("TextTransform: Substitute regex") {
        // Manual examples
        t.equal(substitute(#"(\w+) (\w+) (\w+)":"\3, \1 \2","Rainy":"Yoda"#, regex: true, "I am Rainy"), "Yoda, I am")
        t.equal(substitute(#"^(.{0,5}).+$":"\1..."#, regex: true, "Hello, world!"), "Hello...")
        t.equal(substitute(#"^(\d{1,3}).(\d{1,3}).(\d{1,3}).\d{1,3}$":"\1.\2.\3.***"#, regex: true, "192.168.1.101"),
                "192.168.1.***")
        // \0 is the whole match; every occurrence is replaced.
        t.equal(substitute(#"\d+":"<\0>"#, regex: true, "a12b3"), "a<12>b<3>")
        // Matching empty values.
        t.equal(substitute(#"^$":"empty"#, regex: true, ""), "empty")
        t.equal(substitute(#"^$":"empty"#, regex: true, "x"), "x")
        t.equal(substitute(#"":"none"#, regex: true, ""), "none")
        t.equal(substitute(#"":"none"#, regex: true, "abc"), "abc")
        // Empty captures insert nothing and do not stop later pairs (history r2922+).
        t.equal(substitute(#"(a*)b":"[\1]","\[\]":"E"#, regex: true, "b"), "E")
        t.equal(substitute(#"(x)?y":"<\1>"#, regex: true, "y"), "<>")
        t.equal(substitute(#"(a)":"\5\1"#, regex: true, "a"), "a")
        // Template details
        t.equal(substitute(#"a":"$1 \n $0"#, regex: true, "a"), #"$1 \n $0"#)
        t.equal(substitute(#"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)":"\10\1"#, regex: true, "abcdefghij"), "ja")
        t.equal(substitute(#"(a)":"\10"#, regex: true, "a"), "a0")
        t.equal(substitute(#"(a)":"\\1"#, regex: true, "a"), #"\a"#)
        // PCRE features in patterns.
        t.equal(substitute(#"(?U)<.*>":"""#, regex: true, "<b>bold</b> text"), "bold text")
        t.equal(substitute(#"(?i)hello":"bye"#, regex: true, "HeLLo hello"), "bye bye")
        t.equal(substitute(#"\s+":" "#, regex: true, "a \t\n b"), "a b")
        t.equal(substitute(#"x*":"-"#, regex: true, "abc"), "-a-b-c-")
        t.equal(substitute(#"^\s+|\s+$":""#, regex: true, "  trim me  "), "trim me")
        t.equal(substitute(#"&amp;":"&","&lt;":"<"#, regex: true, "a &amp; b &lt; c"), "a & b < c")
        t.equal(substitute(#"\w+":"X"#, regex: true, "héllo wörld"), "X X")
        // An invalid pattern is skipped, the rest still applies.
        t.equal(substitute(#"(":"x","a":"b"#, regex: true, "a("), "b(")
        // Order: each pair works on the previous result.
        t.equal(substitute(###"\d":"#","##":"X"###, regex: true, "a12b3"), "aXb#")
    }

    t.suite("TextTransform: replacement templates") {
        typealias P = PCRE.TemplatePart
        t.equal(PCRE.templateParts(#"a\1b\12\0"#, groupCount: 1),
                [P.literal("a"), .group(1), .literal("b"), .group(1), .literal("2"), .group(0)])
        t.equal(PCRE.templateParts(#"\12"#, groupCount: 12), [P.group(12)])
        t.equal(PCRE.templateParts(#"\123"#, groupCount: 12), [P.group(12), .literal("3")])
        t.equal(PCRE.templateParts(#"\01"#, groupCount: 12), [P.group(0), .literal("1")])
        t.equal(PCRE.templateParts(#"\"#, groupCount: 3), [P.literal("\\")])
        t.equal(PCRE.templateParts(#"\x\"#, groupCount: 3), [P.literal(#"\x\"#)])
        t.equal(PCRE.templateParts("", groupCount: 3), [])
        t.equal(PCRE.expandTemplate(#"a\1b"#, groups: []), "ab")
        t.equal(PCRE.replaceAll(#"(\w)(\d)"#, in: "a1 b2", template: #"\2\1"#), "1a 2b")
        t.equal(PCRE.replaceAll("(", in: "x", template: ""), nil)
    }

    // MARK: PCRE → ICU

    t.suite("TextTransform: PCRE ungreedy (?U)") {
        t.equal(PCRE.toICU("(?siU)<title>(.*)</title>"), "(?si)<title>(.*?)</title>")
        t.equal(PCRE.toICU("(?U)a+b*c?d{1,3}e{2,}f{3}"), "a+?b*?c??d{1,3}?e{2,}?f{3}")
        t.equal(PCRE.toICU("(?U)a+?b*?c??d{1,3}?e{2,}?"), "a+b*c?d{1,3}e{2,}")
        // Possessive quantifiers ignore U (emitted as atomic groups, see the review regressions suite).
        t.equal(PCRE.toICU("(?U)a++b*+c?+d{1,2}+"), "(?>a+)(?>b*)(?>c?)(?>d{1,2})")
        t.equal(PCRE.toICU(#"(?U)\*+\++\?*\{2}"#), #"\*+?\++?\?*?\{2\}"#)
        t.equal(PCRE.toICU("(?U)[*+?{}]+"), #"[*+?\{\}]+?"#)
        t.equal(PCRE.toICU(#"(?U)\Q.*\E*"#), #"\Q.*\E*?"#)
        t.equal(PCRE.toICU("(?U:a*)b*"), "(?:a*?)b*")
        t.equal(PCRE.toICU("a*(?U)b*(?-U)c*"), "a*b*?c*")
        t.equal(PCRE.toICU("(a(?U)b*|c*)d*"), "(ab*?|c*?)d*", "option lasts to the end of its group, across |")
        t.equal(PCRE.toICU("(?iU)a*"), "(?i)a*?")
        t.equal(PCRE.toICU("(?U)(?i-U)a*"), "(?i)a*")
        t.equal(PCRE.toICU("(?U)(a*(?:b+)(?=c*))"), "(a*?(?:b+?)(?=c*?))")
        t.equal(PCRE.toICU("a*b+?"), "a*b+?", "no U: unchanged")
        // Behaviour: the WebParser examples from the manual and tutorials.
        let items = "<Item>A</Item> <Item>B</Item> <Item>C</Item>"
        t.equal(PCRE.captures("(?siU)<Item>(.*)</Item>.*<Item>(.*)</Item>", in: items),
                ["<Item>A</Item> <Item>B</Item>", "A", "B"])
        t.equal(PCRE.captures("(?si)<Item>(.*)</Item>", in: items)?[1], "A</Item> <Item>B</Item> <Item>C",
                "without U the match is greedy")
        let rss = "<rss><channel>\n<title>Site</title>\n<item>\n<title>First</title>\n<link>https://a/1</link>\n</item>"
            + "<item><title>Second</title><link>https://a/2</link></item></channel></rss>"
        t.equal(PCRE.captures("(?siU)<title>(.*)</title>.*<item>.*<title>(.*)</title>.*<link>(.*)</link>", in: rss)?
                    .dropFirst().map { $0 },
                ["Site", "First", "https://a/1"])
        let html = """
            <tr><td width="100">Your IP Address:</td><td>72.205.25.79</td></tr>
            <tr><td>Country:</td><td> <img src="flags/us.png"> United States</td></tr>
            <tr><td>Region:</td><td>Virginia</td></tr>
            """
        t.equal(PCRE.captures(#"(?siU)<td.*>Your IP Address.*<td>(.*)</td>.*<td.*>Country:.*<img src="(.*)"> (.*)</td>.*<td>Region.*<td>(.*)</td>"#,
                              in: html)?.dropFirst().map { $0 },
                ["72.205.25.79", "flags/us.png", "United States", "Virginia"])
        t.equal(PCRE.captures(#"(?siU)data-ip="(.*)""#, in: #"<span data-ip="68.100.86.32" x="y">"#)?[1],
                "68.100.86.32")
    }

    t.suite("TextTransform: PCRE conditionals (WebParser lookahead tip)") {
        t.equal(PCRE.toICU("(?(?=a)ab|cd)"), "(?:(?=a)ab|(?!a)cd)")
        t.equal(PCRE.toICU("(?(?!a)x)"), "(?:(?!a)x|(?=a))")
        t.equal(PCRE.toICU("(?(?<=a)b|c)"), "(?:(?<=a)b|(?<!a)c)")
        t.equal(PCRE.toICU("(?(?<!a)b|c)"), "(?:(?<!a)b|(?<=a)c)")
        t.equal(PCRE.toICU("(?U)(?(?=.*x).*y)"), "(?:(?=.*?x).*?y|(?!.*?x))")
        // Captures inside the assertion are not duplicated in the negated copy.
        t.equal(PCRE.toICU("(?(?=(a))(a)|b)(c)"), "(?:(?=(a))(a)|(?!(?:a))b)(c)")
        t.equal(PCRE.captures("(?(?=(a))(a)|b)(c)", in: "ac"), ["ac", "a", "a", "c"])
        t.equal(PCRE.captures("(?(?=(a))(a)|b)(c)", in: "bc"), ["bc", "", "", "c"])
        // The manual's example: three optional items, only two present.
        let file = """
            <HTML>
            \t<BODY>
            \t\t<Item>
            \t\t\t<Name>Larry</Name>
            \t\t</Item>
            \t\t<Item>
            \t\t\t<Name>Curly</Name>
            \t\t</Item>
            \t</BODY>
            </HTML>
            """
        let get = "(?(?=.*<Item>).*<Name>(.*)</Name>)"
        let found = PCRE.captures("(?siU)" + get + get + get, in: file)
        t.equal(found?.dropFirst().map { $0 }, ["Larry", "Curly", ""])
        t.equal(SubstituteRules(#"":"No Moe!"#, regex: false).apply(to: found?[3] ?? "?"), "No Moe!")
        // Without the conditional the plain version fails, as the tip says.
        t.equal(PCRE.captures("(?siU)<Item>.*<Name>(.*)</Name>.*<Item>.*<Name>(.*)</Name>.*<Item>.*<Name>(.*)</Name>.*",
                              in: file), nil)
        // Group-reference conditions: best effort (either branch).
        t.equal(PCRE.toICU(#"(<)?\w+(?(1)>)"#), #"(<)?\w+(?:>|)"#)
        t.equal(PCRE.matches(#"^(<)?\w+(?(1)>|)$"#, in: "<abc>"), true)
        t.equal(PCRE.matches(#"^(<)?\w+(?(1)>|)$"#, in: "abc"), true)
        t.equal(PCRE.toICU("(?(<name>)a|b)"), "(?:a|b)")
        // DEFINE never matches its body but keeps group numbering.
        t.equal(PCRE.toICU(#"(?(DEFINE)(?<d>\d))x"#), #"(?:(?!)(?:(?<d>\d)))?x"#)
        t.equal(PCRE.captures(#"(?(DEFINE)(\d))(x)"#, in: "x"), ["x", "", "x"])
        // Nested conditionals are bounded.
        let nested = String(repeating: "(?(?=a)", count: 20) + "a" + String(repeating: ")", count: 20)
        t.equal(PCRE.regex(nested), nil)
        t.check(PCRE.regex(String(repeating: "(?(?=a)", count: 4) + "a" + String(repeating: ")", count: 4)) != nil)
    }

    t.suite("TextTransform: PCRE literal braces and character classes") {
        t.equal(PCRE.toICU("a{"), #"a\{"#)
        t.equal(PCRE.toICU("{"), #"\{"#)
        t.equal(PCRE.toICU("}"), #"\}"#)
        t.equal(PCRE.toICU("a{,3}"), #"a\{,3\}"#)
        t.equal(PCRE.toICU("x{a}"), #"x\{a\}"#)
        t.equal(PCRE.toICU("a{2}b{2,}c{2,3}"), "a{2}b{2,}c{2,3}")
        t.equal(PCRE.toICU("[{}]"), #"[\{\}]"#)
        t.equal(PCRE.toICU("[a&&b]"), #"[a\&\&b]"#)
        t.equal(PCRE.toICU("[[]"), #"[\[]"#)
        t.equal(PCRE.toICU("[]a]"), #"[\]a]"#)
        t.equal(PCRE.toICU("[^]a]"), #"[^\]a]"#)
        t.equal(PCRE.toICU("[+--]"), #"[+-\-]"#)
        t.equal(PCRE.toICU(#"[a-\d]"#), #"[a\-\d]"#)
        t.equal(PCRE.toICU(#"[\d-z]"#), #"[\d\-z]"#)
        t.equal(PCRE.toICU("[$#]"), ##"[\$\#]"##)
        t.equal(PCRE.toICU("[ a]"), #"[\x{20}a]"#)
        t.equal(PCRE.toICU(#"[\b]"#), #"[\x{8}]"#)
        t.equal(PCRE.toICU(#"[\Q]-\E]"#), #"[\x{5d}\x{2d}]"#)
        t.equal(PCRE.toICU("[[:alpha:]_]"), "[[a-zA-Z]_]")
        t.equal(PCRE.toICU("[[:^digit:]]"), "[[^0-9]]")
        t.equal(PCRE.toICU("[[:alpha:]-z]"), #"[[a-zA-Z]\-z]"#)
        t.equal(PCRE.toICU("[[:nope:]]"), #"[\[\:nope\:]]"#)
        // Behaviour
        t.equal(PCRE.captures(#"(?siU)"temp":(.*),"#, in: #"{"temp":21.5,"x":{"y":1}}"#)?[1], "21.5")
        t.equal(PCRE.matches(#"\{"a":\d+\}"#, in: #"{"a":12}"#), true)
        t.equal(PCRE.matches("[{}]", in: "{"), true)
        t.equal(PCRE.matches("^[^{}]+$", in: "abc"), true)
        t.equal(PCRE.matches("[a&&b]", in: "&"), true)
        t.equal(PCRE.matches("[+--]", in: ","), true)
        t.equal(PCRE.matches("^[+--]$", in: "."), false)
        t.equal(PCRE.matches(#"[\d-z]"#, in: "-"), true)
        t.equal(PCRE.matches("[[:punct:]]", in: "$"), true, "PCRE's POSIX punct includes symbols")
        t.equal(PCRE.matches("^[[:alpha:]]+$", in: "abcXYZ"), true)
        t.equal(PCRE.matches("^[[:alpha:]]+$", in: "é"), false, "POSIX classes are ASCII in PCRE")
        t.equal(PCRE.matches("^[[:xdigit:]]+$", in: "0fA9"), true)
        t.equal(PCRE.matches("^[[:space:]]+$", in: " \t\n\r\u{0B}\u{0C}"), true)
        t.equal(PCRE.matches("^[[:word:]]+$", in: "a_1"), true)
        t.equal(PCRE.matches("(?x)[ ]", in: " "), true, "extended mode does not touch classes")
        t.equal(PCRE.matches("(?x)[#]", in: "#"), true)
        t.equal(PCRE.matches(#"[\b]"#, in: "\u{8}"), true)
        t.equal(PCRE.matches(#"^[\Q]-\E]+$"#, in: "]-"), true)
        t.equal(PCRE.matches("[]a]", in: "]"), true)
    }

    t.suite("TextTransform: PCRE groups, names and references") {
        t.equal(PCRE.toICU(#"(?P<year>\d{4})-(?P=year)"#), #"(?<year>\d{4})-\k<year>"#)
        t.equal(PCRE.toICU(#"(?'n'a)\k'n'\k{n}\g{n}\k<n>"#), #"(?<n>a)\k<n>\k<n>\k<n>\k<n>"#)
        t.equal(PCRE.toICU(#"(?<first_name>a)\k<first_name>"#), #"(?<firstx5fname>a)\k<firstx5fname>"#)
        t.equal(PCRE.toICU(#"(?<_x>a)"#), #"(?<x5fx>a)"#)
        t.equal(PCRE.toICU(#"(?<a1>a)"#), #"(?<a1>a)"#)
        t.equal(PCRE.captures(#"(?<first_name>\w+) (?P=first_name)"#, in: "bob bob"), ["bob bob", "bob"])
        t.equal(PCRE.toICU(#"(a)\1"#), #"(a)(?:\1)"#)
        t.equal(PCRE.toICU(#"(a)\g1\g{1}\g{-1}\g-1"#), #"(a)(?:\1)(?:\1)(?:\1)(?:\1)"#)
        t.equal(PCRE.captures(#"(a)(b)\g{-2}\g{-1}"#, in: "abab")?[0], "abab")
        t.equal(PCRE.toICU("(?:a)(?>b)(?=c)(?!d)(?<=e)(?<!f)"), "(?:a)(?>b)(?=c)(?!d)(?<=e)(?<!f)")
        t.equal(PCRE.toICU("(?|(a)|(b))"), "(?:(a)|(b))")
        t.equal(PCRE.matches("^(?|(a)|(b))$", in: "b"), true)
        t.equal(PCRE.toICU("(?#comment)a(?# another )b"), "ab")
        t.equal(PCRE.toICU("(?X)(?J)a"), "a")
        t.equal(PCRE.toICU("(?sm-i)a"), "(?sm-i)a")
        t.equal(PCRE.toICU("(?)a"), "a")
        t.equal(PCRE.toICU("(?-U)a*"), "a*")
        t.equal(PCRE.toICU("(?x: a b )c"), "(?:ab)c")
        t.equal(PCRE.toICU("(?x) a b # comment\n c"), "abc")
        t.equal(PCRE.toICU(#"(?x)a\ b"#), #"a\x{20}b"#)
        t.equal(PCRE.toICU("(?x)a + b"), "a+b")
        t.equal(PCRE.matches(#"(?x)^ a \  b $  # spaced out"#, in: "a b"), true)
        t.equal(PCRE.matches("(?i)GREEN", in: "green"), true)
        t.equal(PCRE.matches("abc", in: "ABC", caseInsensitive: true), true)
        t.equal(PCRE.matches("abc", in: "ABC"), false)
        // Ten or more groups: \10 is a back reference only when group 10 exists.
        t.equal(PCRE.toICU(#"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)\10"#), #"(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(?:\10)"#)
        t.equal(PCRE.toICU(#"(a)\10"#), #"(a)\x{8}"#)
    }

    t.suite("TextTransform: PCRE escapes") {
        t.equal(PCRE.toICU(#"\h\H\v\V\R\X\d\D\w\W\s\S\t\n\r\f\e\a"#), #"\h\H\v\V\R\X\d\D\w\W\s\S\t\n\r\f\e\a"#)
        t.equal(PCRE.toICU(#"\N"#), #"[^\n]"#)
        t.equal(PCRE.toICU(#"\pL\p{^L}\PL\P{^Lu}\p{L&}\p{Greek}"#), #"\p{L}\P{L}\P{L}\p{Lu}\p{LC}\p{Greek}"#)
        t.equal(PCRE.toICU(#"\p{Xan}\p{Xwd}\p{Xsp}\P{Xps}"#), #"[\p{L}\p{N}][\p{L}\p{N}_]\s\S"#)
        t.equal(PCRE.toICU(#"\x41\x{263A}\x"#), #"\x{41}\x{263a}\x{0}"#)
        t.equal(PCRE.toICU(#"\o{101}\101\0\012\07"#), #"\x{41}\x{41}\x{0}\x{a}\x{7}"#)
        t.equal(PCRE.toICU(#"\y\q\i"#), "yqi")
        t.equal(PCRE.toICU(#"a\E"#), "a")
        t.equal(PCRE.toICU(#"\Qa.b\E"#), #"\Qa.b\E"#)
        t.equal(PCRE.toICU(#"\Q\E"#), "")
        t.equal(PCRE.toICU(#"\Qa(b"#), #"\Qa(b\E"#)
        t.equal(PCRE.toICU(#"a\Kb"#), "ab")
        t.equal(PCRE.toICU(#"\C"#), #"[\s\S]"#)
        t.equal(PCRE.toICU(#"\cA\b\B\A\z\Z\G"#), #"\x{1}\b\B\A\z\Z\G"#)
        t.equal(PCRE.toICU(##"\.\*\/\-\<\"\#"##), ##"\.\*\/\-\<\"\#"##)
        t.equal(PCRE.matches(#"^\x{263A}$"#, in: "☺"), true)
        t.equal(PCRE.matches(#"^\101\x42\o{103}$"#, in: "ABC"), true)
        t.equal(PCRE.matches(#"^a\h+b$"#, in: "a \t b"), true)
        t.equal(PCRE.matches(#"^\N+$"#, in: "abc"), true)
        t.equal(PCRE.matches(#"^\N+$"#, in: "a\nb"), false)
        t.equal(PCRE.matches(#"^\p{Han}+$"#, in: "日本"), true)
        t.equal(PCRE.matches(#"\Qa.b\E"#, in: "a.b"), true)
        t.equal(PCRE.matches(#"\Qa.b\E"#, in: "axb"), false)
        t.equal(PCRE.matches(#"\yes"#, in: "yes"), true)
        t.equal(PCRE.matches("(?s)a.b", in: "a\nb"), true)
        t.equal(PCRE.matches("a.b", in: "a\nb"), false)
        t.equal(PCRE.matches("(?m)^b$", in: "a\nb\nc"), true)
        t.equal(PCRE.matches("^b$", in: "a\nb\nc"), false)
        t.equal(PCRE.captures(#"(\d+)\s*°"#, in: "Temp 21 °C")?[1], "21")
        // Escaped space / tab / non-ASCII characters are literals.
        t.equal(PCRE.toICU("a\\ b\\\tc\\é"), #"a\x{20}b\x{9}c\x{e9}"#)
        t.equal(PCRE.matches("^a\\ b\\\tc\\é$", in: "a b\tcé"), true)
        // All matches with their ranges.
        let all = PCRE.allMatches(#"\d+"#, in: "a1b22c333")
        t.equal(all?.map { $0.range.length }, [1, 2, 3])
        t.equal(PCRE.allMatches("(", in: "x")?.count, nil)
        t.equal(PCRE.allMatches("z", in: "abc")?.count, 0)
    }

    t.suite("TextTransform: PCRE verbs, unsupported and invalid patterns") {
        t.equal(PCRE.toICU("(*UTF8)(*UCP)(*CRLF)(*LIMIT_MATCH=10)a"), "a")
        t.equal(PCRE.toICU("a(*FAIL)|b(*F)"), "a(?!)|b(?!)")
        t.equal(PCRE.toICU("a(*SKIP)(*F)|b"), "a(?!)|b")
        t.equal(PCRE.toICU("a(*PRUNE)(*COMMIT)(*THEN)(*MARK:x)(*:y)(*ACCEPT)b"), "ab")
        t.equal(PCRE.replaceAll("a(*SKIP)(*F)|b", in: "ab", template: "X"), "aX")
        // Recursion / subroutine calls cannot be expressed in ICU.
        t.equal(PCRE.regex("(a|(?R))"), nil)
        t.equal(PCRE.regex("(a)(?1)"), nil)
        t.equal(PCRE.regex("(a)(?-1)"), nil)
        t.equal(PCRE.regex("(?<n>a)(?&n)"), nil)
        t.equal(PCRE.regex("(?P<n>a)(?P>n)"), nil)
        t.equal(PCRE.regex(#"(a)\g<1>"#), nil)
        t.equal(PCRE.regex("(*NOPE)a"), nil)
        t.equal(PCRE.matches("(a|(?R))", in: "a"), nil)
        // Invalid in PCRE as well.
        for bad in ["(", "[a", "a)", "*a", "a**", "(?<1a>x)", "(?Z)", "x{2,1}", "\\", #"\x{zz}"#, #"(a)\2"#] {
            t.equal(PCRE.regex(bad), nil, bad)
        }
        t.equal(PCRE.captures("(", in: "("), nil)
        t.equal(PCRE.matches("[", in: "["), nil)
        // Valid, empty pattern.
        t.check(PCRE.regex("") != nil)
        t.equal(PCRE.matches("", in: "abc"), true)
        t.equal(PCRE.matches("(?U)(?x)  ", in: ""), true)
        t.equal(PCRE.captures("x", in: "abc"), nil, "no match")
    }

    t.suite("TextTransform: IfMatch manual examples") {
        // https://docs.rainmeter.net/manual/measures/general-options/ifmatchactions/ — value "Red, Green, Blue"
        let value = "Red, Green, Blue"
        for pattern in ["Red, Green, Blue", "Green", "(?i)green", "^Red", "Blue$", "Red|Blue"] {
            t.equal(PCRE.matches(pattern, in: value), true, pattern)
        }
        // The manual lists `(?=Blue)(?=Red)` as true, but two lookaheads at one position can never both hold in PCRE
        // either; the intended "AND" test is written with `.*`:
        t.equal(PCRE.matches("(?=.*Blue)(?=.*Red)", in: value), true)
        t.equal(PCRE.matches("(?=.*Blue)(?=.*Purple)", in: value), false)
        t.equal(PCRE.matches("Purple", in: value), false)
        t.equal(PCRE.matches("green", in: value), false)
        t.equal(PCRE.matches("Saturday|Sunday", in: "Saturday, March 5, 2022"), true)
        t.equal(PCRE.matches("Saturday|Sunday", in: "Monday, March 7, 2022"), false)
    }

    t.suite("TextTransform: EscapeRegExp") {
        let raw = #"1+1=2 (really?) [ok] {x} a|b $5 ^ \ ."#
        t.equal(PCRE.escape(raw), #"1\+1=2 \(really\?\) \[ok] \{x} a\|b \$5 \^ \\ \."#)
        t.equal(PCRE.matches("^" + PCRE.escape(raw) + "$", in: raw), true)
        t.equal(PCRE.escape("plain"), "plain")
        t.equal(PCRE.escape(""), "")
        t.equal(PCRE.escape("日本.txt"), #"日本\.txt"#)
    }

    t.suite("TextTransform: regex cache and time limit") {
        let first = PCRE.regex("(?siU)<a>(.*)</a>")
        t.check(first != nil)
        t.check(first === PCRE.regex("(?siU)<a>(.*)</a>"), "compiled once")
        t.check(first !== PCRE.regex("(?siU)<a>(.*)</a>", caseInsensitive: true), "flags are part of the key")
        t.equal(PCRE.regex("(unclosed"), nil)
        t.equal(PCRE.regex("(unclosed"), nil)
        for index in 0 ..< 700 { _ = PCRE.regex("cache-\(index)") }
        t.check(PCRERegexCache.shared.count <= 512)
        // Concurrent use from many threads.
        DispatchQueue.concurrentPerform(iterations: 2000) { index in
            let pattern = "(?U)x\(index % 37).*y"
            _ = PCRE.matches(pattern, in: "x\(index % 37)aaay")
            _ = SubstituteRules(#""a":"b","(\d)":"<\1>""#, regex: index % 2 == 0).apply(to: "a1b2")
        }
        t.check(true)
        // Catastrophic backtracking is abandoned instead of hanging: two time-outs of 1 s of CPU time each, which is
        // several seconds of real time on a busy CI runner.
        let start = Date()
        let evil = String(repeating: "a", count: 40) + "b"
        t.equal(PCRE.matches("(a+)+$", in: evil), nil)
        t.equal(SubstituteRules(#"(a+)+$":"x"#, regex: true).apply(to: evil), evil)
        t.check(Date().timeIntervalSince(start) < 30, "time limit not applied: \(Date().timeIntervalSince(start)) s")
    }

    t.suite("TextTransform: review regressions") {
        // Expected values below were cross-checked against Perl's regex engine (PCRE semantics).

        // 1. `:` inside a character class. ICU reads `[:` as the start of a `[:Property:]` set when a `:]` follows
        //    anywhere later, so these ordinary PCRE patterns did not compile at all.
        t.equal(PCRE.toICU("[:=]"), #"[\:=]"#)
        t.equal(PCRE.toICU("[^:]"), #"[^\:]"#)
        t.check(PCRE.regex(#"[:=]\s*([^:]*)"#) != nil)
        t.equal(PCRE.captures(#"[:=]\s*([^:]*)"#, in: "key= value:rest"), ["= value", "value"])
        t.equal(PCRE.captures(#"(\d+)[:.](\d+)[^:]"#, in: "12:34a"), ["12:34a", "12", "34"])
        // Under U the `\s*` is lazy too, so the space lands in the capture (Perl: `\s*?(.*?)`).
        t.equal(PCRE.captures(#"(?siU)Time[:=]\s*(.*)[;:]"#, in: "time: 12;x:y"), ["time: 12;", " 12"])
        t.equal(PCRE.matches("^[:]$", in: ":"), true)
        t.equal(PCRE.matches("[a:]{2}", in: "x:a"), true)
        t.equal(PCRE.captures("[[:alpha:]:]+", in: "ab:c1")?[0], "ab:c")
        t.equal(substitute(#"[:]":"-"#, regex: true, "12:34:56"), "12-34-56")
        t.equal(substitute(#"^[^:]+:\s*(.*?)\s*$":"\1"#, regex: true, "Name:  Bob  "), "Bob")

        // 2. Possessive quantifiers over a body that can match empty. ICU's own `*+` / `++` never match then;
        //    they are emitted as the equivalent atomic groups.
        t.equal(PCRE.toICU("a*+"), "(?>a*)")
        t.equal(PCRE.toICU("(a|)*+x"), "(?>(a|)*)x")
        t.equal(PCRE.toICU(#"\Qab\E++"#), #"(?>\Qab\E+)"#)
        t.equal(PCRE.captures("(a|)*+x", in: "x"), ["x", ""])
        t.equal(PCRE.captures("(x?)++y", in: "y"), ["y", ""])
        t.equal(PCRE.captures("(?:a|b|)++c", in: "abc"), ["abc"])
        t.equal(PCRE.matches("()*+", in: ""), true)
        // Possessive semantics are kept: no giving back.
        t.equal(PCRE.matches("^a++a", in: "aaa"), false)
        t.equal(PCRE.captures(#"(\d)*+(\d)"#, in: "123"), nil)
        t.equal(PCRE.matches("(?:ab|a)++b", in: "aab"), false)
        t.equal(PCRE.captures("(?:ab|a)*+b", in: "aab"), ["b"])
        t.equal(PCRE.captures(#"(?U)"(.*+)""#, in: #""a" "b""#), nil, "possessive ignores U and eats the quote")
        t.equal(PCRE.captures(#"(?U)<(\w++)>"#, in: "<abc>")?[1], "abc")

        // 3. The INI reader strips a pair of *single* quotes around the whole value as well, so options whose
        //    first pattern and last replacement are single-quoted (allowed by the manual) arrive without them.
        t.equal(SubstituteRules(#""':"x","y":'""#, regex: false).pairs, [pair("\"", "x"), pair("y", "\"")])
        t.equal(SubstituteRules(#"'"':"x","y":'"'"#, regex: false).pairs, [pair("\"", "x"), pair("y", "\"")])
        t.equal(SubstituteRules(#"a':"b","c":'d"#, regex: false).pairs, [pair("a", "b"), pair("c", "d")])
        t.equal(SubstituteRules("\"\":'\"'", regex: false).pairs, [pair("", "\"")])
        // Swap straight quotes and apostrophes: `'"':"'","'":'"'` as stored after INI unquoting.
        t.equal(substitute(#""':"'","'":'""#, #"say "hi" it's"#), #"say "hi" it"s"#)
        t.equal(substitute(#""':"","'":'""#, #"a"b'c"#), #"ab"c"#)

        // 4. PCRE hyphen rules inside classes (Perl-verified): a range needs a single character on both sides; a
        //    literal hyphen at the start / after a range can start a new range, one next to a set cannot.
        t.equal(PCRE.matches("^[--/]$", in: "."), true)
        t.equal(PCRE.matches("^[a-f--/]$", in: "."), true)
        t.equal(PCRE.matches("^[a-f--/]$", in: "g"), false)
        t.equal(PCRE.matches("^[:-@--/[]$", in: "."), true)
        t.equal(PCRE.matches(#"^[\d--/]$"#, in: "."), false)
        t.equal(PCRE.matches(#"^[\d--/]$"#, in: "/"), true)
        t.equal(PCRE.matches("^[[:alpha:]--/]$", in: "."), false)
        t.equal(PCRE.matches("^[a-c-e]$", in: "-"), true)
        t.equal(PCRE.matches("^[a-c-e]$", in: "d"), false)
        t.equal(PCRE.matches("^[a-c-e]$", in: "e"), true)
        t.equal(PCRE.matches("^[%--]$", in: "-"), true)
        t.equal(PCRE.matches("^[%--]$", in: "."), false)
        t.equal(PCRE.matches(#"^[a-\d]$"#, in: "-"), true)
        t.equal(PCRE.toICU("[--/]"), #"[\--/]"#)
        t.equal(PCRE.toICU("[a-c-e]"), #"[a-c\-e]"#)

        // 5. `\cX` follows PCRE (upper-case, then flip bit 6), not ICU's `& 0x1F`.
        t.equal(PCRE.matches(#"^\c?$"#, in: "\u{7F}"), true)
        t.equal(PCRE.matches(#"^\c$$"#, in: "d"), true)
        t.equal(PCRE.matches(#"^\ca$"#, in: "\u{01}"), true)
        t.equal(PCRE.matches(#"^[\c?]$"#, in: "\u{7F}"), true)
        t.equal(PCRE.matches(#"^[\c;]$"#, in: "{"), true)
        t.equal(PCRE.regex(#"\c"#), nil)

        // 6. Known ICU engine bugs stay bounded by the time limit (no hang): up to three time-outs of 1 s of CPU time
        //    each, which can be many seconds of real time on a busy CI runner.
        let start = Date()
        _ = PCRE.matches(#"(?:\s*)+?b"#, in: " cb")
        _ = PCRE.matches(#"()*?\Z"#, in: ":")
        _ = SubstituteRules(#"(?U)(?:\s*)+b":"x"#, regex: true).apply(to: " cb")
        t.check(Date().timeIntervalSince(start) < 60,
                "ICU lazy-empty-loop bug must not hang: \(Date().timeIntervalSince(start)) s")
    }

    t.suite("TextTransform: malformed input never crashes") {
        var generator = TransformRandom(seed: 7)
        let alphabet = Array(#"()[]{}?*+\|^$.-:<>=!'&#aPpkgxQEU0123 "#)
        let start = Date()
        for _ in 0 ..< 3000 {
            let length = Int(generator.next() % 30)
            let pattern = String((0 ..< length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
            _ = PCRE.toICU(pattern)
            _ = PCRE.matches(pattern, in: "a(b)[c]{d}")
            _ = SubstituteRules(pattern, regex: true).apply(to: "abc")
            _ = SubstituteRules(pattern, regex: false).apply(to: "abc")
        }
        // Deep nesting and long patterns stay bounded.
        _ = PCRE.toICU(String(repeating: "(", count: 20_000) + String(repeating: ")", count: 20_000))
        t.equal(PCRE.regex(String(repeating: "(", count: 20_000) + "a" + String(repeating: ")", count: 20_000)), nil)
        t.check(PCRE.regex(String(repeating: "(a)", count: 5_000)) != nil)
        _ = PCRE.toICU(String(repeating: "[", count: 20_000))
        _ = PCRE.toICU(String(repeating: #"\"#, count: 20_001))
        _ = SubstituteRules(String(repeating: #""a":"b","#, count: 5_000), regex: false).apply(to: "aaa")
        t.equal(SubstituteRules(String(repeating: #""a":"b","#, count: 5_000), regex: false).pairs.count, 5_000)
        t.check(Date().timeIntervalSince(start) < 20, "fuzzing took too long")
    }
}

/// Deterministic PRNG for the fuzz tests.
fileprivate struct TransformRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
