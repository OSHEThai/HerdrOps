# Tests

Automated suites are separated into unit, contract, integration, and runtime-evidence projects. The runtime suite renders the actual WPF shell, Overview, Widget Gallery, and all seven Widget windows at 100%, 125%, and 150%, adds 1366×768 layout checks, writes PNGs under `artifacts/design-evidence/`, checks tagged Thai text for clipping, and verifies accessibility plus bounded/reversible window behavior.

A green runtime test project does not by itself prove actual Herdr operation; the current visual evidence is synthetic WPF rendering evidence and must not be reported as live Herdr runtime evidence.
