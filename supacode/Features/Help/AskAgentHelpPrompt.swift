import Foundation

/// User-facing strings for the "Ask an agent about Prowl" help dialog.
///
/// `prompt` is the copyable text the user hands to their AI agent; the rest is
/// chrome for the dialog itself. Everything is localized to the user's device
/// language so the prompt is transparent at a glance, and every prompt also
/// asks the agent to answer in the user's preferred language.
nonisolated struct AskAgentHelpStrings: Equatable, Sendable {
  var title: String
  var explanation: String
  var prompt: String
  var copyButtonTitle: String
  var copiedButtonTitle: String
  var doneButtonTitle: String
}

/// Builds the localized "Ask an agent" help content. Pure and locale-driven so
/// it can be unit-tested without a running app.
nonisolated enum AskAgentHelpPrompt {
  enum LanguageKey: Equatable, Sendable {
    case english
    case simplifiedChinese
    case traditionalChinese
    case japanese
  }

  /// Resolve which prompt language to use from a locale. Chinese disambiguates
  /// Hans/Hant by script, falling back to region (TW/HK/MO → Traditional).
  /// Anything we don't translate falls back to English (which still asks the
  /// agent to reply in the user's preferred language).
  static func languageKey(for locale: Locale) -> LanguageKey {
    switch locale.language.languageCode?.identifier {
    case "ja":
      return .japanese
    case "zh":
      if let script = locale.language.script?.identifier {
        return script == "Hant" ? .traditionalChinese : .simplifiedChinese
      }
      switch locale.region?.identifier {
      case "TW", "HK", "MO":
        return .traditionalChinese
      default:
        return .simplifiedChinese
      }
    default:
      return .english
    }
  }

  static func strings(docsDirectoryPath: String, locale: Locale = .current) -> AskAgentHelpStrings {
    let readme = "\(docsDirectoryPath)/README.md"
    let overview = "\(docsDirectoryPath)/overview.md"
    switch languageKey(for: locale) {
    case .english:
      return english(readme: readme, overview: overview)
    case .simplifiedChinese:
      return simplifiedChinese(readme: readme, overview: overview)
    case .traditionalChinese:
      return traditionalChinese(readme: readme, overview: overview)
    case .japanese:
      return japanese(readme: readme, overview: overview)
    }
  }

  // MARK: - English

  private static func english(readme: String, overview: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "Ask an agent about Prowl",
      explanation:
        "Copy this prompt and paste it into your coding agent (Claude Code, Codex, …) "
        + "in a terminal, or any AI assistant. It points the agent at the documentation "
        + "bundled inside Prowl and asks it to introduce Prowl and suggest features useful to you.",
      prompt: """
        Read Prowl's bundled documentation and introduce it to me.

        Prowl is a native macOS command center for running many AI coding agents in parallel. \
        Its full manual ships inside the app:

        - Index:      \(readme)
        - Highlights: \(overview)

        Read those two first — the index links to per-feature manuals in the same folder; \
        open whichever are relevant. Then:

        1. Briefly tell me what Prowl is and why it's worth my time.
        2. Based on what you know about how I work (my projects, tools, and habits), suggest \
        3–4 Prowl features or workflows that would genuinely help me — one line of "how" each.
        3. Then let me ask follow-up questions, consulting the matching file in that folder as needed.

        Reply in my preferred language.
        """,
      copyButtonTitle: "Copy Prompt",
      copiedButtonTitle: "Copied!",
      doneButtonTitle: "Done"
    )
  }

  // MARK: - Simplified Chinese

  private static func simplifiedChinese(readme: String, overview: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "让 agent 介绍 Prowl",
      explanation:
        "复制这段提示词，粘贴给你在终端里的编码 agent（Claude Code、Codex…）或任意 AI 助手。"
        + "它会让 agent 读取 Prowl 内置的文档，介绍 Prowl 并推荐对你有用的功能。",
      prompt: """
        阅读 Prowl 自带的文档，并向我介绍它。

        Prowl 是一款原生 macOS 指挥中心，用来并行运行多个 AI 编码 agent。它的完整说明书就打包在 app 内：

        - 索引：    \(readme)
        - 亮点：    \(overview)

        请先读这两份——索引里链接了各功能的分册（在同一文件夹下），按需打开相关的。然后：

        1. 简要告诉我 Prowl 是什么、为什么值得我花时间。
        2. 结合你对我工作方式的了解（我的项目、工具和习惯），推荐 3–4 个真正能帮到我的 Prowl 功能或用法，每个配一句“怎么用”。
        3. 之后让我继续追问，按需查阅该文件夹下对应的文档。

        请用我的首选语言回答。
        """,
      copyButtonTitle: "复制提示词",
      copiedButtonTitle: "已复制！",
      doneButtonTitle: "完成"
    )
  }

  // MARK: - Traditional Chinese

  private static func traditionalChinese(readme: String, overview: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "讓 agent 介紹 Prowl",
      explanation:
        "複製這段提示詞，貼給你在終端機裡的編碼 agent（Claude Code、Codex…）或任意 AI 助手。"
        + "它會讓 agent 讀取 Prowl 內建的文件，介紹 Prowl 並推薦對你有用的功能。",
      prompt: """
        閱讀 Prowl 內建的文件，並向我介紹它。

        Prowl 是一款原生 macOS 指揮中心，用來並行執行多個 AI 編碼 agent。它的完整說明書就打包在 app 內：

        - 索引：    \(readme)
        - 亮點：    \(overview)

        請先讀這兩份——索引裡連結了各功能的分冊（在同一資料夾下），按需開啟相關的。然後：

        1. 簡要告訴我 Prowl 是什麼、為什麼值得我花時間。
        2. 結合你對我工作方式的了解（我的專案、工具和習慣），推薦 3–4 個真正能幫到我的 Prowl 功能或用法，每個配一句「怎麼用」。
        3. 之後讓我繼續追問，按需查閱該資料夾下對應的文件。

        請用我的首選語言回答。
        """,
      copyButtonTitle: "複製提示詞",
      copiedButtonTitle: "已複製！",
      doneButtonTitle: "完成"
    )
  }

  // MARK: - Japanese

  private static func japanese(readme: String, overview: String) -> AskAgentHelpStrings {
    AskAgentHelpStrings(
      title: "エージェントに Prowl を尋ねる",
      explanation:
        "このプロンプトをコピーして、ターミナルのコーディングエージェント（Claude Code、Codex など）"
        + "や任意の AI アシスタントに貼り付けてください。Prowl に同梱されたドキュメントを読ませ、"
        + "Prowl の紹介とあなたに役立つ機能の提案をしてもらえます。",
      prompt: """
        Prowl に同梱されているドキュメントを読んで、私に紹介してください。

        Prowl は、複数の AI コーディングエージェントを並行して動かすためのネイティブ macOS \
        コマンドセンターです。完全なマニュアルはアプリ内に同梱されています：

        - 索引：      \(readme)
        - ハイライト： \(overview)

        まずこの2つを読んでください。索引から各機能のマニュアル（同じフォルダ内）にリンクしているので、\
        関連するものを開いてください。そのうえで：

        1. Prowl が何で、なぜ使う価値があるのかを簡潔に教えてください。
        2. 私の働き方（プロジェクト・ツール・習慣）について知っていることを踏まえて、本当に役立つ \
        Prowl の機能や使い方を3〜4個、それぞれ「どう使うか」を一言添えて提案してください。
        3. その後の私の質問にも、同じフォルダ内の該当ドキュメントを参照しながら答えてください。

        私の優先言語で回答してください。
        """,
      copyButtonTitle: "プロンプトをコピー",
      copiedButtonTitle: "コピーしました！",
      doneButtonTitle: "完了"
    )
  }
}
