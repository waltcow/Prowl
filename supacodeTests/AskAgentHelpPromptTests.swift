import Foundation
import Testing

@testable import supacode

struct AskAgentHelpPromptTests {
  @Test func languageKeyMapsCommonLocales() {
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "en_US")) == .english)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "ja_JP")) == .japanese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "fr_FR")) == .english)
  }

  @Test func chineseDisambiguatesByScriptThenRegion() {
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_CN")) == .simplifiedChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_TW")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh_HK")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hant")) == .traditionalChinese)
    #expect(AskAgentHelpPrompt.languageKey(for: Locale(identifier: "zh-Hans")) == .simplifiedChinese)
  }

  @Test func promptEmbedsResolvedDocPaths() {
    let docs = "/Applications/Prowl.app/Contents/Resources/docs"
    let strings = AskAgentHelpPrompt.strings(docsDirectoryPath: docs, locale: Locale(identifier: "en_US"))
    #expect(strings.prompt.contains("\(docs)/README.md"))
    #expect(strings.prompt.contains("\(docs)/overview.md"))
  }

  @Test func everyLanguageAsksToReplyInPreferredLanguage() {
    let docs = "/Applications/Prowl.app/Contents/Resources/docs"
    let locales = ["en_US", "zh_CN", "zh_TW", "ja_JP"]
    for identifier in locales {
      let strings = AskAgentHelpPrompt.strings(docsDirectoryPath: docs, locale: Locale(identifier: identifier))
      #expect(!strings.prompt.isEmpty)
      #expect(!strings.title.isEmpty)
      #expect(strings.prompt.contains(docs))
    }
  }

  @Test func localizedTitlesDiffer() {
    let docs = "/tmp/docs"
    let english = AskAgentHelpPrompt.strings(docsDirectoryPath: docs, locale: Locale(identifier: "en_US"))
    let japanese = AskAgentHelpPrompt.strings(docsDirectoryPath: docs, locale: Locale(identifier: "ja_JP"))
    let simplified = AskAgentHelpPrompt.strings(docsDirectoryPath: docs, locale: Locale(identifier: "zh_CN"))
    #expect(english.prompt != japanese.prompt)
    #expect(english.prompt != simplified.prompt)
    #expect(english.copyButtonTitle == "Copy Prompt")
  }
}
