using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows.Interop;
using System.Windows.Media;
using HerdrOps.App.RuntimeEvidence;

namespace HerdrOps.RuntimeTests;

[TestClass]
[DoNotParallelize]
public sealed class Issue10PackageValidatorHostileTests
{
    [TestMethod]
    public void ExactPackageValidatorRejectsHostileInputsBeforeHardwareSelection()
    {
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
        using var fixture = PackageFixture.Create();

        fixture.Reject("profile bytes", "profile bytes drifted", f => File.AppendAllText(f.ProfilePath, " "));
        fixture.Reject("profile id", "identity header", f => f.MutateIdentity(i => i["profileId"] = "forged"));
        fixture.Reject("version", "identity header", f => f.MutateIdentity(i => i["packageVersion"] = "9.9.9"));
        fixture.Reject("RID", "identity header", f => f.MutateIdentity(i => i["runtimeIdentifier"] = "linux-x64"));
        fixture.Reject("source", "identity source", f => f.MutateIdentity(i => i["source"]!["commitSha"] = new string('f', 40)));
        fixture.Reject("caller canonical hash", "canonical hash is not exact", f => f.IdentityCanonicalSha = new string('A', 64));
        fixture.Reject("noncanonical identity file", "not RFC8785 canonical JSON", f => File.WriteAllText(f.IdentityPath, f.Identity.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n", new UTF8Encoding(false)));
        fixture.Reject("archive-only extra", "archive/package-root inventories", f => f.RebuildArchive((zip, _) => WriteEntry(zip, "extra.dll", [9])));
        fixture.Reject("zip-slip", "unsafe relative path", f => f.RebuildArchive((zip, _) => WriteEntry(zip, "../escape.dll", [9])));
        fixture.Reject("duplicate ZIP entry", "duplicate or unsafe", f => f.RebuildArchive((zip, _) => WriteEntry(zip, "HerdrOps.App.exe", [9])));
        fixture.Reject("manifest fileCount", "manifest inventory aggregate", f => f.MutateManifest(m => m["fileCount"] = 99));
        fixture.Reject("manifest content", "manifest inventory aggregate", f => f.MutateManifest(m => m["contentSha256"] = new string('A', 64)));
        fixture.Reject("manifest total", "manifest inventory aggregate", f => f.MutateManifest(m => m["totalBytes"] = 99999));
        fixture.Reject("extra package file", "manifest/package-root inventories", f => { File.WriteAllBytes(Path.Combine(f.PackageRoot, "extra.dll"), [1]); f.RebuildArchive(); });
        fixture.Reject("missing package file", "manifest/package-root inventories", f => { File.Delete(f.CorePath); f.RebuildArchive(); });
        fixture.Reject("App component hash", "identity component HerdrOps.App.exe", f => f.MutateIdentity(i => i["components"]!["app"]!["sha256"] = new string('B', 64)));
        fixture.Reject("Core component hash", "identity component HerdrOps.Core.exe", f => f.MutateIdentity(i => i["components"]!["core"]!["sha256"] = new string('C', 64)));
        fixture.Reject("App/Core byte swap", "identity component HerdrOps.App.exe", f => f.SwapComponentsAndRefreshEvidence());
        fixture.Reject("process-path transplant", "process is not the exact validated package App", f => f.ProcessPath = f.CorePath);
        fixture.RejectReparsePoint();

        Assert.AreEqual(RenderMode.SoftwareOnly, RenderOptions.ProcessRenderMode,
            "No hostile package may reach Hardware renderer selection.");
    }

    private static void WriteEntry(ZipArchive zip, string name, byte[] bytes)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.NoCompression);
        using var stream = entry.Open();
        stream.Write(bytes);
    }

    private sealed class PackageFixture : IDisposable
    {
        private const string ProfileId = "herdrops-v0.2-package-software-only-issue-149";
        private const string ReferenceId = "herdrops-v0.2-submark-nb-software-only-20260822";
        private const string ReferenceSha = "96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3";
        private const string PolicySha = "1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92";
        private static readonly JsonSerializerOptions StringOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        public string Root { get; }
        public string PackageRoot { get; }
        public string AppPath => Path.Combine(PackageRoot, "HerdrOps.App.exe");
        public string CorePath => Path.Combine(PackageRoot, "HerdrOps.Core.exe");
        public string ManifestPath => Path.Combine(PackageRoot, "package-manifest.json");
        public string ArchivePath => Path.Combine(Root, "HerdrOps-0.2.0-win-x64.zip");
        public string IdentityPath => Path.Combine(Root, "identity.json");
        public string ProfilePath => Path.Combine(Root, "package-identity-profile.json");
        public string Commit { get; } = new('a', 40);
        public string Tree { get; } = new('b', 40);
        public JsonObject Identity { get; private set; } = null!;
        public JsonObject Manifest { get; private set; } = null!;
        public string IdentityCanonicalSha { get; set; } = "";
        public string ArchiveSha { get; private set; } = "";
        public string ProcessPath { get; set; } = "";

        private PackageFixture(string root)
        {
            Root = root;
            PackageRoot = Path.Combine(root, "package");
        }

        public static PackageFixture Create()
        {
            var root = Path.Combine(Path.GetTempPath(), "herdrops-i10-validator-" + Guid.NewGuid().ToString("N"));
            var fixture = new PackageFixture(root);
            Directory.CreateDirectory(fixture.PackageRoot);
            File.Copy(FindProfile(), fixture.ProfilePath);
            File.WriteAllBytes(fixture.AppPath, Enumerable.Range(1, 32).Select(i => (byte)i).ToArray());
            File.WriteAllBytes(fixture.CorePath, Enumerable.Range(33, 32).Select(i => (byte)i).ToArray());
            fixture.ProcessPath = fixture.AppPath;
            fixture.Manifest = fixture.NewManifest();
            fixture.WriteManifest();
            fixture.RebuildArchive();
            fixture.Identity = fixture.NewIdentity();
            fixture.SyncIdentityBindings();
            fixture.WriteIdentity();
            _ = fixture.Validate();
            return fixture;
        }

        public void Reject(string name, string expected, Action<PackageFixture> mutate)
        {
            using var hostile = Create();
            mutate(hostile);
            var exception = Assert.ThrowsExactly<InvalidDataException>(() => hostile.Validate(), name);
            StringAssert.Contains(exception.Message, expected, name);
            Assert.AreEqual(RenderMode.SoftwareOnly, RenderOptions.ProcessRenderMode, name + " reached Hardware selection.");
        }

        public void RejectReparsePoint()
        {
            using var hostile = Create();
            var outside = Path.Combine(hostile.Root, "outside.bin");
            File.WriteAllBytes(outside, [7]);
            var link = Path.Combine(hostile.PackageRoot, "linked.bin");
            File.CreateSymbolicLink(link, outside);
            var exception = Assert.ThrowsExactly<InvalidDataException>(() => hostile.Validate(), "reparse point");
            StringAssert.Contains(exception.Message, "reparse point");
            Assert.AreEqual(RenderMode.SoftwareOnly, RenderOptions.ProcessRenderMode);
        }

        public void MutateIdentity(Action<JsonObject> mutation)
        {
            mutation(Identity);
            WriteIdentity();
        }

        public void MutateManifest(Action<JsonObject> mutation)
        {
            mutation(Manifest);
            WriteManifest();
            RebuildArchive();
            SyncIdentityBindings();
            WriteIdentity();
        }

        public void SwapComponentsAndRefreshEvidence()
        {
            var app = File.ReadAllBytes(AppPath);var core = File.ReadAllBytes(CorePath);
            File.WriteAllBytes(AppPath, core);File.WriteAllBytes(CorePath, app);
            Manifest = NewManifest();WriteManifest();RebuildArchive();
        }

        public void RebuildArchive(Action<ZipArchive, PackageFixture>? extra = null)
        {
            if (File.Exists(ArchivePath)) File.Delete(ArchivePath);
            using (var stream = new FileStream(ArchivePath, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None))
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
            {
                foreach (var path in Directory.EnumerateFiles(PackageRoot, "*", SearchOption.AllDirectories).OrderBy(p => p, StringComparer.Ordinal))
                {
                    var relative = Path.GetRelativePath(PackageRoot, path).Replace('\\', '/');
                    WriteEntry(zip, relative, File.ReadAllBytes(path));
                }
                extra?.Invoke(zip, this);
            }
            ArchiveSha = HashFile(ArchivePath);
            if (Identity is not null)
            {
                SyncIdentityBindings();
                WriteIdentity();
            }
        }

        private Issue10ValidatedPackage Validate() => Issue10PackageValidator.Validate(
            IdentityPath, IdentityCanonicalSha, ArchivePath, ArchiveSha, PackageRoot, ProfilePath, Commit, Tree, ProcessPath);

        private JsonObject NewManifest()
        {
            var files = new JsonArray(NewFile(AppPath, "HerdrOps.App.exe"), NewFile(CorePath, "HerdrOps.Core.exe"));
            var inventory = string.Concat(files.Select(n => $"{n!["path"]!.GetValue<string>()}\t{n["length"]!.GetValue<long>()}\t{n["sha256"]!.GetValue<string>()}\n"));
            return new JsonObject
            {
                ["schemaVersion"] = 1, ["profileId"] = ProfileId, ["issue"] = 149,
                ["packageVersion"] = "0.2.0", ["runtimeIdentifier"] = "win-x64",
                ["source"] = new JsonObject { ["commitSha"] = Commit, ["treeSha"] = Tree },
                ["referenceHost"] = new JsonObject { ["profileId"] = ReferenceId, ["profileSha256"] = ReferenceSha },
                ["renderer"] = new JsonObject { ["policy"] = "software-only-process-wide", ["wpfProcessRenderMode"] = "SoftwareOnly", ["policySha256"] = PolicySha },
                ["fileCount"] = 2, ["totalBytes"] = files.Sum(n => n!["length"]!.GetValue<long>()),
                ["contentSha256"] = Hash(Encoding.UTF8.GetBytes(inventory)), ["files"] = files,
                ["evidenceClass"] = "Static/PackagedCompatibilityPreparation"
            };
        }

        private JsonObject NewIdentity()
        {
            var profileBytes = File.ReadAllBytes(ProfilePath);
            using var profile = JsonDocument.Parse(profileBytes);
            var profileCanonicalSha = Hash(Encoding.UTF8.GetBytes(Canonical(profile.RootElement)));
            return new JsonObject
            {
                ["schemaVersion"] = 1, ["profileId"] = ProfileId, ["issue"] = 149,
                ["packageVersion"] = "0.2.0", ["runtimeIdentifier"] = "win-x64",
                ["source"] = new JsonObject { ["commitSha"] = Commit, ["treeSha"] = Tree },
                ["profile"] = new JsonObject { ["id"] = ProfileId, ["relativePath"] = "tools/packaging/v0.2/package-identity-profile.json", ["bytes"] = profileBytes.LongLength, ["fileSha256"] = Hash(profileBytes), ["canonicalSha256"] = profileCanonicalSha },
                ["archive"] = new JsonObject(), ["packageManifest"] = new JsonObject(),
                ["components"] = new JsonObject { ["app"] = Component(AppPath, "HerdrOps.App.exe"), ["core"] = Component(CorePath, "HerdrOps.Core.exe") },
                ["referenceHost"] = new JsonObject { ["profileId"] = ReferenceId, ["profileSha256"] = ReferenceSha },
                ["renderer"] = new JsonObject { ["policy"] = "software-only-process-wide", ["wpfProcessRenderMode"] = "SoftwareOnly" },
                ["evidenceBoundary"] = new JsonObject { ["evidenceClass"] = "PackagedCompatibilityPreparation", ["runtimeUse"] = "not-used", ["actualHerdrUsed"] = false, ["runtimeCredit"] = "NOT CLAIMED", ["releaseCredit"] = "NOT CLAIMED" }
            };
        }

        private void SyncIdentityBindings()
        {
            Identity["archive"] = new JsonObject { ["relativePath"] = "HerdrOps-0.2.0-win-x64.zip", ["fileName"] = "HerdrOps-0.2.0-win-x64.zip", ["bytes"] = new FileInfo(ArchivePath).Length, ["sha256"] = ArchiveSha };
            Identity["packageManifest"] = new JsonObject { ["fileName"] = "package-manifest.json", ["bytes"] = new FileInfo(ManifestPath).Length, ["sha256"] = HashFile(ManifestPath), ["contentSha256"] = Manifest["contentSha256"]!.GetValue<string>(), ["fileCount"] = int.Parse(Manifest["fileCount"]!.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture), ["totalBytes"] = long.Parse(Manifest["totalBytes"]!.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture) };
        }

        private static JsonObject Component(string path, string relative) => new() { ["relativePath"] = relative, ["bytes"] = new FileInfo(path).Length, ["sha256"] = HashFile(path) };
        private static JsonObject NewFile(string path, string relative) => new() { ["path"] = relative, ["length"] = new FileInfo(path).Length, ["sha256"] = HashFile(path) };
        private void WriteManifest() => WriteCanonical(ManifestPath, Manifest);
        private void WriteIdentity() { WriteCanonical(IdentityPath, Identity); IdentityCanonicalSha = Hash(Encoding.UTF8.GetBytes(Canonical(JsonDocument.Parse(File.ReadAllBytes(IdentityPath)).RootElement))); }
        private static void WriteCanonical(string path, JsonObject value) => File.WriteAllText(path, Canonical(JsonDocument.Parse(value.ToJsonString()).RootElement) + "\n", new UTF8Encoding(false));
        private static string Canonical(JsonElement value) => value.ValueKind switch { JsonValueKind.Object => "{" + string.Join(",", value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal).Select(p => JsonSerializer.Serialize(p.Name, StringOptions) + ":" + Canonical(p.Value))) + "}", JsonValueKind.Array => "[" + string.Join(",", value.EnumerateArray().Select(Canonical)) + "]", JsonValueKind.String => JsonSerializer.Serialize(value.GetString(), StringOptions), JsonValueKind.Number => value.GetInt64().ToString(System.Globalization.CultureInfo.InvariantCulture), JsonValueKind.True => "true", JsonValueKind.False => "false", JsonValueKind.Null => "null", _ => throw new InvalidDataException() };
        private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
        private static string HashFile(string path) => Hash(File.ReadAllBytes(path));
        private static string FindProfile() { var path = AppContext.BaseDirectory; while (path is not null) { var candidate = Path.Combine(path, "tools", "packaging", "v0.2", "package-identity-profile.json"); if (File.Exists(candidate)) return candidate; path = Directory.GetParent(path)?.FullName; } throw new FileNotFoundException("Repository package profile not found."); }
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
