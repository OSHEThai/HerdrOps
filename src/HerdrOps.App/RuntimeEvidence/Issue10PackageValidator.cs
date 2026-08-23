using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace HerdrOps.App.RuntimeEvidence;

internal sealed class Issue10ValidatedPackage : IDisposable
{
    private readonly HeldPackageFile[] _heldFiles;
    private bool _disposed;

    internal Issue10ValidatedPackage(string appPath,string appSha256,string corePath,string coreSha256,
        string manifestPath,string manifestSha256,string identityFileSha256,string profileFileSha256,
        string archiveSha256,HeldPackageFile[] heldFiles)
    {
        AppPath=appPath;AppSha256=appSha256;CorePath=corePath;CoreSha256=coreSha256;
        ManifestPath=manifestPath;ManifestSha256=manifestSha256;IdentityFileSha256=identityFileSha256;
        ProfileFileSha256=profileFileSha256;ArchiveSha256=archiveSha256;_heldFiles=heldFiles;
    }

    internal string AppPath { get; }
    internal string AppSha256 { get; }
    internal string CorePath { get; }
    internal string CoreSha256 { get; }
    internal string ManifestPath { get; }
    internal string ManifestSha256 { get; }
    internal string IdentityFileSha256 { get; }
    internal string ProfileFileSha256 { get; }
    internal string ArchiveSha256 { get; }

    internal void Revalidate(string boundary)
    {
        ObjectDisposedException.ThrowIf(_disposed,this);
        foreach(var file in _heldFiles)file.Revalidate(boundary);
    }

    public void Dispose()
    {
        if(_disposed)return;_disposed=true;
        foreach(var file in _heldFiles)file.Dispose();
    }

    internal sealed class HeldPackageFile : IDisposable
    {
        private readonly string _context;private readonly string _path;private readonly string _sha256;
        private readonly FileStream _stream;private readonly RendererFileIdentity _identity;private readonly string _finalPath;
        internal HeldPackageFile(string path,string sha256,string context)
        {
            _context=context;_path=Path.GetFullPath(path);_sha256=sha256;
            _stream=new FileStream(_path,FileMode.Open,FileAccess.Read,FileShare.Read);
            try
            {
                _finalPath=RendererTargetNativeMethods.GetFinalPath(_stream.SafeFileHandle);
                _identity=RendererTargetNativeMethods.GetFileIdentity(_stream.SafeFileHandle);
                if(!StringComparer.OrdinalIgnoreCase.Equals(_finalPath,_path)||_identity.NumberOfLinks!=1||HashHeld()!=_sha256)
                    throw new InvalidDataException($"Issue #10 {_context} held-file identity is not exact.");
            }
            catch { _stream.Dispose();throw; }
        }
        internal void Revalidate(string boundary)
        {
            var identity=RendererTargetNativeMethods.GetFileIdentity(_stream.SafeFileHandle);
            var finalPath=RendererTargetNativeMethods.GetFinalPath(_stream.SafeFileHandle);
            if(identity!=_identity||!StringComparer.OrdinalIgnoreCase.Equals(finalPath,_finalPath)||HashHeld()!=_sha256)
                throw new InvalidDataException($"Issue #10 {_context} changed across {boundary}.");
        }
        private string HashHeld(){_stream.Position=0;var hash=Convert.ToHexString(SHA256.HashData(_stream));_stream.Position=0;return hash;}
        public void Dispose()=>_stream.Dispose();
    }
}

internal static class Issue10PackageValidator
{
    private const string ProfileId = "herdrops-v0.2-package-software-only-issue-149";
    private const string CoreFileName = "HerdrOps." + "Core.exe";
    private const string ProfileFileSha = "9DC76EC4A3A634ED49B551CCB83824DB76D48E0EA6DA2A50663F8BA31F549BEB";
    private const string ProfileCanonicalSha = "D642524E46F06CED9F066CBEE197E6CFB1C722D64714DC0C8C0C39106BB90F98";
    private const string ReferenceProfileId = "herdrops-v0.2-submark-nb-software-only-20260822";
    private const string ReferenceProfileSha = "96D01ED15A536F2DF50B59B43CFDEB3683DCE8667AE2E7BF6A96124182FE13A3";
    private const string RendererPolicySha = "1D37C9C39449556EB30F9AB5B734F0C5411CF4203321AF0B238993D017229E92";
    private static readonly JsonSerializerOptions StringOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    internal static Issue10ValidatedPackage Validate(
        string identityPath, string identityCanonicalSha, string archivePath, string archiveSha,
        string packageRoot, string profilePath, string commit, string tree, string processPath,
        Action<string>? leaseAcquisitionHook = null)
    {
        identityPath = Path.GetFullPath(identityPath); archivePath = Path.GetFullPath(archivePath);
        packageRoot = Path.GetFullPath(packageRoot).TrimEnd(Path.DirectorySeparatorChar); profilePath = Path.GetFullPath(profilePath);
        RejectReparsePath(packageRoot); RejectReparsePath(identityPath); RejectReparsePath(archivePath); RejectReparsePath(profilePath);
        if (!Directory.Exists(packageRoot) || !File.Exists(identityPath) || !File.Exists(archivePath) || !File.Exists(profilePath)) throw new InvalidDataException("Issue #10 package inputs are missing.");
        var profileBytes = ReadBounded(profilePath, 4 * 1024 * 1024);
        if (Hash(profileBytes) != ProfileFileSha) throw new InvalidDataException("Issue #10 committed v0.2 package profile bytes drifted.");
        using var profile = ParseStrict(profileBytes, "package profile");
        if (Hash(Encoding.UTF8.GetBytes(Canonicalize(profile.RootElement))) != ProfileCanonicalSha) throw new InvalidDataException("Issue #10 package profile canonical identity drifted.");
        ValidateProfile(profile.RootElement);

        var identityBytes = ReadBounded(identityPath, 4 * 1024 * 1024);
        using var identity = ParseExactCanonical(identityBytes, "package identity");
        var identityCanonical = Canonicalize(identity.RootElement);
        if (Hash(Encoding.UTF8.GetBytes(identityCanonical)) != identityCanonicalSha) throw new InvalidDataException("Issue #10 package identity canonical hash is not exact.");
        ValidateIdentity(identity.RootElement, identityBytes.LongLength, commit, tree, archiveSha);

        var archiveBytes = ReadBounded(archivePath, 512L * 1024 * 1024);
        if (Hash(archiveBytes) != archiveSha) throw new InvalidDataException("Issue #10 package archive bytes are not exact.");
        var root = identity.RootElement;
        if (root.GetProperty("archive").GetProperty("bytes").GetInt64() != archiveBytes.LongLength) throw new InvalidDataException("Issue #10 package archive length is not exact.");

        var manifestPath = Path.Combine(packageRoot, "package-manifest.json");
        var manifestBytes = ReadBounded(manifestPath, 16 * 1024 * 1024);
        using var manifest = ParseExactCanonical(manifestBytes, "package manifest");
        ValidateManifest(manifest.RootElement, commit, tree);
        var manifestSha = Hash(manifestBytes);
        var identityManifest = root.GetProperty("packageManifest");
        if (identityManifest.GetProperty("bytes").GetInt64() != manifestBytes.LongLength ||
            identityManifest.GetProperty("sha256").GetString() != manifestSha) throw new InvalidDataException("Issue #10 manifest leaf is not exact.");

        using var heldRoot = InventoryDirectoryHeld(packageRoot);
        var rootInventory = heldRoot.Entries;
        RequireInventoryEqual(rootInventory, InventoryDirectory(packageRoot), "repeated package-root");
        var manifestInventory = ReadManifestInventory(manifest.RootElement);
        var withoutManifest = rootInventory.Where(entry => entry.Path != "package-manifest.json").ToArray();
        RequireInventoryEqual(manifestInventory, withoutManifest, "manifest/package-root");
        var inventoryText = InventoryText(manifestInventory);
        if (Hash(Encoding.UTF8.GetBytes(inventoryText)) != manifest.RootElement.GetProperty("contentSha256").GetString() ||
            manifest.RootElement.GetProperty("fileCount").GetInt32() != manifestInventory.Length ||
            manifest.RootElement.GetProperty("totalBytes").GetInt64() != manifestInventory.Sum(entry => entry.Length)) throw new InvalidDataException("Issue #10 manifest inventory aggregate is invalid.");
        if (identityManifest.GetProperty("contentSha256").GetString() != manifest.RootElement.GetProperty("contentSha256").GetString() ||
            identityManifest.GetProperty("fileCount").GetInt32() != manifestInventory.Length ||
            identityManifest.GetProperty("totalBytes").GetInt64() != manifestInventory.Sum(entry => entry.Length)) throw new InvalidDataException("Issue #10 identity manifest aggregate is invalid.");

        var archiveInventory = InventoryArchive(archiveBytes);
        RequireInventoryEqual(archiveInventory, InventoryArchive(archiveBytes), "repeated archive");
        RequireInventoryEqual(archiveInventory, rootInventory, "archive/package-root");
        var appEntry = RequireSingle(manifestInventory, "HerdrOps.App.exe");
        var coreEntry = RequireSingle(manifestInventory, CoreFileName);
        ValidateComponent(root.GetProperty("components").GetProperty("app"), appEntry, "HerdrOps.App.exe");
        ValidateComponent(root.GetProperty("components").GetProperty("core"), coreEntry, CoreFileName);
        var appPath = Path.Combine(packageRoot, appEntry.Path.Replace('/', Path.DirectorySeparatorChar));
        var actualApp = Path.GetFullPath(processPath);
        if (!StringComparer.OrdinalIgnoreCase.Equals(appPath, actualApp)) throw new InvalidDataException("Issue #10 process is not the exact validated package App.");
        var corePath=Path.Combine(packageRoot,coreEntry.Path.Replace('/',Path.DirectorySeparatorChar));
        var identityFileSha=Hash(identityBytes);var leases=new List<Issue10ValidatedPackage.HeldPackageFile>();
        try
        {
            foreach(var item in new[]{(identityPath,identityFileSha,"package identity"),(profilePath,ProfileFileSha,"package profile"),(archivePath,archiveSha,"package archive"),(manifestPath,manifestSha,"package manifest"),(appPath,appEntry.Sha256,"package App"),(corePath,coreEntry.Sha256,"package Core")})
            {
                leaseAcquisitionHook?.Invoke(item.Item3);
                leases.Add(new Issue10ValidatedPackage.HeldPackageFile(item.Item1,item.Item2,item.Item3));
            }
            var lease=new Issue10ValidatedPackage(appPath,appEntry.Sha256,corePath,coreEntry.Sha256,manifestPath,manifestSha,identityFileSha,ProfileFileSha,archiveSha,leases.ToArray());
            lease.Revalidate("validated package lease acquisition");return lease;
        }
        catch { foreach(var lease in leases.AsEnumerable().Reverse())lease.Dispose();throw; }
    }

    private static void ValidateProfile(JsonElement p)
    {
        Exact(p, "schemaVersion","profileId","issue","packageVersion","runtimeIdentifier","archiveFileName","packageManifestFileName","sourcePolicy","approval","components","referenceHost","renderer","evidenceBoundary");
        Require(p.GetProperty("schemaVersion").GetInt32() == 1 && p.GetProperty("profileId").GetString() == ProfileId && p.GetProperty("issue").GetInt32() == 149 && p.GetProperty("packageVersion").GetString() == "0.2.0" && p.GetProperty("runtimeIdentifier").GetString() == "win-x64", "profile identity");
        Require(p.GetProperty("archiveFileName").GetString() == "HerdrOps-0.2.0-win-x64.zip" && p.GetProperty("packageManifestFileName").GetString() == "package-manifest.json", "profile filenames");
        var components=p.GetProperty("components"); Exact(components,"appRelativePath","coreRelativePath"); Require(components.GetProperty("appRelativePath").GetString()=="HerdrOps.App.exe"&&components.GetProperty("coreRelativePath").GetString()==CoreFileName,"profile components");
        var reference=p.GetProperty("referenceHost");Exact(reference,"profileId","profileSha256");Require(reference.GetProperty("profileId").GetString()==ReferenceProfileId&&reference.GetProperty("profileSha256").GetString()==ReferenceProfileSha,"profile reference host");
        var renderer=p.GetProperty("renderer");Exact(renderer,"policy","wpfProcessRenderMode","policySha256");Require(renderer.GetProperty("policy").GetString()=="software-only-process-wide"&&renderer.GetProperty("wpfProcessRenderMode").GetString()=="SoftwareOnly"&&renderer.GetProperty("policySha256").GetString()==RendererPolicySha,"profile renderer");
    }

    private static void ValidateIdentity(JsonElement i, long fileBytes, string commit, string tree, string archiveSha)
    {
        Exact(i,"schemaVersion","profileId","issue","packageVersion","runtimeIdentifier","source","profile","archive","packageManifest","components","referenceHost","renderer","evidenceBoundary");
        Require(i.GetProperty("schemaVersion").GetInt32()==1&&i.GetProperty("profileId").GetString()==ProfileId&&i.GetProperty("issue").GetInt32()==149&&i.GetProperty("packageVersion").GetString()=="0.2.0"&&i.GetProperty("runtimeIdentifier").GetString()=="win-x64","identity header");
        var source=i.GetProperty("source");Exact(source,"commitSha","treeSha");Require(source.GetProperty("commitSha").GetString()==commit&&source.GetProperty("treeSha").GetString()==tree,"identity source");
        var profile=i.GetProperty("profile");Exact(profile,"id","relativePath","bytes","fileSha256","canonicalSha256");Require(profile.GetProperty("id").GetString()==ProfileId&&profile.GetProperty("relativePath").GetString()=="tools/packaging/v0.2/package-identity-profile.json"&&profile.GetProperty("bytes").GetInt64()==1330&&profile.GetProperty("fileSha256").GetString()==ProfileFileSha&&profile.GetProperty("canonicalSha256").GetString()==ProfileCanonicalSha,"identity profile");
        var archive=i.GetProperty("archive");Exact(archive,"relativePath","fileName","bytes","sha256");Require(archive.GetProperty("relativePath").GetString()=="HerdrOps-0.2.0-win-x64.zip"&&archive.GetProperty("fileName").GetString()=="HerdrOps-0.2.0-win-x64.zip"&&archive.GetProperty("sha256").GetString()==archiveSha,"identity archive");
        var packageManifest=i.GetProperty("packageManifest");Exact(packageManifest,"fileName","bytes","sha256","contentSha256","fileCount","totalBytes");Require(packageManifest.GetProperty("fileName").GetString()=="package-manifest.json","identity manifest filename");
        var components=i.GetProperty("components");Exact(components,"app","core");
        var reference=i.GetProperty("referenceHost");Exact(reference,"profileId","profileSha256");Require(reference.GetProperty("profileId").GetString()==ReferenceProfileId&&reference.GetProperty("profileSha256").GetString()==ReferenceProfileSha,"identity reference host");
        var renderer=i.GetProperty("renderer");Exact(renderer,"policy","wpfProcessRenderMode");Require(renderer.GetProperty("policy").GetString()=="software-only-process-wide"&&renderer.GetProperty("wpfProcessRenderMode").GetString()=="SoftwareOnly","identity renderer");
        var boundary=i.GetProperty("evidenceBoundary");Exact(boundary,"evidenceClass","runtimeUse","actualHerdrUsed","runtimeCredit","releaseCredit");Require(boundary.GetProperty("evidenceClass").GetString()=="PackagedCompatibilityPreparation"&&boundary.GetProperty("runtimeUse").GetString()=="not-used"&&!boundary.GetProperty("actualHerdrUsed").GetBoolean()&&boundary.GetProperty("runtimeCredit").GetString()=="NOT CLAIMED"&&boundary.GetProperty("releaseCredit").GetString()=="NOT CLAIMED","identity boundary");
        _=fileBytes;
    }

    private static void ValidateManifest(JsonElement m,string commit,string tree)
    {
        Exact(m,"schemaVersion","profileId","issue","packageVersion","runtimeIdentifier","source","referenceHost","renderer","fileCount","totalBytes","contentSha256","files","evidenceClass");
        Require(m.GetProperty("schemaVersion").GetInt32()==1&&m.GetProperty("profileId").GetString()==ProfileId&&m.GetProperty("issue").GetInt32()==149&&m.GetProperty("packageVersion").GetString()=="0.2.0"&&m.GetProperty("runtimeIdentifier").GetString()=="win-x64"&&m.GetProperty("evidenceClass").GetString()=="Static/PackagedCompatibilityPreparation","manifest header");
        var source=m.GetProperty("source");Exact(source,"commitSha","treeSha");Require(source.GetProperty("commitSha").GetString()==commit&&source.GetProperty("treeSha").GetString()==tree,"manifest source");
        var reference=m.GetProperty("referenceHost");Exact(reference,"profileId","profileSha256");Require(reference.GetProperty("profileId").GetString()==ReferenceProfileId&&reference.GetProperty("profileSha256").GetString()==ReferenceProfileSha,"manifest reference host");
        var renderer=m.GetProperty("renderer");Exact(renderer,"policy","wpfProcessRenderMode","policySha256");Require(renderer.GetProperty("policy").GetString()=="software-only-process-wide"&&renderer.GetProperty("wpfProcessRenderMode").GetString()=="SoftwareOnly"&&renderer.GetProperty("policySha256").GetString()==RendererPolicySha,"manifest renderer");
    }

    private static Entry[] ReadManifestInventory(JsonElement manifest)
    {
        var entries=new List<Entry>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var item in manifest.GetProperty("files").EnumerateArray()){Exact(item,"path","length","sha256");var path=item.GetProperty("path").GetString()??"";SafeRelative(path);if(!seen.Add(path))throw new InvalidDataException("Issue #10 manifest has duplicate paths.");entries.Add(new(path,item.GetProperty("length").GetInt64(),RequireSha(item.GetProperty("sha256").GetString())));}
        return entries.OrderBy(e=>e.Path,StringComparer.Ordinal).ToArray();
    }

    private static Entry[] InventoryDirectory(string root)
    {
        var entries=new List<Entry>();
        foreach(var path in Directory.EnumerateFileSystemEntries(root,"*",SearchOption.AllDirectories)){var attr=File.GetAttributes(path);if((attr&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Issue #10 package root contains a reparse point.");if((attr&FileAttributes.Directory)!=0)continue;var relative=Path.GetRelativePath(root,path).Replace('\\','/');SafeRelative(relative);using var stream=OpenHeld(path);entries.Add(new(relative,stream.Length,Hash(stream)));}
        return entries.OrderBy(e=>e.Path,StringComparer.Ordinal).ToArray();
    }

    private static HeldInventory InventoryDirectoryHeld(string root)
    {
        var entries=new List<Entry>();var streams=new List<FileStream>();
        try
        {
            foreach(var path in Directory.EnumerateFileSystemEntries(root,"*",SearchOption.AllDirectories))
            {
                var attr=File.GetAttributes(path);if((attr&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Issue #10 package root contains a reparse point.");if((attr&FileAttributes.Directory)!=0)continue;
                var relative=Path.GetRelativePath(root,path).Replace('\\','/');SafeRelative(relative);var stream=OpenHeld(path);streams.Add(stream);entries.Add(new(relative,stream.Length,Hash(stream)));
            }
            return new HeldInventory(entries.OrderBy(e=>e.Path,StringComparer.Ordinal).ToArray(),streams);
        }
        catch { foreach(var stream in streams)stream.Dispose();throw; }
    }

    private static Entry[] InventoryArchive(byte[] bytes)
    {
        var entries=new List<Entry>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);using var stream=new MemoryStream(bytes,false);using var zip=new ZipArchive(stream,ZipArchiveMode.Read,false);if(zip.Entries.Count>4096)throw new InvalidDataException("Issue #10 archive has too many entries.");long total=0;
        foreach(var item in zip.Entries){SafeRelative(item.FullName);if(!seen.Add(item.FullName)||item.FullName.EndsWith('/'))throw new InvalidDataException("Issue #10 archive path is duplicate or unsafe.");total=checked(total+item.Length);if(total>1024L*1024*1024||item.CompressedLength<=0&&item.Length>0||item.Length>item.CompressedLength*1000m)throw new InvalidDataException("Issue #10 archive expansion bounds failed.");using var content=item.Open();entries.Add(new(item.FullName,item.Length,Hash(content)));}
        return entries.OrderBy(e=>e.Path,StringComparer.Ordinal).ToArray();
    }

    private static void ValidateComponent(JsonElement value,Entry entry,string path){Exact(value,"relativePath","bytes","sha256");Require(value.GetProperty("relativePath").GetString()==path&&value.GetProperty("bytes").GetInt64()==entry.Length&&value.GetProperty("sha256").GetString()==entry.Sha256,$"identity component {path}");}
    private static Entry RequireSingle(Entry[] entries,string path){var matches=entries.Where(e=>e.Path==path).ToArray();if(matches.Length!=1)throw new InvalidDataException($"Issue #10 package omitted exact {path}.");return matches[0];}
    private static void RequireInventoryEqual(Entry[] expected,Entry[] actual,string context){if(expected.Length!=actual.Length||expected.Where((entry,index)=>entry!=actual[index]).Any())throw new InvalidDataException($"Issue #10 {context} inventories are not exact.");}
    private static string InventoryText(IEnumerable<Entry> entries)=>string.Concat(entries.OrderBy(e=>e.Path,StringComparer.Ordinal).Select(e=>$"{e.Path}\t{e.Length.ToString(CultureInfo.InvariantCulture)}\t{e.Sha256}\n"));
    private static byte[] ReadBounded(string path,long maximum){using var stream=OpenHeld(path);if(stream.Length<=0||stream.Length>maximum)throw new InvalidDataException("Issue #10 package input exceeds bounds.");var bytes=new byte[checked((int)stream.Length)];stream.ReadExactly(bytes);return bytes;}
    private static FileStream OpenHeld(string path)=>new(path,FileMode.Open,FileAccess.Read,FileShare.Read);
    private static void RejectReparsePath(string path){var current=Path.GetFullPath(path);while(!string.IsNullOrEmpty(current)){if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Issue #10 package path contains a reparse point.");var parent=Path.GetDirectoryName(current);if(string.IsNullOrEmpty(parent)||parent==current)break;current=parent;}}
    private static JsonDocument ParseExactCanonical(byte[] bytes,string context){if(bytes.Length<2||bytes[^1]!=(byte)'\n'||bytes[^2]==(byte)'\r'||(bytes.Length>=3&&bytes[0]==0xEF&&bytes[1]==0xBB&&bytes[2]==0xBF))throw new InvalidDataException($"Issue #10 {context} is not exact UTF-8 canonical JSON plus LF.");var json=new UTF8Encoding(false,true).GetString(bytes,0,bytes.Length-1);var document=JsonDocument.Parse(json,new JsonDocumentOptions{AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow});RejectDuplicates(document.RootElement);if(Canonicalize(document.RootElement)!=json){document.Dispose();throw new InvalidDataException($"Issue #10 {context} is not RFC8785 canonical JSON.");}return document;}
    private static JsonDocument ParseStrict(byte[] bytes,string context){if(bytes.Length<2||bytes[^1]!=(byte)'\n'||(bytes.Length>=3&&bytes[0]==0xEF&&bytes[1]==0xBB&&bytes[2]==0xBF))throw new InvalidDataException($"Issue #10 {context} is not strict UTF-8 JSON plus LF.");var json=new UTF8Encoding(false,true).GetString(bytes,0,bytes.Length-1);var document=JsonDocument.Parse(json,new JsonDocumentOptions{AllowTrailingCommas=false,CommentHandling=JsonCommentHandling.Disallow});RejectDuplicates(document.RootElement);return document;}
    private static string Canonicalize(JsonElement value)=>value.ValueKind switch{JsonValueKind.Object=>"{"+string.Join(",",value.EnumerateObject().OrderBy(p=>p.Name,StringComparer.Ordinal).Select(p=>JsonSerializer.Serialize(p.Name,StringOptions)+":"+Canonicalize(p.Value)))+"}",JsonValueKind.Array=>"["+string.Join(",",value.EnumerateArray().Select(Canonicalize))+"]",JsonValueKind.String=>JsonSerializer.Serialize(value.GetString(),StringOptions),JsonValueKind.Number=>value.TryGetInt64(out var number)?number.ToString(CultureInfo.InvariantCulture):throw new InvalidDataException("Issue #10 canonical package JSON contains a non-integer number."),JsonValueKind.True=>"true",JsonValueKind.False=>"false",JsonValueKind.Null=>"null",_=>throw new InvalidDataException("Issue #10 canonical package JSON contains an unsupported value.")};
    private static void RejectDuplicates(JsonElement value){if(value.ValueKind==JsonValueKind.Object){var seen=new HashSet<string>(StringComparer.Ordinal);foreach(var property in value.EnumerateObject()){if(!seen.Add(property.Name))throw new InvalidDataException("Issue #10 package JSON has duplicate properties.");RejectDuplicates(property.Value);}}else if(value.ValueKind==JsonValueKind.Array){foreach(var item in value.EnumerateArray())RejectDuplicates(item);}}
    private static void Exact(JsonElement value,params string[] names){var actual=value.ValueKind==JsonValueKind.Object?value.EnumerateObject().Select(p=>p.Name).ToArray():[];if(actual.Length!=names.Length||actual.Any(name=>!names.Contains(name,StringComparer.Ordinal)))throw new InvalidDataException($"Issue #10 package object shape is not exact: {string.Join(',',names)}.");}
    private static void SafeRelative(string path){if(string.IsNullOrWhiteSpace(path)||Path.IsPathRooted(path)||path.Contains('\\')||path.StartsWith('/')||path.EndsWith('/')||path.Split('/').Any(segment=>segment is "" or "." or ".."))throw new InvalidDataException("Issue #10 package contains an unsafe relative path.");}
    private static string RequireSha(string? value){if(value is null||value.Length!=64||value.Any(c=>!char.IsAsciiHexDigitUpper(c)))throw new InvalidDataException("Issue #10 package SHA-256 is invalid.");return value;}
    private static void Require(bool condition,string context){if(!condition)throw new InvalidDataException($"Issue #10 {context} is invalid.");}
    private static string Hash(byte[] bytes)=>Convert.ToHexString(SHA256.HashData(bytes));
    private static string Hash(Stream stream)=>Convert.ToHexString(SHA256.HashData(stream));
    private sealed record Entry(string Path,long Length,string Sha256);
    private sealed class HeldInventory(Entry[] entries,List<FileStream> streams):IDisposable { internal Entry[] Entries { get; }=entries; public void Dispose(){foreach(var stream in streams)stream.Dispose();} }
}
