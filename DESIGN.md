---
name: ServeAI
description: A restrained, court-side editorial system for clear tennis serve coaching.
colors:
  court-night: "#0B0D0B"
  deep-surface: "#101210"
  utility-surface: "#161915"
  raised-surface: "#1D201B"
  chalk: "#F2F1E8"
  muted-chalk: "#B1B3A9"
  faint-chalk: "#7E8278"
  grass-note: "#C5CFA8"
  evidence-sage: "#8FAAA0"
  caution-clay: "#D59A6F"
  issue-red: "#C97B78"
typography:
  display:
    fontFamily: "New York, ui-serif, serif"
    fontSize: "39pt"
    fontWeight: 600
    lineHeight: 1.08
    letterSpacing: "-1.15pt"
  body:
    fontFamily: "San Francisco, ui-sans-serif, sans-serif"
    fontSize: "16pt"
    fontWeight: 400
    lineHeight: 1.45
  label:
    fontFamily: "San Francisco, ui-sans-serif, sans-serif"
    fontSize: "12pt"
    fontWeight: 600
rounded:
  metadata: "6pt"
  surface: "12pt"
spacing:
  xs: "4pt"
  sm: "8pt"
  md: "16pt"
  lg: "24pt"
  xl: "32pt"
components:
  button-primary:
    backgroundColor: "{colors.grass-note}"
    textColor: "{colors.court-night}"
    typography: "{typography.body}"
    rounded: "{rounded.surface}"
    padding: "18pt"
    height: "56pt"
  surface:
    backgroundColor: "{colors.utility-surface}"
    textColor: "{colors.chalk}"
    rounded: "{rounded.surface}"
    padding: "16pt"
---

# Design System: ServeAI

## Overview

**Creative North Star: "The Court-Side Journal"**

ServeAI should feel like a serious player’s annotated practice journal translated into a native iPhone interface: quiet, direct, and specific. It borrows the editorial hierarchy and material restraint of the Ouranos DTS system without copying its product structure. The interface makes the evidence and next coaching action easy to read; it never uses visual spectacle to imply scientific certainty.

The world is dark and warm rather than neon or cybernetic. Large serif moments establish a human coaching voice, while system sans-serif handles instructions and controls. Hairline rules organize reading order. Rounded containers are used only where interaction or grouping genuinely needs them.

**Key Characteristics:**
- Editorial headings paired with plain, high-legibility body copy.
- One muted grass accent, used sparingly for actions and active state.
- Flat sections and hairline dividers instead of card-on-card scaffolding.
- Transparent evidence language and native iOS behavior.

## Colors

The palette is warm graphite, chalk, and a desaturated grass note, with semantic colors reserved for evidence and warning states.

**The One Accent Rule.** Grass Note carries the primary action and active analysis state; a screen does not add decorative competing accents.

**The Evidence Rule.** Sage, clay, and red communicate evidence or caution only. They never become decorative gradients.

## Typography

**Display Font:** New York via SwiftUI’s system serif design.
**Body Font:** San Francisco via SwiftUI’s system default design.
**Data Font:** San Francisco Mono, only for measurements, dates, and compact evidence metadata.

Display type is measured and editorial, not poster-like. Body type remains native and readable at Dynamic Type sizes.

**The Sentence Case Rule.** Headings, controls, and status copy use sentence case. Uppercase is reserved for short machine-readable metadata originating in research tools.

## Layout

Phone screens use a single reading column with 20–24pt horizontal insets. Related content sits close together; sections receive 18–30pt separation and a one-point hairline when the boundary matters. The primary analysis action may be anchored above the home indicator so it stays reachable, while secondary navigation stays in the content flow.

Dynamic Type reflows naturally instead of switching to a separate visual concept. Interactive targets remain at least 44pt.

## Elevation & Depth

The system is flat by default. Depth comes from tonal surface changes, sparse grain, and one fixed ambient spotlight near the home title. It does not use drop shadows, glow, glass, or blur for decoration.

**The Flat-By-Default Rule.** A border, tonal fill, or whitespace is enough; never stack all three plus a shadow.

## Shapes

Utility surfaces and primary buttons use a restrained 12pt continuous corner. Evidence metadata may use a 6pt corner. Full capsules are limited to true compact tags or progress marks. Video retains slightly larger clipping where the media itself benefits from separation.

## Components

### Buttons
- Primary: muted grass fill, near-black text, 56pt minimum height, 12pt corner, and a 0.975 press scale when Reduce Motion is off.
- Secondary: graphite surface with chalk text and the same 12pt corner.
- Text action: no container unless touch-area visibility requires it.

### Sections
- Default: transparent background with generous vertical rhythm and a one-point chalk-opacity divider.
- Grouped utility surface: graphite fill, 12pt corner, no shadow, 16–20pt inset.

### Evidence labels
- Use explicit wording such as “Video evidence · Medium,” an SF Symbol, and a quiet semantic tint.
- Evidence quality and model assurance remain separate concepts.

### Motion
- Numeric scores use native numeric text transitions.
- Active analysis gets the system’s only continuous authored motion: a thin edge trace around its progress summary. It stops when Reduce Motion is enabled.

## Do's and Don'ts

### Do:
- **Do** foreground the next useful coaching action.
- **Do** show insufficient visibility instead of inventing precision.
- **Do** use whitespace and rules to create hierarchy.
- **Do** preserve native controls, accessibility semantics, and system navigation.

### Don't:
- **Don't** use neon gradients, glowing rings, gradient avatars, or multicolor progress tracks.
- **Don't** label deterministic or heuristic output as a personified “Coach AI.”
- **Don't** turn every row or section into a rounded card.
- **Don't** use all-caps hype copy as a substitute for hierarchy.
