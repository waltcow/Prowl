import SwiftUI
import Testing

@testable import supacode

struct WindowChromeTintTests {
  // MARK: - fill(mode:customColor:repositoryColor:)

  @Test
  func noneModeNeverDrawsABand() {
    #expect(WindowChromeTint.fill(mode: .none, customColor: nil, repositoryColor: nil) == nil)
    #expect(WindowChromeTint.fill(mode: .none, customColor: .green, repositoryColor: .red) == nil)
  }

  @Test
  func repositoryColorModeUsesRepoColorAtSaturatedAlpha() {
    let fill = WindowChromeTint.fill(mode: .repositoryColor, customColor: nil, repositoryColor: .red)
    #expect(fill == WindowChromeTint.Fill(color: .red, alpha: WindowChromeTint.saturatedPeakAlpha))
  }

  @Test
  func repositoryColorModeFallsBackToNeutralSurfaceWhenUncolored() {
    let fill = WindowChromeTint.fill(mode: .repositoryColor, customColor: nil, repositoryColor: nil)
    #expect(fill == WindowChromeTint.Fill(color: .primary, alpha: WindowChromeTint.neutralPeakAlpha))
  }

  @Test
  func customModeUsesCustomColorAndIgnoresRepoColor() {
    let fill = WindowChromeTint.fill(mode: .custom, customColor: .green, repositoryColor: .red)
    #expect(fill == WindowChromeTint.Fill(color: .green, alpha: WindowChromeTint.saturatedPeakAlpha))
  }

  @Test
  func customModeWithoutAColorDrawsNoBand() {
    #expect(WindowChromeTint.fill(mode: .custom, customColor: nil, repositoryColor: .red) == nil)
  }

  // MARK: - Repository surface helpers (shared with the Shelf spine)

  @Test
  func repositoryPeakAlphaIsGentlerWhenUncolored() {
    #expect(WindowChromeTint.repositoryPeakAlpha(for: nil) == WindowChromeTint.neutralPeakAlpha)
    #expect(WindowChromeTint.repositoryPeakAlpha(for: .blue) == WindowChromeTint.saturatedPeakAlpha)
  }

  // MARK: - TintColor persistence

  @Test
  func tintColorRoundTripsThroughSRGBComponents() throws {
    let original = TintColor(red: 0.2, green: 0.4, blue: 0.6)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TintColor.self, from: data)
    #expect(decoded == original)
  }
}
