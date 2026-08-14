# HerdrOps

HerdrOps คือ Windows desktop operations monitor สำหรับติดตาม Agent ที่ทำงานอยู่ใน Herdr Terminal แบบเรียลไทม์ โดยรวมสถานะองค์กร การมอบหมายงาน กิจกรรมไฟล์ หลักฐาน การตรวจความสอดคล้อง การประเมิน และสรุปรายวันไว้ใน Dashboard และ Floating Widget ชุดเดียวกัน

## สถานะปัจจุบัน

Repository นี้อยู่ในระยะ **v0.1.0 Visual Shell Implementation** โดยมี Solution, ขอบเขต Process, Build Pipeline, Test Suites และ WPF Shell แบบ Synthetic แล้ว แต่ยังไม่มีหลักฐานว่าเชื่อมต่อ Herdr, เก็บ Event, แสดงข้อมูลจริง หรือพร้อมเผยแพร่

Design Reference ที่ผู้ใช้ยืนยันถูกเก็บแบบไม่แก้ไขไว้ใน [`docs/design/reference`](docs/design/reference/). ไฟล์เหล่านี้เป็น Source of Truth สำหรับหน้าตา UI และโลโก้ HerdrOps

## Architecture Baseline

- .NET 10 LTS และ WPF สำหรับ Windows desktop UI
- `HerdrOps.Core.exe` เป็น per-user background collector
- `HerdrOps.App.exe` ดูแล System Tray, Floating Widget และ Dashboard
- `HerdrOps.Cli.exe` รับ self-report จาก Agent แล้วส่งเข้า Core
- SQLite แบบ WAL สำหรับข้อมูลภายในเครื่อง
- Windows Named Pipe สำหรับ Herdr และ IPC ภายใน
- Local-first; รุ่นแรกไม่เปิด localhost HTTP port และไม่ต้องใช้สิทธิ์ Administrator

รายละเอียดอยู่ที่ [`Plan/ARCHITECTURE.md`](Plan/ARCHITECTURE.md)

## Version Plan

| Version | เป้าหมายหลัก |
|---|---|
| v0.1 | Foundation และ Visual Shell |
| v0.2 | Live Herdr Monitoring |
| v0.3 | Realtime Activity และ File Activity |
| v0.4 | Delegation และ Task Alignment |
| v0.5 | Compliance และ Evidence Review |
| v0.6 | Evaluation และ Daily Summary |
| v0.7 | Beta Hardening และ Packaging |
| v1.0 | Stable Local Release |

ขอบเขตและเกณฑ์รับรองแต่ละรุ่นอยู่ที่ [`Plan/ROADMAP.md`](Plan/ROADMAP.md) และ [`Plan/RELEASE-GATES.md`](Plan/RELEASE-GATES.md)

GitHub Milestones, scoped Issues และ Release Trackers อยู่ที่ [`Plan/GITHUB-TRACKING.md`](Plan/GITHUB-TRACKING.md)

## Visual Shell

- ใช้ Design Token สามชั้น: Primitive → Semantic → Component
- มี Top bar, Sidebar, Content host, Bottom status bar และ Window controls ตามภาพอ้างอิง
- ลงทะเบียน Navigation ครบ 10 หน้ามาตรฐาน พร้อม keyboard shortcuts และ responsive sidebar
- Logo/Wordmark ของ v0.1 ใช้ crop จากภาพอ้างอิงเดิมโดยไม่แก้ไข Source PNG
- ทุกค่าบน Shell ระบุเป็น Synthetic หรือ Not connected อย่างชัดเจน
- หน้า Overview แสดง summary cards, recent activity, score trend, work distribution, top agents และ alerts จาก deterministic synthetic fixture

Design checklists อยู่ที่ [`v0.1 Issue #2`](docs/design/implementation/v0.1-issue-2-checklist.md) และ [`v0.1 Issue #3`](docs/design/implementation/v0.1-issue-3-overview-checklist.md)

## Build Foundation

Requires .NET SDK 10.0.400 or a compatible latest patch in the 10.0.4xx feature band.

```powershell
./tools/Invoke-Build.ps1 -Configuration Release -VerifyFormat
```

This command restores from committed package locks, builds the solution, verifies formatting, runs all automated suites, and writes disposable output under `artifacts/`.

## Repository Map

```text
HerdrOps/
├── Plan/                    Current architecture and version truth
├── docs/design/reference/   Immutable user-approved design images
├── src/                     Product source code (starts in v0.1)
├── tests/                   Automated and runtime evidence suites
└── tools/                   Build, verification, and packaging tools
```

## Planning Rules

- `Plan/` เป็นแผนปัจจุบัน; เอกสารหรือ Mockup อื่นไม่แทนแผนนี้โดยอัตโนมัติ
- แต่ละ Version ต้องผ่าน Gate ของตัวเองก่อนเปลี่ยนสถานะเป็น Complete
- Mock, static checks และ synthetic tests ไม่ใช่หลักฐานว่าเชื่อมต่อ Herdr จริง
- ห้ามแก้ภาพอ้างอิงใน `docs/design/reference` โดยตรง
- โลโก้ในภาพอ้างอิงต้องคงรูปทรงและ Wordmark เดิม ไม่สร้างเครื่องหมายใหม่มาทดแทน
