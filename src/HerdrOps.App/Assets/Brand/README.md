# Prototype brand source

The v0.1 shell renders the HerdrOps symbol and wordmark from an in-memory crop of the immutable approved reference `docs/design/reference/01-overview.png`.

- The source PNG is linked into the WPF resource assembly without modifying its bytes.
- The crop is prototype-only, as allowed by `Plan/DESIGN-CONTRACT.md`.
- Do not redraw or replace the mark. A production master requires explicit approval before v1.0.
