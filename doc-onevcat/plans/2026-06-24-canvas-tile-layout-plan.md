# Canvas Tile Layout（平铺占满视口）

## Context

Prowl 的画布模式（Canvas）当前提供两种卡片排序，入口在 `CanvasView.canvasToolbar`
（`supacode/Features/Canvas/Views/CanvasView.swift`）与命令面板：

| 模式 | 快捷键 | 卡片尺寸 | 算法 | 入口函数 |
|------|--------|---------|------|---------|
| **Organize** | ⌘⌥G | 统一默认尺寸（`adaptiveDefaultCardSize`），**不随卡片当前大小变化** | √N 平衡网格（`gridColumns`/`gridPosition`） | `organizeCards()` |
| **Arrange** | ⌘⌥R | **保留每张卡片当前尺寸** | MaxRects 风格 bin-packing（`CanvasCardPacker`，waterfall vs row-break 竞争） | `arrangeCards()` |

两者都把卡片放进**无限画布坐标系**，再由 `fitToView(canvasSize:)` 计算缩放/平移把整组卡片
塞进视口（缩放上限 1.0，四周留 30pt padding，底部预留 `bottomToolbarReserve = 50`）。

卡片数据是 `CanvasCardLayout { position(center), size }`，存活在 `CanvasLayoutStore`
（`@Observable`，落 UserDefaults `canvasCardLayouts`），`zOrder` 决定渲染层级。

排序的触发是**三通路**复用同一套基建：

1. 工具栏按钮 → `arrangeCardsWithFit()` / `organizeCardsWithFit()`
2. 键盘快捷键 → `body` 的 `.onKeyPress`
3. 命令面板 → `AppFeature+CommandPalette` 发 `.repositories(.requestCanvasCommand(.arrange/.organize))`
   → `CanvasCommandRequest.Command` → `CanvasView+Focus.fulfillCommandRequest()`

## Goal

新增**第三种**布局 **Tile**（⌘⌥T，图标 `rectangle.split.2x1`），定位为
**自动平铺窗口管理器**式排序：把所有打开的卡片**重新调整尺寸**，按规整网格铺满整个可视
画布，让用户用尽可能大的面积组织卡片。

与现有两种的本质区别：Organize 用固定默认尺寸、Arrange 保留卡片原尺寸，而 **Tile 由视口
反推卡片尺寸**——这是它"占满"的关键。

### 行为规格（与 onevcat 对齐确认）

**平衡网格 + 宽高比自适应**：

- 短边（视觉上较短的轴）放 `s = max(1, floor(√N))` 条"线"，N 张卡片在这 `s` 条线上
  尽量均分，多出来的卡片放到**靠后的线**（靠下的行 / 靠右的列）。
- **宽窗口（W ≥ H）→ 线即"行"，左右铺开**；**高窗口（W < H）→ 线即"列"，上下堆叠**。
  这是纯粹的横/纵方向翻转（短边永远放 `floor(√N)` 条线）。
- 每条线**独立铺满整条**：2 卡的行每张占 ½ 宽，3 卡的行每张占 ⅓ 宽（所以不同线上的
  卡片尺寸可以不同——这才是"尽可能大"）。同方向的所有线等分另一轴。

**线分配 `lineCounts(for: N)`**：`base = N / s`，`rem = N % s`；前 `s - rem` 条线各
`base` 张，后 `rem` 条线各 `base + 1` 张。

| N | s = floor(√N) | 分配 | 宽窗口（行） | 高窗口（列） |
|---|---|---|---|---|
| 1 | 1 | [1] | 整屏 1 张 | 整屏 1 张 |
| 2 | 1 | [2] | 左右各半 | 上下各半 |
| 3 | 1 | [3] | 横排 3 | 竖排 3 |
| 4 | 2 | [2,2] | 2×2 | 2×2 |
| 5 | 2 | [2,3] | 上 2 下 3 | 左 2 右 3 |
| 6 | 2 | [3,3] | 2 行 ×3 | 2 列 ×3 |
| 7 | 2 | [3,4] | 上 3 下 4 | 左 3 右 4 |
| 8 | 2 | [4,4] | 2 行 ×4 | 2 列 ×4 |
| 9 | 3 | [3,3,3] | 3×3 | 3×3 |
| 10 | 3 | [3,3,4] | 3 行（3,3,4） | 3 列（3,3,4） |

> 取舍说明：方向自适应是**二元翻转**（看 `W ≥ H`），不做极端宽高比的列数微调（例如
> 32:9 超宽屏 4 张仍是 2×2，而非 1×4）。这保持了与上面确定性例子完全一致的"平衡网格"
> 观感。若日后想要极端比例下进一步铺开，可在 `lineCounts` 上叠加一层 aspect-aware 的
> 候选评分（按最大化最小卡片面积选 `s`），属于后续增强、不在本次范围。

### 缩放策略（已确认 + 自适应增强）

**复用现有 `fitToView`**：Tile 在画布坐标系按视口比例摆好卡片后，调用 `fitToView` 居中并
缩放。因为布局 bounding box 的宽高比 ≈ 视口宽高比，`fitToView` 的 `min(W/bboxW, H/bboxH)`
会让两个方向同时贴合。

**自适应 zoom（v2 增强，回应"字太大、间距偏大"反馈）**：固定 scale=1 时，卡片多→单卡
surface 小→终端行列少→字相对显得大、内容少。改进做法：`layout` 在一个
`viewport × zoom` 的放大画框里铺卡，`fitToView` 自然得到 `scale ≈ 1/zoom`。

- `zoom = max(1, comfortableSize / 单卡 surface)`：卡片本就够大时 `zoom=1`（scale≈1，
  与单窗口体验一致）；卡片缩小到 `comfortableSize` 以下时 `zoom>1`，surface 维持舒适
  尺寸（更多行列、字更小、内容更多）。`comfortableSize = adaptiveDefaultCardSize × 0.6`，
  让少量卡片保持原生 scale，再平滑过渡。
- **间距**：Tile 用更小的 `tileCardSpacing = 14`（其余模式 20）；它活在放大画框里，屏幕
  间距 = `14 × scale`，会随卡片增多自动收紧——同时解决"间距偏大"与"不随尺寸适配"。
- `fitToView` 的 scale 夹在 `[0.25, 1.0]`：`zoom>1 → scale≤1`；极端卡片数 zoom 很大时
  scale 触底 0.25、卡片轻微溢出，属可接受降级。

## 算法细节

新增可单测的纯逻辑类型 `CanvasTileLayout`，与 `CanvasCardPacker` 并列放在
`CanvasCardLayout.swift`：

```
struct CanvasTileLayout {
  var spacing: CGFloat
  var titleBarHeight: CGFloat
  // clamp 边界（minCard*/maxCard*）由调用方传入或用默认

  static func lineCounts(for count: Int) -> [Int]   // 上面的分配规则
  func layout(keys: [String], viewport: CGSize) -> [String: CanvasCardLayout]
}
```

`layout` 几何（以**宽窗口=行**为例，高窗口为对称转置）：

- `rows = lineCounts(for: keys.count)`，`rowVisualHeight = (H - (rows+1)·spacing) / rows`，
  `terminalHeight = rowVisualHeight - titleBarHeight`。
- 第 `r` 行有 `k` 张：`cardWidth = (W - (k+1)·spacing) / k`。
- 卡片中心：`y = spacing + r·(rowVisualHeight + spacing) + rowVisualHeight/2`；
  `x = spacing + i·(cardWidth + spacing) + cardWidth/2`。
- `CanvasCardLayout(position: center, size: CGSize(cardWidth, terminalHeight))`。
  **不做 min/max 夹紧**：tile 的卡片尺寸就是视口除以网格的结果，夹紧只会在窗口过小时
  把卡片撑大到超出格子、造成重叠。min/maxCard 约束属于"手动拖拽 resize"与"新卡默认
  尺寸"的范畴，与 tile 的"按视口铺满"无关。窗口很小时卡片会变小（低于默认尺寸），由
  `fitToView` 负责后续视觉缩放——与 Organize 的降级思路一致，但保证恒不重叠、恰好铺满。

高窗口对称：线=列，`colVisualWidth = (W-(cols+1)·spacing)/cols`，每列 `k` 张时
`cardVisualHeight = (H-(k+1)·spacing)/k`、`terminalHeight = cardVisualHeight - titleBarHeight`。

边界：`count == 0` 或 `viewport` 任一维 ≤ 0 时返回空 dict（调用方 no-op，与 `arrangeCards`
的 guard 一致）。

## 改动清单（按文件）

### 1. 核心算法 — `supacode/Features/Canvas/Models/CanvasCardLayout.swift`
新增 `CanvasTileLayout`（`lineCounts(for:)` + `layout(keys:viewport:)`）。纯函数、无副作用、
`@MainActor` 无关，便于单测。

### 2. 触发逻辑 — `supacode/Features/Canvas/Views/CanvasView.swift`
- `func tileCards()`：取 `collectCardKeys` → `CanvasTileLayout(...).layout(keys:viewport:)`
  → `layoutStore.setCardLayouts(result, zOrder: keys)`（仿 `organizeCards()`）。guard 视口有效。
- `func tileCardsWithFit()`：`withAnimation(.easeInOut(0.2))` 内 `cancelExpandForRelayout()`
  + `tileCards()` + `fitToView(canvasSize: viewportSize)`（仿 `*WithFit`）。
- `body` 顶部新增 `tileCanvasShortcut = AppShortcuts.resolvedShortcut(for: .tileCanvasCards, ...)`。
- 新增一条 `.onKeyPress(tileCanvasShortcut?.keyEquivalent ?? AppShortcuts.tileCanvasCards.keyEquivalent, phases: .down)`，
  模式与 arrange/organize 完全一致（解析为 nil 时 `.ignored`，校验 modifiers）。
- `canvasToolbar` 第三个按钮：`Image(systemName: "rectangle.split.2x1")`，
  `help(AppShortcuts.helpText(title: "Tile cards to fill the canvas", commandID: .tileCanvasCards, ...))`。

### 3. 命令通路（接入 arrange/organize 的全套基建）
- `CanvasFocusRequest.swift`：`CanvasCommandRequest.Command` 加 `case tile`。
- `CanvasView+Focus.swift`：`fulfillCommandRequest` 的 switch 加 `case .tile: tileCardsWithFit()`。
- `AppShortcuts.swift`：
  - `CommandID.tileCanvasCards = "tile_canvas_cards"`（≈ line 143 区）
  - `static let tileCanvasCards = AppShortcut(key: "t", modifiers: [.command, .option])`（≈ line 303）
    —— ⌘⌥T 当前空闲（已核对 ⌘⌥ 已用：p/u/return/[/]/方向键/a/r/g/e）
  - 注册进命令表（≈ line 778-787 区，title `"Tile Canvas Cards"`）
- `AppFeature+CommandPalette.swift`：`case .tileCanvasCards: return .send(.repositories(.requestCanvasCommand(.tile)))`。
- 命令面板枚举/映射四处：`CommandPaletteItem.swift`、`CommandPaletteFeature.swift`
  （`kind` + 注册项 ≈ line 613-620 区）、`CommandPaletteSupport.swift`
  （`globalTileCanvasCards` 常量 + 各 mapping ≈ line 19/192/267/319）、
  `CommandPaletteOverlayView.swift`（各 switch/list ≈ line 525/590/640/775）。
- `ShortcutsSettingsView.swift`：canvas 快捷键列表加 `.tileCanvasCards`（≈ line 942）。

### 4. 测试 — 新建 `supacodeTests/CanvasTileLayoutTests.swift`
- `lineCounts(for:)`：断言 N=1…10 全部命中上表（重点覆盖 5→[2,3]、7→[3,4]、9→[3,3,3]）。
- `layout`：
  - **宽窗口**（如 1600×900）N=2 → 两张左右、各约半宽、等高、无重叠。
  - **高窗口**（如 900×1600）N=2 → 两张上下（方向翻转生效）。
  - N=5 宽窗口 → 上排 2 下排 3，下排卡片更窄。
  - 通用：任意两卡矩形不相交；每行/列铺满对应轴；clamp 在极小视口下生效。
- 复用 `CanvasCardPackerTests` 的无重叠/间距断言风格。

### 5. 文档（同 PR）
- `docs/components/canvas.md`：≈ line 57-59 追加 `⌘⌥T Tile Cards` 段落；line 6 keywords 加 `tile`。
- `docs/reference/keyboard-shortcuts.md`：≈ line 67-68 加一行
  `| Tile Canvas Cards (fill viewport) | ⌘⌥T | \`tile_canvas_cards\` | yes (local) |`，
  必要时更新 line 132 的 local-action 说明。

### 6. 收尾
- 新分支 `feature/canvas-tile-layout`（从最新 `origin/main`）。
- `make build-app`、`make test`（含新测试）、`make check` 全绿。
- 仅提交本次改动文件（不 `git add .`），开 PR 到 `onevcat/Prowl`。

## 验收标准

1. 画布有 2/3/4/5 张卡片时点 Tile，宽窗口下分别得到 左右 / 横排3 / 2×2 / 上2下3。
2. 把窗口拉成竖屏后点 Tile，2 张变上下、3 张变竖排、5 张变左2右3。
3. 卡片铺满可视区域（仅四周少量边距），无重叠、间距一致。
4. 三通路（按钮 / ⌘⌥T / 命令面板 "Tile Canvas Cards"）行为一致。
5. 设置里能看到并改键，禁用后 ⌘⌥T 不触发。
6. `lineCounts` 单测与布局单测通过。
