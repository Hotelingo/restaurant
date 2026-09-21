# Restaurant Performance Review v4.2 — Preservation Audit

v4.2 was produced by **adding a simplified customer navigation layer on top of the full v4 HTML**. The original analytical screens, staff tools, reviewer screens, state demonstrations, coverage audit, calculations and interaction code remain in the file.

## Automated structural checks

- Original `.scr` screens: **45**
- v4.2 `.scr` screens: **45**
- Screen ID sets identical: **True**
- Missing original screen IDs: **None**
- Original W decisions: **17**
- v4.2 W decisions: **17**
- W decision ID sets identical: **True**

## Explicit high-risk details checked

- SC27: **present**
- SC28: **present**
- MN01: **present**
- MN02: **present**
- MN03: **present**
- MN04: **present**
- MN05: **present**
- MN06: **present**
- MN07: **present**
- MN08: **present**
- MN09: **present**
- MN10: **present**
- MN11: **present**
- MN12: **present**
- ST01: **present**
- ST02: **present**
- ST03: **present**
- ST04: **present**
- MAP: **present**
- STATES: **present**
- COVER: **present**
- SC15: **present**
- SC08: **present**

## UX change

Customer mode now exposes six top-level areas — Home, Data Centre, Analysis, Review & Actions, Reports & History, Settings — with nested drill-downs to every original v4 screen. `Full v4 detail / review mode` restores the original v4 review header, full screen inventory, release filtering, role switcher and right-side review notes.

No original v4 screen was intentionally deleted. The customer shell changes discoverability, not analytical scope.

## DOM/detail preservation checks

- `section.scr[data-id]`: v4 **45** → v4.2 **45**
- `table`: v4 **76** → v4.2 **76**
- `input`: v4 **431** → v4.2 **431**
- `select`: v4 **117** → v4.2 **117**
- `textarea`: v4 **10** → v4.2 **10**
- `button`: v4 **468** → v4.2 **518**
- `details`: v4 **5** → v4.2 **11**
- `section.card`: v4 **159** → v4.2 **159**
- `[data-sheet]`: v4 **6** → v4.2 **6**

- Original screen sections whose content changed after normalising only the version label: **None**
- The customer UX shell is additive. The original v4 screen sections are structurally preserved; new buttons/details belong to the navigation shell only.