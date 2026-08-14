# GitHub Version Tracking

Repository: [OSHEThai/HerdrOps](https://github.com/OSHEThai/HerdrOps)

Every planned release has one GitHub Milestone, scoped work issues, and one release-readiness tracker. A version is not releasable while any required issue remains open or any version-local gate lacks matching evidence.

| Version | Milestone | Work issues | Release tracker |
|---|---|---:|---|
| v0.1.0 | [Milestone 1](https://github.com/OSHEThai/HerdrOps/milestone/1) | 4 | [#5](https://github.com/OSHEThai/HerdrOps/issues/5) |
| v0.2.0 | [Milestone 2](https://github.com/OSHEThai/HerdrOps/milestone/2) | 6 | [#11](https://github.com/OSHEThai/HerdrOps/issues/11) |
| v0.3.0 | [Milestone 3](https://github.com/OSHEThai/HerdrOps/milestone/3) | 5 | [#17](https://github.com/OSHEThai/HerdrOps/issues/17) |
| v0.4.0 | [Milestone 4](https://github.com/OSHEThai/HerdrOps/milestone/4) | 5 | [#23](https://github.com/OSHEThai/HerdrOps/issues/23) |
| v0.5.0 | [Milestone 5](https://github.com/OSHEThai/HerdrOps/milestone/5) | 5 | [#29](https://github.com/OSHEThai/HerdrOps/issues/29) |
| v0.6.0 | [Milestone 6](https://github.com/OSHEThai/HerdrOps/milestone/6) | 4 | [#34](https://github.com/OSHEThai/HerdrOps/issues/34) |
| v0.7.0 | [Milestone 7](https://github.com/OSHEThai/HerdrOps/milestone/7) | 5 | [#40](https://github.com/OSHEThai/HerdrOps/issues/40) |
| v1.0.0 | [Milestone 8](https://github.com/OSHEThai/HerdrOps/milestone/8) | 5 | [#46](https://github.com/OSHEThai/HerdrOps/issues/46) |

Total: 8 milestones, 39 scoped work issues, and 8 release trackers.

## Operating rules

1. Work from the earliest open dependency milestone unless the roadmap explicitly allows parallel preparation.
2. Reference the issue number in commits and pull requests.
3. Do not close a work issue until its acceptance criteria and required evidence are attached or linked.
4. Static, synthetic, contract, runtime, independent-review, and release evidence remain separate.
5. Close the release tracker and milestone only after every required work issue and version-local gate passes.
6. Do not rebuild an accepted release artifact without invalidating its prior runtime/release evidence.

## Commands

Create missing roadmap objects without duplicating existing ones:

```powershell
./tools/Sync-GitHubRoadmap.ps1
```

Verify that a version has no open issues and its milestone is closed:

```powershell
./tools/Test-VersionMilestone.ps1 -Version v0.1.0
```

The verifier is expected to fail while work or the release tracker remains open.
