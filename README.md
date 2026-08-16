# HerdrOps

HerdrOps คือ Windows desktop operations monitor สำหรับติดตาม Agent ที่ทำงานอยู่ใน Herdr Terminal แบบเรียลไทม์ โดยรวมสถานะองค์กร การมอบหมายงาน กิจกรรมไฟล์ หลักฐาน การตรวจความสอดคล้อง การประเมิน และสรุปรายวันไว้ใน Dashboard และ Floating Widget ชุดเดียวกัน

## สถานะปัจจุบัน

**v0.1.0 Visual Shell ได้รับอนุมัติและเผยแพร่แล้ว** ส่วน **v0.2.0 Live Herdr Monitoring** เปิดดำเนินการอยู่ โดยมี protocol/schema admission, fail-closed Herdr monitor, SQLite state store, Core-to-App Named Pipe protocol v2 และ live adapters สำหรับ Dashboard กับ Widget แล้ว

IPC v2 แยกสถานะ `Core connected` ออกจาก `Herdr live` อย่างชัดเจน ถ้า Herdr ขาดการเชื่อมต่อ หน้าจอจะเก็บ identity/topology ล่าสุดไว้เพื่อวินิจฉัย แต่จะไม่แสดง Agent เก่าว่ายังทำงานอยู่ หลักฐานปัจจุบันยังเป็น Contract, Integration และ Synthetic WPF; actual Herdr snapshot/event/reconnect, production WPF captures และผลวัดบน reference Windows host ต้องผ่าน composite runtime gate ก่อน จึงยังไม่อ้างว่า v0.2 พร้อม Release

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
- ค่าเริ่มต้นเป็นภาษาไทยและสลับเป็นภาษาอังกฤษได้จากแถบบน โดยหนึ่งหน้าจอแสดงภาษาเดียว; ชื่อผลิตภัณฑ์ รหัสงาน ชื่อ Agent และ path คงเป็นข้อมูลเทคนิคเดิม

Design checklists อยู่ที่ [`v0.1 Issue #2`](docs/design/implementation/v0.1-issue-2-checklist.md), [`v0.1 Issue #3`](docs/design/implementation/v0.1-issue-3-overview-checklist.md), [`v0.1 Issue #4`](docs/design/implementation/v0.1-issue-4-widget-checklist.md), [`v0.1 Issue #51`](docs/design/implementation/v0.1-issue-51-widget-review-remediation.md) และ [`v0.1 Issue #60`](docs/design/implementation/v0.1-issue-60-language-separation.md)

รัน Quality Gate ของ v0.1 แบบครบชุดด้วย:

```powershell
./tools/Test-V01ReleaseGate.ps1
```

ตรวจ exact Herdr binary และ bounded protocol contract สำหรับ v0.2 Issue #6 ด้วย:

```powershell
./tools/Test-V02ProtocolContract.ps1
```

ผลผ่านของคำสั่งนี้เป็น Contract evidence ไม่ใช่หลักฐาน live Herdr runtime

ดึงและตรวจ full bundled JSON Schema สำหรับ v0.2 Issue #54 ด้วย:

```powershell
./tools/Test-V02BundledSchemaContract.ps1
```

ผลผ่านยังคงเป็น Contract evidence จาก executable bytes เท่านั้น ไม่ใช่หลักฐาน live Herdr runtime

ให้เปิด PowerShell แบบไม่ใช้สิทธิ์ผู้ดูแลระบบจาก Pane ใหม่ที่ยังไม่เคยย้ายตำแหน่งใน Named Session `acceptance` โดยคง `HERDR_SOCKET_PATH` ของ Pane ให้ชี้ไปที่ Control Session นี้ ส่วน Session `default` ใช้เป็น Agent Lab เป้าหมาย จากนั้นรัน Composite Runtime Gate สำหรับ Issues #7, #9 และ #10 ด้วย:

```powershell
$targetAgentLabSocket = Join-Path $env:APPDATA 'herdr\herdr.sock'
./tools/Test-V02LiveRuntimeAcceptance.ps1 `
    -TargetHerdrSocketPath $targetAgentLabSocket `
    -Language Thai `
    -DurationSeconds 600
```

Control Session กับ Agent Lab ต้องใช้ Socket และ Herdr Server Process คนละตัว เพราะการหยุด Herdr Server จะปิด Process ของทุก Pane ใน Session นั้น ระหว่างรัน Gate ให้สร้าง Event A ด้วยการเปลี่ยนสถานะ Agent จริงใน Agent Lab เมื่อ Dashboard ปิดแล้วจึงหยุดและเปิดใหม่เฉพาะ Session `default` รอจน Floating Widget กลับมาเป็น `LIVE` แล้วสร้าง Event B ด้วยการเปลี่ยนสถานะ Agent จริงอีกครั้ง Gate จะตรวจลำดับ Event A → Disconnect → PID/เวลาเริ่ม Process ใหม่ → Event B การสลับ Focus หรือสร้าง Workspace, Tab หรือ Pane ไม่นับเป็น Event โปรแกรมจะเก็บ Exact Core Trace, Production WPF Captures, Dashboard-close continuity, Widget latency, Core+App resource usage และ owned TCP listener evidence ไว้ใน `artifacts/runtime-evidence/` ผลจากสภาพแวดล้อมที่ไม่มี Herdr authorization จะ fail closed และไม่ได้ Runtime credit

งานพื้นฐานของ v0.3 Issue #12 มีคำสั่ง replay สำหรับตรวจการเรียงลำดับ การตัดข้อมูลซ้ำ การรวมเหตุการณ์ถี่ และ sequence gap แบบ deterministic:

```powershell
./tools/Test-V03ActivityPipeline.ps1
```

คำสั่งนี้ต้องรันจาก checkout ที่ commit แล้วและไม่มีไฟล์ค้าง ผลผ่านเป็นหลักฐาน Contract กับ Synthetic เท่านั้น ยังไม่ใช่หลักฐาน Herdr runtime, process/file collection หรือความพร้อม Release ของ v0.3

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
