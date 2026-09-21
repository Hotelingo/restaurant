# Restaurant Performance Review — v4.2 Development Handoff

## Purpose
v4.2 is the lossless UX refactor requested after v4.1. It keeps the complete v4 analytical/control specification and adds a simpler six-area customer navigation layer.

## Core rule
**Simplify navigation and disclosure, not functionality.**

The source v4 remains inside the same HTML: all original screen sections, calculations, C02 sheets, Menu MN01–MN12, staff ST01–ST04, reviewer controls, states, review map, W1–W17 decisions and the 99-view coverage audit remain present.

## Customer navigation
1. Home
2. Data Centre
3. Analysis
4. Review & Actions
5. Reports & History
6. Settings

### Nested Analysis
- Management P&L / SEQUENCE
- Reconciliation
- Revenue → Meal-period Revenue → Customer Source → Contribution
- Food & Beverage Cost → Expected Usage Builder → C02 Investigation & Test Sheets
- Labour & Activity
- Other Restaurant Costs
- Menu & Product → MN01 through MN12

### Nested Settings / specialist detail
- Restaurant Context
- Settings & Users
- Setup Analyst tools ST01–ST04
- Internal Review Map / States / Coverage Audit

## Full v4 detail mode
The top customer shell includes **Full v4 detail / review mode**. This restores the original v4 three-column review experience, including release filters, role switcher, complete screen inventory, right-side guide checks and W1–W17 review decisions.

## Preservation result
Automated structural comparison against the uploaded v4 source found:
- 45 original `.scr` screens in v4
- 45 original `.scr` screens in v4.2
- identical screen-ID set
- 0 missing original screen IDs
- all W1–W17 decisions still present
- SC27 and SC28 present
- MN01–MN12 present
- ST01–ST04 present
- SC08 Reconciliation and SC15 Reviewer Workbench present
- MAP, STATES and COVER present
- 99-view coverage audit still present
- original screen section content unchanged after normalising the version label

See `Restaurant_Performance_Review_v4_2_Preservation_Audit.md` for the detailed structural check.

## Demo assets
The v4.1 Amberside demo workbook and upload/template assets are carried forward unchanged as the current unified demo fixture. They can now be used alongside the full v4.2 functional wireframe.

## Next development step after approval
Do not redesign the analytical scope again. Move to Product/Engineering Freeze:
1. Freeze R1 capability scope.
2. Freeze review state machine.
3. Freeze domain model and immutable/versioned records.
4. Freeze calculation contracts and golden-fixture outputs.
5. Implement the first vertical slice: setup → upload/mapping → readiness → P&L → one issue → action → Owner Pack → reviewer sign-off.
6. Then add Food Cost, Revenue/Labour/Other Costs, and Menu as subsequent vertical slices.
