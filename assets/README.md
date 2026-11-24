# Icon assets

The app icon uses the widget’s two progress bars: mint for the larger remaining quota and amber for the smaller one. The menu bar icon uses the same motif as a monochrome AppKit template, which macOS recolors for its current appearance.

- `AppIcon.png`: original artwork generated with the built-in imagegen tool, preserving transparency.
- `AppIcon.icns`: packaged macOS icon, with standard sizes from 16px through 1024px. Regenerate it with `bash scripts/generate-app-icon.sh` after changing the artwork.
- The menu bar mark is drawn by `Sources/CodexUsageWidget/StatusBarIcon.swift` so it stays sharp at different display scales.
- `MenuBarIcon@2x.png` and `MenuBarIcon-preview.png` are exports of that mark; the larger preview has a light background for visibility.

## Artwork prompt

```text
Use case: logo-brand
Asset type: finished macOS application icon for AI Usage (originally Codex Usage), a floating widget showing weekly and five-hour remaining quota.
Create one square 1024px polished macOS icon, isolated on a genuinely transparent outer background. Large graphite charcoal rounded-square tile occupying 84% of canvas, standard macOS squircle corners, front-on orthographic view. In the center, precisely two horizontal pill-shaped progress tracks stacked with generous separation, both aligned at their left edge. Top bar luminous mint emerald glass filled to roughly 75% with a faint inset remainder track extending right; bottom bar warm amber glass filled to roughly 45% with its faint inset remainder extending to the same right edge. The two bars are the only symbol. Thick readable shapes, sculpted liquid-glass highlights, very restrained depth, clean edge reflections, premium calm desktop utility aesthetic. Dark tile lightly translucent, subtle top-left light and satin glass edge. Strong silhouette recognizable at 32px. Entire tile contained within transparent canvas with equal margins. No text, no numbers, no letters, no OpenAI logo, no sparkles, no dots, no badge, no decorative chart axes, no mockup, no multiple icons.
```
