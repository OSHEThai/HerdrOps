# HerdrOps Design Contract

Status: User-approved visual reference baseline  
Reference set: `docs/design/reference/*.png`

## Authority order

1. Latest explicit user decision
2. Reference PNGs and their manifest hashes
3. This design contract
4. Derived implementation tokens and component specs

If derived UI differs materially from the images, the images win unless the user approves a change.

## Brand lock

- Preserve the blue circular HerdrOps symbol shown in the references.
- Preserve the white `HerdrOps` wordmark and its visual relationship to the symbol.
- Do not replace the mark with an `H`, generic pulse icon or newly generated logo.
- A production SVG/PNG master must be obtained or recreated only with explicit approval before v1.0. Screenshot cropping is prototype-only.

## Shared application shell

- Dark navy Windows desktop surface
- Fixed top bar with logo, page title, project selector, status legend and window controls
- Fixed left navigation with active-page blue outline/fill
- Main content region using compact cards and data-dense layouts
- Bottom status bar with application health, last update and connection latency
- Thin cool-blue borders, restrained glow, small radius and minimal shadow
- Render exactly one selected UI language at a time (Thai default, English selectable); do not stack dual-language translation labels

## Status semantics

| State | Visual role |
|---|---|
| Working | Green |
| Idle | Amber |
| Blocked | Red/coral |
| Review | Purple |
| Done | Blue |
| Offline/Unknown | Slate gray |

Severity and workflow state are separate concepts. `Blocked`, `Review`, `Suspected`, `Confirmed`, `High` and `Critical` must not be collapsed into one badge system.

## Canonical pages

| Page | Primary responsibility | Reference |
|---|---|---|
| Overview | Agent totals, activity, score trend, work distribution and alerts | `01-overview.png` |
| Live Organization | Live role hierarchy, vacancies/conflicts and selected-role details | `02-live-organization.png` |
| Realtime Activity | Filtered event stream, selected-event details and evidence sources | `03-realtime-activity.png` |
| Delegation Graph | Task tree, role/agent graph, handoff detail and timeline | `04-delegation-graph.png` |
| Agent Detail | Identity, assignment, activity, evidence, scores, reviews and related tasks | `05-agent-detail.png` |
| Task Alignment | Contract, acknowledgement, plan, criteria, actual actions/files and deviations | `06-task-alignment.png` |
| File Activity | File events, confidence/source, diff preview and high-risk paths | `07-file-activity.png` |
| Compliance Queue | Incident queue, evidence and role-distinct review actions | `08-compliance-queue.png` |
| Evaluation | Score distribution/trend, dimensions and agent comparisons | `09-evaluation.png` |
| Daily Summary | Highlights, issues, actions, timeline and workstream summary | `10-daily-summary.png` |

## Widget set

The canonical variants in `11-widget-concepts.png` are:

1. Compact Widget
2. Normal Widget
3. Expanded Widget
4. Floating Mini Widget
5. Floating Vertical Widget
6. Notification Widget
7. Agent Detail Popup
8. Dashboard launch/preview state

Widget variants share one state model and status semantics. They differ in density and interaction, not in the meaning of values.

## Initial implementation tokens

These are implementation starting points, not substitutes for visual review:

- Background: near-black navy
- Surface: layered deep navy with thin blue-gray border
- Primary accent: electric blue
- Text: cool white with blue-gray secondary text
- Corners: compact, approximately 6–10 px at 100% scale
- Spacing: dense 4/8/12/16/24 scale
- Motion: brief status/update transitions; support reduced motion

The approved v0.1 release established the initial sampled colors and dimensions. Every later implementation change must continue to validate exact colors and dimensions against the approved references.

## Visual acceptance

- Compare at the native reference dimensions: Dashboard 1672×941; Widget board 1536×1024
- Validate Windows scale factors 100%, 125% and 150%
- Validate 1366×768 minimum layout without losing primary actions
- Validate keyboard order, visible focus, contrast and Thai text clipping
- Record screenshots from the actual WPF build; generated mockups are not implementation evidence
