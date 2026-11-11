# Minimal UI prototypes

Approved design direction for PokerLab (shadcn-like, monochrome zinc palette, generous spacing).
These are HTML prototypes of three screens; port them to SwiftUI.

- `Main.dc.html`: Learn path (home tab): streak pill, daily goal bar, unit header, lesson path with done / current / locked states, bottom tab bar (Learn, Lab, Practice, Profile).
- `Lesson.dc.html`: lesson question: close button, segmented progress, hero hand card, villain range, 2x2 answer grid, feedback panel, full-width 52 pt primary button (Check, then Next question).
- `Lab.dc.html`: Equity Lab: two hand rows with large tabular percentages, win/tie/lose bar, five dashed board slots, convergence card.

Tokens: background #FFFFFF, foreground #09090B (zinc-950), muted text #71717A (zinc-500), faint #A1A1AA, border #E4E4E7 (zinc-200), subtle fill #F4F4F5 / #FAFAFA, red suits #B91C1C. Radius 8-12, 1 px borders, 24 pt side padding, line icons at 1.75 stroke, Geist-like type (use SF Pro / SF Pro Rounded is not needed; keep SF Pro with tight tracking on titles).
