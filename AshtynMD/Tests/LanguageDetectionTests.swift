import Foundation
import Testing
@testable import AshtynMD

@Suite("Language detection")
struct LanguageDetectionTests {
    @Test func extensionsMapToLanguages() {
        let cases: [(String, LanguageID)] = [
            ("note.md", .markdown), ("note.markdown", .markdown),
            ("readme.txt", .plainText),
            ("main.swift", .swift),
            ("script.py", .python),
            ("app.js", .javascript), ("component.jsx", .javascript),
            ("module.mjs", .javascript), ("legacy.cjs", .javascript),
            ("app.ts", .typescript), ("view.tsx", .typescript),
            ("package.json", .json),
            ("config.yaml", .yaml), ("config.yml", .yaml),
            ("index.html", .html), ("page.htm", .html),
            ("style.css", .css),
            ("run.sh", .shell), ("run.bash", .shell), ("run.zsh", .shell),
        ]
        for (name, expected) in cases {
            #expect(LanguageDetector.detect(fileName: name, contents: nil) == expected, "\(name)")
        }
    }

    @Test func extensionMatchingIsCaseInsensitive() {
        #expect(LanguageDetector.detect(fileName: "NOTE.MD", contents: nil) == .markdown)
    }

    @Test func overrideBeatsExtension() {
        let detected = LanguageDetector.detect(
            fileName: "data.json", contents: "{}", override: .yaml
        )
        #expect(detected == .yaml)
    }

    @Test func shebangDetection() {
        #expect(LanguageDetector.detect(fileName: "deploy", contents: "#!/bin/bash\necho hi\n") == .shell)
        #expect(LanguageDetector.detect(fileName: "tool", contents: "#!/usr/bin/env python3\nprint()\n") == .python)
        #expect(LanguageDetector.detect(fileName: "cli", contents: "#!/usr/bin/env node\n") == .javascript)
        #expect(LanguageDetector.detect(fileName: "z", contents: "#!/usr/bin/env zsh\n") == .shell)
    }

    @Test func extensionBeatsShebang() {
        // Detection order: extension comes before shebang.
        let detected = LanguageDetector.detect(
            fileName: "script.py", contents: "#!/bin/bash\n"
        )
        #expect(detected == .python)
    }

    @Test func contentDetection() {
        #expect(LanguageDetector.detect(fileName: "page", contents: "<!DOCTYPE html>\n<html></html>") == .html)
        #expect(LanguageDetector.detect(fileName: "data", contents: "{\"a\": 1}") == .json)
        #expect(LanguageDetector.detect(fileName: "notes", contents: "just some words") == .plainText)
    }

    @Test func bracesAloneAreNotJSON() {
        #expect(LanguageDetector.detect(fileName: "x", contents: "{not json at all") == .plainText)
    }

    @Test func fenceAliases() {
        #expect(LanguageDetector.language(forFenceIdentifier: "swift") == .swift)
        #expect(LanguageDetector.language(forFenceIdentifier: "py") == .python)
        #expect(LanguageDetector.language(forFenceIdentifier: "js") == .javascript)
        #expect(LanguageDetector.language(forFenceIdentifier: "TS") == .typescript)
        #expect(LanguageDetector.language(forFenceIdentifier: "shellscript") == .shell)
        #expect(LanguageDetector.language(forFenceIdentifier: "") == nil)
        #expect(LanguageDetector.language(forFenceIdentifier: "made-up-lang") == nil)
    }

    @Test func everyLanguageHasADefinition() {
        for id in LanguageID.allCases {
            #expect(LanguageDefinition.definition(for: id).id == id)
        }
    }
}
