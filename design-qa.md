# Design QA — Light technology network backdrop

- Source visual truth: `/var/folders/fs/t96_fl155zddkwkd9wb44l980000gn/T/codex-clipboard-b1013dce-8cf2-45d5-b2a4-06253751c5a8.png`
- Implementation evidence: `cua://native-app/Codex Harbor/main-AppWindow-1@2026-10-21T16:10:00+08:00`
- Viewport/state: maximized macOS app window, light appearance, 工作台, Codex configured, system proxy managed, ChatGPT MCP connected
- Source pixels: 2159 × 728
- Implementation capture pixels: 2702 × 1578; native SwiftUI viewport approximately 1351 × 789 points at 2× density
- Density normalization: the source is a panoramic background asset rather than a full-screen mock. Comparison used the visible top technology panel at its aspect-fill crop; no browser/device frame was involved.

## Full-view comparison evidence

- The new background retains the source's pale ice-blue globe, cyan/green/violet light ribbons, central illuminated platform, and dotted world map.
- The workbench remains visually lighter than the prior navy panel and now blends with the white app shell and blue sidebar.
- Existing Codex, Network Core, and ChatGPT circular connection treatments remain in their original positions and proportions.
- Existing route curves and compositor-driven moving particles were not modified.
- The three functional status cards below remain visible and unchanged.

## Focused-region comparison evidence

The top technology panel was inspected at full window scale because this change is limited to that region. The generated background is sharp at the installed window size, the globe/platform crop remains centered behind Network Core, and labels remain readable over the brighter image.

## Findings

No actionable P0, P1, or P2 findings remain.

- Typography: the first pass retained white labels from the former dark panel, producing weak contrast. Fixed by using deep blue-gray label tokens while preserving icon/circle colors and geometry.
- Spacing/layout: circular endpoints, center core, labels, and legend remain within the rounded panel with no clipping or overlap.
- Colors/tokens: the panel now uses the requested pale blue/cyan/violet palette; green and blue semantic connection states remain distinct.
- Image quality: the exact user-provided 2159 × 728 source is packaged as a native PNG and rendered with aspect-fill; no SVG or code-drawn substitute is used for the backdrop.
- Copy/content: all visible labels describe live Codex, proxy, and MCP state; no placeholder status was introduced.
- Interaction/accessibility: native controls and accessibility labels remain intact; motion still follows Reduce Motion through the existing particle implementation.

## Comparison history

1. Pass 1 — P2: white endpoint and legend copy lost contrast on the new light background.
   - Fix: introduced dark navy primary and blue-gray secondary copy colors only inside the technology panel.
   - Post-fix evidence: final CUA capture at 16:10 shows readable CODEX, CHATGPT / MCP, NETWORK CORE, header, and legend text while all circular visuals and moving route points remain unchanged.
2. Pass 2 — no actionable P0/P1/P2 differences.

## Implementation checklist

- [x] Use the supplied background image in the top technology panel.
- [x] Keep all three circular connection visuals unchanged.
- [x] Keep route curves and moving points unchanged.
- [x] Package the PNG inside the installed `.app`.
- [x] Verify light-background text contrast.
- [x] Build, sign, install, launch, and run the full automated test suite.

final result: passed
