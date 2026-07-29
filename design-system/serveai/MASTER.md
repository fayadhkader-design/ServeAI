# ServeAI Design System — Master

The canonical visual specification is [`DESIGN.md`](../../DESIGN.md). This file records the UI/UX Pro Max design dials and implementation constraints.

## Design Dials

- Variance: 7/10 — bold supplied sports prototype, translated without replacing native iOS behavior.
- Motion: 4/10 — active analysis motion plus restrained state feedback.
- Density: 5/10 — compact home dashboard, spacious capture, progressively disclosed report detail.

## Native Rules

- SwiftUI + SF Symbols + custom fonts tied to Dynamic Type styles.
- NavigationStack and type-safe navigation destinations.
- Minimum 44-point controls and safe-area-aware layouts.
- The supplied dark-only court palette is the committed appearance.
- Accent never substitutes for a text or symbol state label.
- Respect Reduce Motion; continuous animation is limited to active analysis progress.
- No AI-purple palette, ornamental glassmorphism, or web-shaped navigation.

## Spacing

Use the 4-point scale: 4, 8, 12, 16, 20, 24, 28, 32. Utility cards use 16–18 points; prototype hero/video surfaces use 22–28 points; pills are reserved for compact metadata.

## Pre-delivery

Build and test with Xcode, verify core screens at small and large iPhone widths plus landscape, exercise accessibility Dynamic Type and Reduce Motion, confirm all controls have labels and 44-point hit regions, and verify loading/error/empty states.
