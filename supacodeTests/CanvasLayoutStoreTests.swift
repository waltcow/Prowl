import CoreGraphics
import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasLayoutStoreTests {
  @Test func loadsLegacyCardLayoutDictionary() throws {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let legacyLayouts = [
      "tab-a": CanvasCardLayout(position: CGPoint(x: 10, y: 20), size: CGSize(width: 300, height: 200)),
      "tab-b": CanvasCardLayout(position: CGPoint(x: 30, y: 40), size: CGSize(width: 500, height: 400)),
    ]
    let data = try JSONEncoder().encode(legacyLayouts)
    defaults.set(data, forKey: "canvasCardLayouts")

    let store = CanvasLayoutStore(defaults: defaults)

    #expect(store.cardLayouts == legacyLayouts)
    #expect(Set(store.zOrder) == Set(legacyLayouts.keys))
    #expect(store.shouldAutoArrangeOnInitialEntry(for: ["tab-a", "tab-b"]) == false)
  }

  @Test func skipsInitialAutoArrangeWhenCurrentCardsWereLoadedFromStorage() throws {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts([
      "tab-a": CanvasCardLayout(position: CGPoint(x: 10, y: 20)),
      "tab-b": CanvasCardLayout(position: CGPoint(x: 30, y: 40)),
    ])

    let restoredStore = CanvasLayoutStore(defaults: defaults)

    #expect(restoredStore.shouldAutoArrangeOnInitialEntry(for: ["tab-a", "tab-b"]) == false)
    #expect(restoredStore.shouldAutoArrangeOnInitialEntry(for: ["tab-c", "tab-d"]))
  }

  @Test func moveToFrontPersistsZOrder() {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts(
      [
        "tab-a": CanvasCardLayout(position: .zero),
        "tab-b": CanvasCardLayout(position: .zero),
      ],
      zOrder: ["tab-a", "tab-b"]
    )

    store.moveToFront("tab-a")
    let restoredStore = CanvasLayoutStore(defaults: defaults)

    #expect(restoredStore.zOrder == ["tab-b", "tab-a"])
    #expect(restoredStore.zIndex(for: "tab-a") > restoredStore.zIndex(for: "tab-b"))
  }

  @Test func pruneRemovesStaleLayoutsAndZOrder() {
    let defaults = makeDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
    let store = CanvasLayoutStore(defaults: defaults)
    store.setCardLayouts(
      [
        "tab-a": CanvasCardLayout(position: .zero),
        "tab-b": CanvasCardLayout(position: .zero),
      ],
      zOrder: ["tab-a", "tab-b"]
    )

    store.prune(to: ["tab-b"])

    #expect(Array(store.cardLayouts.keys) == ["tab-b"])
    #expect(store.zOrder == ["tab-b"])
  }
}

private func makeDefaults() -> UserDefaults {
  let suiteName = "CanvasLayoutStoreTests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defaults.set(suiteName, forKey: "__suiteName")
  return defaults
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
  defaults.string(forKey: "__suiteName")!
}
