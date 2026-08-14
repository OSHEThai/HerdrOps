# Tests

Automated suites are separated into unit, contract, integration, and runtime-evidence projects. The runtime suite also renders the actual WPF shell at 100%, 125%, and 150% into `artifacts/design-evidence/` and checks tagged Thai text for clipping.

A green runtime test project does not by itself prove actual Herdr operation; the current visual evidence is synthetic WPF rendering evidence and must not be reported as live Herdr runtime evidence.
