# Tests

Automated suites are separated into unit, contract, integration, and runtime-evidence projects. The runtime suite renders the actual WPF shell, Overview, Widget Gallery, and all seven Widget windows at 100%, 125%, and 150%, adds 1366×768 layout checks, writes PNGs under `artifacts/design-evidence/`, checks tagged Thai text for clipping, and verifies accessibility plus bounded/reversible window behavior.

The Widget Gallery regression checks compare decoded BGRA pixel hashes, so 125% and 150% evidence cannot pass by changing only PNG DPI metadata; the Gallery must select its responsive layout while retaining all eight launch actions.

A green runtime test project does not by itself prove actual Herdr operation; the current visual evidence is synthetic WPF rendering evidence and must not be reported as live Herdr runtime evidence.

The v0.2 protocol contract suite creates bounded binary fixtures for compatible, malformed,
missing-marker and unknown-hash cases. Fixture success is Contract evidence only. The repeatable
installed-binary gate is `./tools/Test-V02ProtocolContract.ps1`; it reads the exact executable
bytes but does not connect to or control a Herdr session.
