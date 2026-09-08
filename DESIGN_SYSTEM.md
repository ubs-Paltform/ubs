# UBS desktop design system

## Direction

**Precision Rail** — a compact release-control surface derived from build pipelines, terminal status lights, and artifact rails. It avoids dashboard density: one project, a small option set, one primary action.

Alternatives considered:

- Launch Pad: friendlier and softer, but less precise for release work.
- Build Ledger: information-rich, but visually heavier and slower to scan.

## Tokens

| Role | Value |
|---|---|
| Canvas | `#0b1016` |
| Surface | `#101922` |
| Raised surface | `#14212c` |
| Divider | `#263440` |
| Primary text | `#dde7ef` |
| Secondary text | `#8293a1` |
| Action / success | `#61d6c6` |
| Running / caution | `#f2a65a` |
| Failure | `#ff7c74` |
| UI type | system sans-serif |
| Data / status type | system monospace |
| Card radius | `18px` |

## Interaction contract

- One cyan primary action per screen.
- Folder selection always precedes option editing and build execution.
- Saved project rows persist locally and pair one compact build action with one removable folder target.
- Finite option groups with five or fewer choices stay visible as segmented buttons instead of dropdowns.
- Pipeline states use text, shape, and color together.
- Motion is limited to active progress and short hover transitions; `prefers-reduced-motion` disables it.
- The operating-system language selects `ko`, `en`, `ja`, or `zh`; all other languages fall back to English.
- Keyboard focus remains visible. Logs use a live region and never inject HTML.

## Safety contract

- The desktop layer passes only allow-listed values to the existing `build.sh` engine.
- Builds are non-interactive and never publish.
- Only one child process can run; cancellation terminates its process group.
- Remote scripts, fonts, analytics, and application servers are not used.
