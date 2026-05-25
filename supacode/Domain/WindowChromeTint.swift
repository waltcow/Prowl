import AppKit
import SwiftUI

/// Unified color logic for the window *chrome* tint — the nav-panel band
/// behind the floating glass sidebar and the toolbar band behind the
/// transparent titlebar — shared across every view mode (Normal, Shelf,
/// Canvas).
///
/// The tint is "driven from the detail side": both bands are overlays on
/// the full-bleed detail content that bleed up under the titlebar and left
/// under the sidebar glass, so one resolved color paints the nav and the
/// toolbar as a single continuous "L".
///
/// `WindowTintMode` selects the source:
/// - `.none` ⇒ no band (neutral system chrome).
/// - `.repositoryColor` ⇒ the active repo's pinned color, or a neutral
///   surface when uncolored — the same `repositoryBase`/`repositoryPeakAlpha`
///   pair the Shelf spine uses, so the chrome and the open spine match.
/// - `.custom` ⇒ a single user-chosen color, ignoring per-repo colors.
enum WindowChromeTint {
  struct RGBComponents: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color {
      Color(.sRGB, red: red, green: green, blue: blue)
    }

    var luminance: Double {
      0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
  }

  /// A resolved chrome band: a base color plus the alpha it should be
  /// filled at. `nil` from `fill(...)` means "draw no band".
  struct Fill: Equatable {
    var color: Color
    var alpha: Double
  }

  /// Peak fill alpha for a saturated tint (a colored repo, or a custom
  /// color). Matches the Shelf spine's open-book peak so the chrome and
  /// the spine read at the same intensity.
  static let saturatedPeakAlpha: Double = 0.20
  /// Gentler peak for the neutral fallback: `Color.primary` reads as a
  /// distinct panel at far lower opacity than a saturated hue, so 0.20
  /// would look like a glaring mid-gray instead of the subtle near-black /
  /// near-white surface we want.
  static let neutralPeakAlpha: Double = 0.10

  /// Base hue for a repository-color surface: the pinned color, or
  /// `Color.primary` for the neutral fallback. Used by the Shelf spine
  /// (always) and by `.repositoryColor` chrome bands.
  static func repositoryBase(for color: RepositoryColorChoice?) -> Color {
    color?.color ?? .primary
  }

  /// Peak alpha for a repository-color surface — the saturated peak for a
  /// pinned color, the neutral peak when uncolored.
  static func repositoryPeakAlpha(for color: RepositoryColorChoice?) -> Double {
    color == nil ? neutralPeakAlpha : saturatedPeakAlpha
  }

  /// Resolves the chrome band for the given tint mode. Returns `nil` when
  /// no band should be drawn (`.none`, or `.custom` without a color).
  ///
  /// - Parameters:
  ///   - mode: the user's window tint mode.
  ///   - customColor: the user's custom color, for `.custom` mode.
  ///   - repositoryColor: the active repo's pinned color (the open book in
  ///     Shelf, the selected worktree's repo in Normal, the focused card's
  ///     repo in Canvas), used by `.repositoryColor` mode.
  static func fill(
    mode: WindowTintMode,
    customColor: Color?,
    repositoryColor: RepositoryColorChoice?
  ) -> Fill? {
    switch mode {
    case .none:
      return nil
    case .repositoryColor:
      return Fill(
        color: repositoryBase(for: repositoryColor),
        alpha: repositoryPeakAlpha(for: repositoryColor)
      )
    case .custom:
      guard let customColor else { return nil }
      return Fill(color: customColor, alpha: saturatedPeakAlpha)
    }
  }

  /// Resolves a chrome surface background to an opaque sRGB color under
  /// the requested app appearance. `toolbarBackground` sits on the real
  /// AppKit toolbar surface, so a translucent semantic color can otherwise
  /// be resolved against the system appearance captured when the app
  /// launched. Shelf spines use this same precomposed color so the open
  /// spine and toolbar read as one continuous surface in light and dark
  /// appearances.
  static func surfaceBackgroundComponents(
    fill: Fill?,
    colorScheme: ColorScheme
  ) -> RGBComponents {
    let base = resolvedComponents(for: NSColor.windowBackgroundColor, colorScheme: colorScheme)
    guard let fill else {
      return base
    }

    let overlay = resolvedComponents(for: fill.color, colorScheme: colorScheme)
    let alpha = min(max(fill.alpha, 0), 1)
    return RGBComponents(
      red: overlay.red * alpha + base.red * (1 - alpha),
      green: overlay.green * alpha + base.green * (1 - alpha),
      blue: overlay.blue * alpha + base.blue * (1 - alpha)
    )
  }

  private static func resolvedComponents(for color: Color, colorScheme: ColorScheme) -> RGBComponents {
    resolvedComponents(for: NSColor(color), colorScheme: colorScheme)
  }

  private static func resolvedComponents(for color: NSColor, colorScheme: ColorScheme) -> RGBComponents {
    withAppearance(for: colorScheme) {
      let resolved = color.usingColorSpace(.sRGB) ?? fallbackColor(for: colorScheme)
      return RGBComponents(
        red: Double(resolved.redComponent),
        green: Double(resolved.greenComponent),
        blue: Double(resolved.blueComponent)
      )
    }
  }

  private static func withAppearance<T>(for colorScheme: ColorScheme, _ body: () -> T) -> T {
    guard let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) else {
      return body()
    }

    var result: T?
    appearance.performAsCurrentDrawingAppearance {
      result = body()
    }
    return result!
  }

  private static func fallbackColor(for colorScheme: ColorScheme) -> NSColor {
    colorScheme == .dark ? .black : .white
  }
}

extension View {
  /// Overlays chrome tint bands on full-bleed detail content. The bands
  /// fill the safe-area insets the window reserves for the toolbar (top)
  /// and the floating sidebar (leading), bleeding past them via
  /// `ignoresSafeArea` so the color reaches under the titlebar / sidebar
  /// glass. A `nil` fill draws nothing.
  ///
  /// - Parameters:
  ///   - fill: the resolved band fill, or `nil` for no tint.
  ///   - edges: which chrome regions to tint — `.top` (toolbar) and/or
  ///     `.leading` (nav). Normal uses both; Canvas uses `.leading` only.
  func windowChromeTint(_ fill: WindowChromeTint.Fill?, edges: Edge.Set) -> some View {
    modifier(WindowChromeTintModifier(fill: fill, edges: edges))
  }

  /// Sets the real SwiftUI/AppKit window toolbar background. This is kept
  /// separate from `windowChromeTint`: the tint bands color the content
  /// behind full-bleed chrome, while the toolbar itself must also have an
  /// explicit background because macOS can stop sampling that content when
  /// a window is zoomed or fullscreen.
  func windowToolbarChromeBackground(_ fill: WindowChromeTint.Fill?) -> some View {
    modifier(WindowToolbarChromeBackgroundModifier(fill: fill))
  }
}

/// Measures the toolbar (top) and sidebar (leading) safe-area insets of
/// the detail content and paints a band into each requested edge.
private struct WindowChromeTintModifier: ViewModifier {
  let fill: WindowChromeTint.Fill?
  let edges: Edge.Set

  @State private var topInset: CGFloat = 0
  @State private var leadingInset: CGFloat = 0

  func body(content: Content) -> some View {
    content
      // Content draws under the transparent titlebar, so the top
      // safe-area inset equals the toolbar/titlebar height — exactly the
      // region the top band should fill.
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.top
      } action: {
        topInset = $0
      }
      // The detail is laid out full-bleed beneath the floating glass
      // sidebar, so the leading inset equals the sidebar width — the span
      // the leading band fills to color the nav.
      .onGeometryChange(for: CGFloat.self) {
        $0.safeAreaInsets.leading
      } action: {
        leadingInset = $0
      }
      .overlay(alignment: .top) {
        if let fill, edges.contains(.top) {
          band(fill)
            .frame(height: topInset)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(.container, edges: .top)
        }
      }
      .overlay(alignment: .leading) {
        if let fill, edges.contains(.leading) {
          band(fill)
            .frame(width: leadingInset)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.leading, .top, .bottom])
        }
      }
  }

  private func band(_ fill: WindowChromeTint.Fill) -> some View {
    fill.color
      .opacity(fill.alpha)
      .allowsHitTesting(false)
  }
}

private struct WindowToolbarChromeBackgroundModifier: ViewModifier {
  let fill: WindowChromeTint.Fill?
  @Environment(\.colorScheme) private var colorScheme

  @ViewBuilder
  func body(content: Content) -> some View {
    let background = WindowChromeTint.surfaceBackgroundComponents(
      fill: fill,
      colorScheme: colorScheme
    ).color

    content
      .toolbarBackground(background, for: .windowToolbar)
      .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
  }
}
