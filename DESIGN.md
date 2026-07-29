# ServeAI Design System

## Reference and Intent

The shipped interface is a native SwiftUI translation of the supplied Claude Design prototype. Its scene is an early-morning player checking one decisive coaching note beside a dark court: energetic, direct, and a little irreverent without disguising estimated analysis as laboratory truth.

The visual target is intentionally dark-only. ServeAI preserves iOS navigation, permissions, video controls, VoiceOver semantics, Dynamic Type, and Reduce Motion beneath the prototype’s expressive layer.

## Foundations

- Platform: native iPhone UI using SwiftUI, NavigationStack, PhotosPicker, AVFoundation, VideoPlayer, Swift Charts, native alerts, and system back behavior.
- Canvas: `#08150F` court green with a low-contrast 22-point diagonal line texture.
- Typography: Archivo Black for display moments, Space Grotesk for coaching/body copy, and JetBrains Mono for metadata and compact labels. Every custom font is registered locally and uses a relative Dynamic Type style.
- Color strategy: committed dark court architecture with acid lime as the primary action and score color. Cyan, pink, and orange are reserved for distinct stat, warning, phase, and capture roles.
- Spacing: a 4-point base with 8, 12, 16, 20, 24, 28, and 32-point tiers.
- Shape: 16-point utility surfaces, 18-point action tiles, 22-point buttons/callouts, 24–28-point hero and video containers, and full pills for metadata.
- Motion: 150–300 ms state feedback. Continuous motion exists only while analysis is active and stops for Reduce Motion.

## Color Roles

| Role | Value | Use |
| --- | --- | --- |
| Court | `#08150F` | Global background and on-accent text |
| Deep surface | `#0C1F16` | Video and phase review wells |
| Chalk | `#F3F5E8` | Primary text and pale result actions |
| Serve lime | `#C6FF3D` | Primary CTA, score, selection, analysis progress |
| Motion cyan | `#46D5FF` | Serves-read stat, record action, mid-score phases |
| Contact pink | `#FF3D9A` | Priority fixes and destructive emphasis |
| Energy orange | `#FF8A3D` | Streaks, medium video evidence, caution |

Performance and evidence quality never rely on color alone. Numeric values, grade text, tags, symbols, and explicit labels remain present. Video evidence describes tracking conditions; model assurance is a separate textual status.

## Screen Mapping

- Home reproduces the prototype’s rallying headline, streak/read chips, last-serve hero, practice and clip tiles, and bottom analyze CTA. Its avatar menu keeps History and Progress reachable without adding a tab bar that was absent from the reference.
- Drop the Clip maps the prototype upload state onto the real PhotosPicker and camera route, retains side/rear angle choice, and enables the CTA only after a usable selection.
- Check the Clip preserves replay, replacement, retake, persistence, and full-clip disclosure before analysis.
- Analyzing maps real progress stages onto the rotating multi-color dial and explicitly identifies simulated versus on-device processing.
- The Verdict maps real score, grade, video-evidence quality, separate model assurance, coaching priority, provenance, detailed phases, drills, measurements, and limitations into the reference hierarchy.
- Frame by Frame seeks the real video to each measured phase and shows the phase note, tag, score color, scrub position, and visible previous/next controls.
- My Clips, The Trend, onboarding, camera, errors, and empty states extend the same palette and type system to functionality not present in the reference archive.

## Accessibility

- All interactive targets are at least 44 by 44 points.
- Custom fonts use `relativeTo` Dynamic Type styles; key horizontal groups fall back to vertical layouts when text grows.
- Buttons, video controls, stat summaries, score dials, phase states, and icon-only actions have explicit accessibility labels or combined values.
- Every colored state includes text or a symbol.
- The analyzing animation is the only continuous animation and honors Reduce Motion.
- Long screens scroll inside safe areas; no action is placed under the Dynamic Island or home indicator.
