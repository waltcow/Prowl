import CoreGraphics
import Testing

@testable import supacode

struct CanvasTileLayoutTests {
  private let titleBarHeight: CGFloat = 28
  private let spacing: CGFloat = 20

  private var tiler: CanvasTileLayout {
    CanvasTileLayout(spacing: spacing, titleBarHeight: titleBarHeight)
  }

  private func keys(_ count: Int) -> [String] {
    (0..<count).map { "card\($0)" }
  }

  /// Visual rect (terminal + title bar) of a laid-out card, used for overlap checks.
  private func visualRect(_ layout: CanvasCardLayout) -> CGRect {
    let width = layout.size.width
    let height = layout.size.height + titleBarHeight
    return CGRect(
      x: layout.position.x - width / 2,
      y: layout.position.y - height / 2,
      width: width,
      height: height
    )
  }

  private func assertNoOverlap(_ rects: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
    for outer in 0..<rects.count {
      for inner in (outer + 1)..<rects.count {
        // Shrink by a hair to tolerate shared spacing edges.
        let lhs = rects[outer].insetBy(dx: 0.5, dy: 0.5)
        let rhs = rects[inner].insetBy(dx: 0.5, dy: 0.5)
        #expect(!lhs.intersects(rhs), sourceLocation: sourceLocation)
      }
    }
  }

  // MARK: - lineCounts

  @Test func lineCountsMatchBalancedGridSpec() {
    #expect(CanvasTileLayout.lineCounts(for: 0) == [])
    #expect(CanvasTileLayout.lineCounts(for: 1) == [1])
    #expect(CanvasTileLayout.lineCounts(for: 2) == [2])
    #expect(CanvasTileLayout.lineCounts(for: 3) == [3])
    #expect(CanvasTileLayout.lineCounts(for: 4) == [2, 2])
    #expect(CanvasTileLayout.lineCounts(for: 5) == [2, 3])
    #expect(CanvasTileLayout.lineCounts(for: 6) == [3, 3])
    #expect(CanvasTileLayout.lineCounts(for: 7) == [3, 4])
    #expect(CanvasTileLayout.lineCounts(for: 8) == [4, 4])
    #expect(CanvasTileLayout.lineCounts(for: 9) == [3, 3, 3])
    #expect(CanvasTileLayout.lineCounts(for: 10) == [3, 3, 4])
  }

  @Test func lineCountsAlwaysSumToTotal() {
    for count in 1...50 {
      #expect(CanvasTileLayout.lineCounts(for: count).reduce(0, +) == count)
    }
  }

  // MARK: - Empty / guard

  @Test func emptyKeysProduceNoLayouts() {
    #expect(tiler.layout(keys: [], viewport: CGSize(width: 1600, height: 900)).isEmpty)
  }

  @Test func zeroViewportProducesNoLayouts() {
    #expect(tiler.layout(keys: keys(3), viewport: .zero).isEmpty)
  }

  // MARK: - Orientation

  @Test func wideViewportPlacesTwoCardsSideBySide() throws {
    let layouts = tiler.layout(keys: keys(2), viewport: CGSize(width: 1600, height: 900))
    let left = try #require(layouts["card0"])
    let right = try #require(layouts["card1"])

    // Same row → equal y, distinct x, left card first.
    #expect(left.position.y == right.position.y)
    #expect(left.position.x < right.position.x)
    // Each fills roughly half the width.
    #expect(abs(left.size.width - right.size.width) < 0.001)
    #expect(left.size.width < 1600 / 2)
  }

  @Test func tallViewportStacksTwoCardsVertically() throws {
    let layouts = tiler.layout(keys: keys(2), viewport: CGSize(width: 900, height: 1600))
    let top = try #require(layouts["card0"])
    let bottom = try #require(layouts["card1"])

    // Single column → equal x, distinct y, top card first.
    #expect(top.position.x == bottom.position.x)
    #expect(top.position.y < bottom.position.y)
    #expect(abs(top.size.height - bottom.size.height) < 0.001)
  }

  @Test func wideFiveCardsFormTopTwoBottomThree() throws {
    let layouts = tiler.layout(keys: keys(5), viewport: CGSize(width: 1600, height: 900))
    let topRow = try [layouts["card0"], layouts["card1"]].map { try #require($0) }
    let bottomRow = try [layouts["card2"], layouts["card3"], layouts["card4"]].map { try #require($0) }

    // Top row of 2 shares one y; bottom row of 3 shares a larger y.
    #expect(topRow[0].position.y == topRow[1].position.y)
    #expect(bottomRow[0].position.y == bottomRow[1].position.y)
    #expect(bottomRow[1].position.y == bottomRow[2].position.y)
    #expect(bottomRow[0].position.y > topRow[0].position.y)
    // 3-card row cards are narrower than 2-card row cards.
    #expect(bottomRow[0].size.width < topRow[0].size.width)
  }

  // MARK: - Fill & non-overlap

  @Test func cardsNeverOverlap() throws {
    let viewports = [CGSize(width: 1600, height: 900), CGSize(width: 900, height: 1600)]
    for viewport in viewports {
      for count in 1...12 {
        let layouts = tiler.layout(keys: keys(count), viewport: viewport)
        #expect(layouts.count == count)
        assertNoOverlap(layouts.values.map(visualRect))
      }
    }
  }

  @Test func eachRowFillsViewportWidth() throws {
    let width: CGFloat = 1600
    let layouts = tiler.layout(keys: keys(3), viewport: CGSize(width: width, height: 900))
    let rects = (0..<3).compactMap { layouts["card\($0)"] }.map(visualRect)
    let minX = rects.map(\.minX).min()!
    let maxX = rects.map(\.maxX).max()!
    // Row spans from the left spacing to the right spacing of the viewport.
    #expect(abs(minX - spacing) < 0.001)
    #expect(abs(maxX - (width - spacing)) < 0.001)
  }

  // MARK: - Small viewports

  @Test func smallViewportTilesExactlyWithoutClamping() throws {
    // Tile sizes cards by dividing the viewport, so a small viewport yields
    // small cards (below default sizes) rather than overlapping ones — fitToView
    // handles the visual scaling afterwards.
    let layouts = tiler.layout(keys: keys(4), viewport: CGSize(width: 400, height: 300))
    let rects = (0..<4).compactMap { layouts["card\($0)"] }.map(visualRect)
    // 2×2 grid: each cell is well under the 300pt default minimum width.
    #expect(rects.allSatisfy { $0.width < 300 })
    assertNoOverlap(rects)
  }
}
