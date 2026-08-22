# HerdrOps Version Roadmap

Status: Planning baseline  
Product target: Windows 11 desktop utility  
Versioning: Semantic Versioning; every version has a version-local acceptance gate

## Version policy

1. แต่ละ Version ต้องสร้าง Artifact ที่ติดตั้งหรือทดสอบได้ตามขอบเขตของรุ่นนั้น
2. งานเตรียมสำหรับ Version ถัดไปไม่ถือว่ารุ่นปัจจุบันเสร็จ
3. Mock และ Synthetic data ใช้พัฒนาได้ แต่ต้องติดป้ายชัดเจนและไม่แทน Runtime evidence
4. การเปลี่ยน Contract หรือ Evidence ที่ถูกใช้รับรองแล้วต้องออก Successor revision ห้ามแก้ย้อนหลังแบบเงียบ ๆ
5. Release note ต้องระบุ Known limitations และข้อมูลที่ยังไม่ได้มาจาก Herdr โดยตรง

## v0.1.0 — Foundation and Visual Shell

### Outcome

สร้างฐานโครงการที่ Build ได้และถ่ายทอด Design Contract ให้เป็น WPF shell โดยยังใช้ข้อมูลจำลองที่ติดป้ายชัดเจน

### Scope

- สร้าง .NET 10 solution และโครงการ `App`, `Core`, `Cli`, `Contracts`, `Domain`, `Infrastructure`
- สร้าง Design Tokens: สี Typography Spacing Border Radius Icon และ Status semantics
- สร้าง Window shell: Top bar, Sidebar, Content host และ Bottom status bar
- สร้าง Navigation สำหรับ 10 หน้าตาม Reference
- สร้าง Overview visual slice และ Widget gallery จากข้อมูลจำลอง
- แยกข้อความภาษาไทยและอังกฤษเป็นคนละโหมดสำหรับ Shell, Overview และ Widget โดยค่าเริ่มต้นเป็นภาษาไทย
- เพิ่ม Dark theme, Windows scaling 100/125/150%, keyboard focus และ basic accessibility
- ตั้งค่า build, unit test, formatting และ artifact output

### Explicitly out of scope

- การเชื่อมต่อ Herdr จริง
- SQLite production schema
- การสรุปว่า Agent status หรือ Task เป็นข้อมูลจริง

### Exit gate

- Clean build และ automated tests ผ่าน
- Visual checklist ผ่านบน reference size 1672×941 และ Windows scaling ที่กำหนด
- โลโก้และ shared shell ตรงกับ Design Contract
- Mock data ถูกแสดงว่าเป็น Demo/Synthetic อย่างชัดเจน
- หน้าจอ v0.1 แสดงภาษาไทยหรืออังกฤษเพียงภาษาเดียวตามตัวเลือก และไม่มีหัวข้อคำแปลสองภาษาซ้อนกัน

## v0.2.0 — Live Herdr Monitoring

### Outcome

แสดงสถานะ Agent จริงจาก Herdr แบบ local realtime พร้อมการคืนสภาพหลังการเชื่อมต่อหลุด

### Scope

- อ่าน API schema/protocol จาก Herdr binary ที่ติดตั้ง
- เชื่อม Herdr Windows Named Pipe
- Bootstrap ด้วย session snapshot และติดตาม event subscription
- Reconcile snapshot หลัง reconnect หรือ sequence gap
- เพิ่ม SQLite WAL สำหรับ current state และ event metadata ขั้นต่ำ
- เปิดใช้หน้าจอ Overview, Live Organization และ Agent Detail ด้วยข้อมูลจริง
- เปิดใช้ Compact, Normal และ Floating Vertical Widget
- แสดงแหล่งข้อมูลและความสดของสถานะใน UI

### Exit gate

- Contract tests และ Runtime test กับ Herdr ที่ติดตั้งจริง (snapshot, event subscription, disconnect, reconnect, reconciliation)
- สถานะ `working`, `idle`, `blocked`, `done`, `unknown/offline` ถูกแมปอย่างมีหลักฐาน
- Disconnect/reconnect แล้ว state กลับมาตรงกับ snapshot
- Atomic package identity validation สำหรับ self-contained `win-x64` ZIP + PowerShell installer และ process-wide `SoftwareOnly` renderer policy
- Renderer compatibility และ visual parity บน reference-host profile (`96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3`, Windows 11 build 26220, non-elevated single-user)
- Atomic Thai/English language matrix reports พร้อม disjoint capture roots และ Narrator accessibility
- Display coverage 1920x1080 และ 1366x768 ที่ 100/125/150% พร้อม mixed-DPI transitions
- Performance budgets (CPU <=1%, event-to-WPF p95 <=250 ms, UI-stall p95 <=50 ms max <=100 ms, regression <=10%) และ Soak 120 นาที (60 นาที AC + 60 นาที Battery, working set <=255 MiB, slope <=1 MiB/10 min)
- ไม่มี localhost HTTP listener และไม่ต้องใช้ Administrator

## v0.3.0 — Realtime and File Activity

### Outcome

ติดตาม Event, Process และ File activity โดยแยกข้อมูลที่ดึงตรงจาก Herdr ออกจากข้อมูลที่อนุมานหรือเก็บเพิ่ม

### Scope

- หน้าจอ Realtime Activity และ File Activity
- Event normalize, sequence, deduplicate, debounce และ correlation
- `pane.read` แบบ bounded preview และ revision tracking
- Process metrics จาก Windows API โดยอิง PID ที่ Herdr รายงาน
- File watcher และ Git activity ภายใน repository scope
- Notification Widget และ Agent Detail Popup
- Filtering ตามเวลา Agent Task severity และ evidence source

### Exit gate

- Event replay test ให้ผล state เดิมแบบ deterministic
- Runtime trace ยืนยัน event latency, deduplication และ bounded terminal reads
- File event ทุกชนิดมี source/confidence และไม่มีการอ่านนอก policy โดยไม่แจ้ง
- Secret/redaction tests ผ่าน

## v0.4.0 — Delegation and Task Alignment

### Outcome

เห็นสายการมอบหมายงานและตรวจความสอดคล้องระหว่าง Assignment Contract, แผน, การกระทำ และไฟล์ที่แตะจริง

### Scope

- หน้าจอ Delegation Graph และ Task Alignment
- `HerdrOps.Cli.exe` สำหรับ Agent self-report
- Assignment, acknowledgement, delegation, progress, deviation และ handoff events
- Task tree และ role relationship model
- Planned steps, acceptance criteria, actual files touched และ observed actions
- Expanded Widget สำหรับมุมมอง Agent/Task แบบละเอียด

### Exit gate

- Lifecycle trace ครบจาก PM → Leader → Worker → Review
- ทุก node/edge มี provenance และ timestamp
- Missing acknowledgement, orphan task และ scope mismatch ถูกตรวจพบจาก test corpus
- Self-report ไม่สามารถเขียนฐานข้อมูลโดยตรงและถูก validate ที่ Core

## v0.5.0 — Compliance and Evidence Review

### Outcome

สร้าง review queue ที่แยก suspected, confirmed, dismissed, leader review และ PM review อย่างชัดเจน

### Scope

- หน้าจอ Compliance Queue
- Rule engine สำหรับ scope, missing evidence, unapproved deviation และ review-order violations
- Evidence item พร้อม SHA-256, source, timestamp และ task/actor linkage
- Role-distinct review actions: confirm, send to leader, escalate to PM, dismiss
- Incident history และ immutable review audit trail
- Retention และ redaction controls

### Exit gate

- Rule tests ครอบคลุม positive/negative cases และลด duplicate incidents
- ไม่มี suspected event ถูกยืนยันอัตโนมัติโดยไม่มี policy authority
- Evidence hash และ reviewer identity ตรวจย้อนกลับได้
- Runtime workflow ผ่านด้วย reviewer roles ที่แยกจาก actor

## v0.6.0 — Evaluation and Daily Summary

### Outcome

ประเมินผลแบบอธิบายได้และสร้าง Daily Summary จากข้อมูลที่ผ่าน provenance checks

### Scope

- หน้าจอ Evaluation และ Daily Summary
- Dimension scoring: goal alignment, acceptance criteria, technical quality, scope compliance, evidence และ communication
- Leader score, PM score, objective evidence และ weighted score
- Trend, distribution, recurring issue, strengths และ recommended actions
- Daily workstream summary และ local export
- Score explanation และ recalculation history

### Exit gate

- สูตรคำนวณ reproducible และ versioned
- Missing data ไม่ถูกแปลงเป็นคะแนนผ่านโดยอัตโนมัติ
- Leader/PM/evidence values แยกแหล่งที่มา
- Daily Summary เทียบกลับไปยัง events และ evidence ได้

## v0.7.0 — Beta Hardening and Packaging

### Outcome

รวมทุกหน้าจอและ Widget เป็น Beta ที่ติดตั้ง ทนต่อการเปิดใช้งานระยะยาว และใช้งานได้ทั้งภาษาไทย/อังกฤษ

### Scope

- ครบ 10 Dashboard pages และ Widget variants ที่ยืนยัน
- System Tray, start at logon, notification settings และ retention settings
- ทำ localization ให้ครบทั้ง 10 หน้า บันทึกค่าภาษา accessibility, DPI/multi-monitor และ reduced motion
- Crash recovery, database migration/backup และ corrupted-state recovery
- Installer, upgrade, uninstall และ diagnostic bundle
- Performance profiling และ 8-hour soak test

### Exit gate

- Clean-machine install/upgrade/uninstall ผ่านบน Windows reference host
- 8-hour runtime soak ไม่มี crash หรือ unreconciled state
- Performance budgets ใน `RELEASE-GATES.md` ผ่านหรือมี waiver ที่อนุมัติ
- Human UAT และ Design review ผ่าน

## v1.0.0 — Stable Local Release

### Outcome

HerdrOps รุ่น Local Stable พร้อมคู่มือ การอัปเกรด และหลักฐาน Release ที่ตรวจสอบได้

### Scope

- ปิดข้อบกพร่องระดับ release-blocking จาก Beta
- 24-hour soak และ reconnect/fault-injection suite
- Final schema migration, retention defaults และ privacy review
- Versioned installer, checksums, release notes และ rollback instructions
- User/operator documentation และ troubleshooting

### Exit gate

- ทุก Version-local gate ที่เป็น dependency มีหลักฐานครบ
- Release artifact hash ตรงกับ artifact ที่ผ่าน acceptance
- Clean-machine install และ actual Herdr runtime acceptance ผ่าน
- Human go/no-go ได้รับการบันทึก

## Post-v1 candidates — Not committed

- v1.1: Adapter/Rule plugin SDK และ custom dashboard filters
- v1.2: Read-only remote aggregation ผ่าน opt-in secure relay
- v2.0: Multi-user/team operations โดยออกแบบ authorization และ privacy ใหม่
