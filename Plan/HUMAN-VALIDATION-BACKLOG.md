# Human-only validation backlog

Status: Optional post-v1.0 follow-up; non-blocking

GitHub tracker: [#161](https://github.com/OSHEThai/HerdrOps/issues/161)

## Boundary

Every activity that inherently requires a person is excluded from version milestones, release-critical Issues/PRs, and automated release readiness. An unchecked or failed Human-only activity cannot block implementation, issue closure, milestone closure, packaging, tagging, or release readiness.

Agents replace removed gates with deterministic Static, Synthetic, Contract, Runtime, automated lifecycle, exact-artifact, CI, and role-distinct Agent-review evidence where applicable. Human observations collected later are supplemental and do not retroactively grant Runtime or Release evidence.

Explicit authorization remains required before an external publication or destructive action when repository safety rules require it. That authorization controls the action; it is not Human validation evidence and is not a version gate.

## Deferred activities

- Product-owner exploratory UI/UAT across all pages and widget variants.
- Subjective visual/design review beyond automated pixel, layout, language, and accessibility assertions.
- Human-listened Narrator or other manual-perception and assistive-technology sessions.
- Physical-device exercises unavailable to automation on the current host, including alternate-monitor/mixed-DPI unplug scenarios and battery-operation observation.
- Optional Beta feedback, post-release usability notes, and a human release opinion or go/no-go record.

## Source migration

- Open GitHub Issues #11, #35, #36, #39, #40, #45, #46, and #149 were migrated to this non-blocking backlog on 2026-08-25.
- No pull request was open at migration time. Future pull requests must link here instead of carrying a Human-only acceptance checkbox.
- Historical closed Issues, merged pull requests, comments, and superseded Plan decisions remain immutable audit history; they do not create a current Human gate.
