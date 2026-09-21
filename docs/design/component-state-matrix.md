# Component State Matrix and Keyboard Walkthrough

**Applies to:** Slice 1 shared web primitives and v4.3 operational journeys.  
**Design source:** `STATES` in the v4.2 wireframe plus the v4.3 operational addendum.

## State matrix

| Primitive | Default | Hover / focus | Active / selected | Disabled | Loading | Empty | Error |
|---|---|---|---|---|---|---|---|
| Button | Bordered action, visible text | Pointer hover plus global 2px focus ring | Primary/gold variants retain text contrast | Native `disabled`, reduced opacity, no action | `aria-busy=true`, disabled, text becomes “Working…” | n/a | Error actions are ordinary buttons inside `ErrorPanel` |
| Field | Visible `label` linked by `htmlFor` | Global focus ring, input border retained | User value visible in control | Native input state | Parent form owns loading state | Blank remains a labelled field, never a placeholder-only field | `aria-invalid=true`; error and hint IDs are included in `aria-describedby` |
| Select | Visible label and native select | Global focus ring | Native selected option | Native disabled state | Parent form owns loading state | Explicit “Not set” option where the domain permits it | Same error contract as Field |
| Tabs / Tab | Tablist has accessible label | Arrow Left/Right, Home and End move focus; global focus ring | Selected tab uses `aria-selected=true` and roving `tabIndex=0` | Consumer may omit or disable unavailable tabs | n/a | n/a | Route/page error is outside the tabset |
| DataTable | Required caption; every column header has `scope=col` | Browser focus only for interactive descendants | n/a | n/a | Skeleton replaces table while loading | Consumer renders EmptyState instead of an unlabeled blank table | Consumer renders ErrorPanel rather than partial/false data |
| Disclosure | Native `details/summary` | Summary is keyboard focusable | Open state is native | n/a | n/a | n/a | n/a |
| EmptyState | Dashed contained region with unique labelled heading | Action receives normal focus treatment | n/a | n/a | n/a | This is the canonical empty state | May contain recovery guidance but errors use ErrorPanel |
| ErrorPanel | Alert region with strong heading/message | Recovery action receives normal focus | n/a | n/a | n/a | n/a | `role=alert`; correlation ID is visible when supplied |
| Skeleton | Neutral non-semantic placeholder | n/a | n/a | n/a | Used inside a parent carrying loading semantics where needed | n/a | n/a |
| Card | Contained grouping | Interactive descendants own focus | n/a | n/a | n/a | n/a | n/a |
| Chip | Status label | Non-interactive | Tone communicates state in addition to text | n/a | n/a | n/a | Text remains the primary meaning; colour is not the only cue |

## Automated accessibility gate

`npm run a11y:test` renders a representative matrix of the shared primitives into JSDOM and runs
Deque axe against WCAG 2.0/2.1/2.2 A/AA tagged rules. CI fails when axe reports a violation.

This is intentionally lightweight: it adds no browser installation to every pull request. Full
browser accessibility checks can be added later to representative end-to-end flows once those flows
are stable.

## Manual keyboard walkthrough

The following walkthrough is the release checklist. It is **not marked executed merely because this
document exists**.

1. **AUTH01 sign-in:** Tab reaches Password/Magic Link method controls, Email, Password, submit,
   Forgot password and Create account in a logical order. Shift+Tab reverses it. Focus is always visible.
2. **AUTH04 password recovery:** Tab through the managed forgot-password form; submit an invalid
   value and confirm the error is announced/readable. From a valid reset link, tab through new
   password, confirmation and submit. Confirm no keyboard trap.
3. **SETUP01–SETUP05:** Complete organisation, outlet, context and period setup using keyboard only.
   Native selects open from the keyboard; validation messages are associated with their fields.
4. **Settings / users:** Reach every input and action without pointer input. For tabs, Arrow
   Left/Right changes tab focus/selection, Home selects the first tab and End the last.
5. **Tables and disclosures:** Table captions are announced before data; disclosures toggle with
   Enter/Space; no information exists only in a hover tooltip.
6. **Error/empty/recovery states:** Recovery actions are reachable immediately after the explanatory
   copy. Correlation IDs remain selectable/readable.
7. **Focus after navigation:** Each route displays a meaningful H1 and browser focus is not trapped
   in an obsolete overlay or hidden control.

Record browser/OS, date, tester and any defect before declaring the manual item complete.
