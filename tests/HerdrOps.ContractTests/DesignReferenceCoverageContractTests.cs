using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HerdrOps.ContractTests;

[TestClass]
public sealed class DesignReferenceCoverageContractTests
{
    private const string MappingDocument = "docs/design/implementation/v0.7-issue-35-design-parity.md";

    private static readonly ReferenceEntry[] ExpectedReferences =
    [
        new("01-overview.png", 1672, 941, 1592813, "2D390E965001986EB95E0C395177FC978385C98927B117AB0DE7C1C80266B90B", "Page: `overview`"),
        new("02-live-organization.png", 1672, 941, 1518762, "21531405D1BF5F8C520F60E98107C464071EB089327D35D34552486AE982C35D", "Page: `live-organization`"),
        new("03-realtime-activity.png", 1672, 941, 1739843, "1EFBF8A309665511E6BF330E736D2B4CE96791338DB2101B7723B1A5C987BD0F", "Page: `realtime-activity`"),
        new("04-delegation-graph.png", 1672, 941, 1659041, "61831A14CA46726C1CB5376F61957EA2CBDFAB534F3D681F02561B38CB774AA1", "Page: `delegation-graph`"),
        new("05-agent-detail.png", 1672, 941, 1663880, "6E8E8749ACC3D791CF3719DD0173E75B7BB52FA1ECD3A2319271B41F719CAF84", "Page: `agent-detail`"),
        new("06-task-alignment.png", 1672, 941, 1585608, "0A9AEBBFB97C23F2A0593248E9FFADFD5F5B4579161ED340496E2BD3B45E832D", "Page: `task-alignment`"),
        new("07-file-activity.png", 1672, 941, 1672825, "2BFB03357D9FFE4D4C11582D311D45CF2CFCCBD69A63D15130FD1EEBA0537F24", "Page: `file-activity`"),
        new("08-compliance-queue.png", 1672, 941, 1714456, "685B54499D36C564A67FD74F81798825470F462FE8D5379D6C1D47E1ABABB45C", "Page: `compliance-queue`"),
        new("09-evaluation.png", 1672, 941, 1483137, "7721C24EE49887286854D07132BBFE12C52B028AAE50CE7EB8062F0877C2B23D", "Page: `evaluation`"),
        new("10-daily-summary.png", 1672, 941, 1627596, "A44CAFDFB9A8B34694B67B6AABAD86B8B65A99A8A947C7CAB83C11FE7464F693", "Page: `daily-summary`"),
        new("11-widget-concepts.png", 1536, 1024, 1800245, "6AB57A967BE8C62A436A8F5C6DBB89616B210E66DD34AB851D148B4DCC1A904A", "Widget concepts: 8 approved concepts"),
    ];

    private static readonly PageEntry[] ExpectedPages =
    [
        new("overview", "Overview", "ภาพรวม", "OverviewView", "OverviewPage"),
        new("live-organization", "Live Organization", "โครงสร้างองค์กรสด", "LiveOrganizationView", "LiveOrganizationPage"),
        new("realtime-activity", "Realtime Activity", "กิจกรรมเวลาจริง", "RealtimeActivityView", "RealtimeActivityPage"),
        new("delegation-graph", "Delegation Graph", "กราฟการมอบหมาย", "DelegationGraphView", "DelegationGraphPage"),
        new("agent-detail", "Agent Detail", "รายละเอียดเอเจนต์", "AgentDetailView", "AgentDetailPage"),
        new("task-alignment", "Task Alignment", "ความสอดคล้องของงาน", "TaskAlignmentView", "TaskAlignmentPage"),
        new("file-activity", "File Activity", "กิจกรรมไฟล์", "FileActivityView", "FileActivityPage"),
        new("compliance-queue", "Compliance Queue", "คิวตรวจความสอดคล้อง", "ComplianceQueueView", "ComplianceQueuePage"),
        new("evaluation", "Evaluation", "การประเมิน", "EvaluationView", "EvaluationPage"),
        new("daily-summary", "Daily Summary", "สรุปรายวัน", "DailySummaryView", "DailySummaryPage"),
    ];

    private static readonly WidgetEntry[] ExpectedWidgets =
    [
        new("Compact", "CompactPreview", "Compact"),
        new("Normal", "NormalPreview", "Normal"),
        new("Expanded", "ExpandedPreview", "Expanded"),
        new("FloatingMini", "MiniPreview", "FloatingMini"),
        new("FloatingVertical", "VerticalPreview", "FloatingVertical"),
        new("Notification", "NotificationPreview", "Notification"),
        new("AgentDetailPopup", "AgentDetailPreview", "AgentDetailPopup"),
    ];

    private static readonly StatusEntry[] ExpectedStatuses =
    [
        new("Working", "Working", "Green", "StatusWorking"),
        new("Idle", "Idle", "Amber", "StatusIdle"),
        new("Blocked", "Blocked", "Red/coral", "StatusBlocked"),
        new("Review", "Review", "Purple", "StatusReview"),
        new("Done", "Done", "Blue", "StatusDone"),
        new("Offline", "Offline/Unknown", "Slate gray", "StatusOffline"),
    ];

    [TestMethod]
    public void ManifestHasExactImmutableCoverageAndTrackedReferenceBytes()
    {
        var repositoryRoot = FindRepositoryRoot();
        var manifest = ReadRepositoryFile(repositoryRoot, "docs", "design", "reference", "MANIFEST.md");
        var rows = Regex.Matches(
                manifest,
                @"^\| `(?<file>[^`]+)` \| (?<width>\d+)×(?<height>\d+) \| (?<bytes>[\d,]+) \| `(?<hash>[0-9A-Fa-f]{64})` \|$",
                RegexOptions.Multiline | RegexOptions.CultureInvariant)
            .Cast<Match>()
            .ToArray();

        Assert.HasCount(ExpectedReferences.Length, rows, "Manifest reference cardinality changed.");
        CollectionAssert.AreEqual(
            ExpectedReferences.Select(reference => reference.FileName).ToArray(),
            rows.Select(row => row.Groups["file"].Value).ToArray(),
            "Manifest references must remain complete, ordered and duplicate-free.");
        Assert.AreEqual(
            rows.Length,
            rows.Select(row => row.Groups["file"].Value).Distinct(StringComparer.Ordinal).Count(),
            "Manifest contains duplicate reference filenames.");
        Assert.AreEqual(
            rows.Length,
            rows.Select(row => row.Groups["hash"].Value.ToUpperInvariant()).Distinct(StringComparer.Ordinal).Count(),
            "Manifest contains duplicate reference hashes.");

        foreach (var expected in ExpectedReferences)
        {
            var row = rows.Single(candidate => candidate.Groups["file"].Value == expected.FileName);
            Assert.AreEqual(expected.Width, ParseInt(row, "width"), $"Manifest width changed: {expected.FileName}");
            Assert.AreEqual(expected.Height, ParseInt(row, "height"), $"Manifest height changed: {expected.FileName}");
            Assert.AreEqual(expected.Bytes, ParseLong(row, "bytes"), $"Manifest byte count changed: {expected.FileName}");
            Assert.AreEqual(expected.Sha256, row.Groups["hash"].Value.ToUpperInvariant(), $"Manifest hash changed: {expected.FileName}");

            var relativePath = Path.Combine("docs", "design", "reference", expected.FileName);
            var absolutePath = Path.Combine(repositoryRoot, relativePath);
            Assert.IsTrue(File.Exists(absolutePath), $"Immutable reference is missing: {absolutePath}");
            AssertTrackedByGit(repositoryRoot, relativePath);

            var bytes = File.ReadAllBytes(absolutePath);
            Assert.AreEqual(expected.Bytes, bytes.LongLength, $"Reference byte count changed: {expected.FileName}");
            Assert.AreEqual(expected.Sha256, Convert.ToHexString(SHA256.HashData(bytes)), $"Reference bytes changed: {expected.FileName}");
            var dimensions = ReadPngDimensions(bytes, expected.FileName);
            Assert.AreEqual(expected.Width, dimensions.Width, $"Reference width changed: {expected.FileName}");
            Assert.AreEqual(expected.Height, dimensions.Height, $"Reference height changed: {expected.FileName}");
        }
    }

    [TestMethod]
    public void MappingDocumentHasOneFailClosedRowPerManifestReference()
    {
        var repositoryRoot = FindRepositoryRoot();
        var document = ReadRepositoryFile(repositoryRoot, MappingDocument.Split('/'));
        var rows = Regex.Matches(
                document,
                @"^\| (?<ordinal>\d{2}) \| `(?<file>[^`]+)` \| (?<width>\d+)×(?<height>\d+) \| (?<bytes>[\d,]+) \| `(?<hash>[0-9A-Fa-f]{64})` \| (?<destination>[^|]+) \| (?<surface>[^|]+) \| (?<evidence>[^|]+) \| (?<accessibility>[^|]+) \| (?<review>[^|]+) \|$",
                RegexOptions.Multiline | RegexOptions.CultureInvariant)
            .Cast<Match>()
            .ToArray();

        Assert.HasCount(ExpectedReferences.Length, rows, "Mapping cardinality must match the eleven-entry manifest.");
        CollectionAssert.AreEqual(
            ExpectedReferences.Select(reference => reference.FileName).ToArray(),
            rows.Select(row => row.Groups["file"].Value).ToArray(),
            "Mapping must cover every manifest reference exactly once and in manifest order.");
        Assert.AreEqual(
            rows.Length,
            rows.Select(row => row.Groups["file"].Value).Distinct(StringComparer.Ordinal).Count(),
            "Mapping contains duplicate reference rows.");

        foreach (var (expected, row) in ExpectedReferences.Zip(rows))
        {
            Assert.AreEqual(expected.Width, ParseInt(row, "width"), $"Mapping width changed: {expected.FileName}");
            Assert.AreEqual(expected.Height, ParseInt(row, "height"), $"Mapping height changed: {expected.FileName}");
            Assert.AreEqual(expected.Bytes, ParseLong(row, "bytes"), $"Mapping byte count changed: {expected.FileName}");
            Assert.AreEqual(expected.Sha256, row.Groups["hash"].Value.ToUpperInvariant(), $"Mapping hash changed: {expected.FileName}");
            StringAssert.Contains(row.Groups["destination"].Value, expected.DestinationMarker);
            Assert.IsFalse(string.IsNullOrWhiteSpace(row.Groups["surface"].Value), $"Missing implementation surface: {expected.FileName}");
            Assert.IsFalse(string.IsNullOrWhiteSpace(row.Groups["accessibility"].Value), $"Missing accessibility equivalent: {expected.FileName}");
            var expectedEvidence = string.Equals(expected.FileName, "02-live-organization.png", StringComparison.Ordinal)
                ? "Static + Contract + Synthetic candidate"
                : "Static + Contract";
            Assert.AreEqual(expectedEvidence, row.Groups["evidence"].Value.Trim(), $"Unexpected evidence class: {expected.FileName}");
            Assert.AreEqual(
                "Human acceptance: PENDING; candidate only; no accepted capture",
                row.Groups["review"].Value.Trim(),
                $"Human review boundary changed: {expected.FileName}");
        }

        StringAssert.Contains(document, "Human design review: **PENDING**.");
        StringAssert.Contains(document, "Actual Herdr Runtime: **NOT OBSERVED**.");
        StringAssert.Contains(document, "v0.7 runtime, clean-machine, soak, UAT and Release evidence: **NOT OBSERVED**.");
        StringAssert.Contains(document, "No mapping row below claims an accepted implementation capture.");
        Assert.IsFalse(document.Contains("[x]", StringComparison.OrdinalIgnoreCase), "The bounded record must not mark human acceptance complete.");
    }

    [TestMethod]
    public void ShellCatalogAndNamedPageSurfacesRemainOneToOne()
    {
        var repositoryRoot = FindRepositoryRoot();
        var catalog = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Shell", "ShellNavigationCatalog.cs");
        var shell = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Views", "ShellView.xaml");

        var catalogRows = Regex.Matches(
                catalog,
                @"new\(""(?<id>[^""]+)"", ""(?<english>[^""]+)"", ""(?<thai>[^""]+)""",
                RegexOptions.CultureInvariant)
            .Cast<Match>()
            .ToArray();
        Assert.HasCount(ExpectedPages.Length, catalogRows, "The canonical shell catalog must contain exactly ten destinations.");
        CollectionAssert.AreEqual(
            ExpectedPages.Select(page => page.Id).ToArray(),
            catalogRows.Select(row => row.Groups["id"].Value).ToArray(),
            "Shell destination IDs changed or were reordered.");
        Assert.AreEqual(
            catalogRows.Length,
            catalogRows.Select(row => row.Groups["id"].Value).Distinct(StringComparer.Ordinal).Count(),
            "Shell destination IDs must be unique.");

        foreach (var expected in ExpectedPages)
        {
            StringAssert.Contains(catalog, $"new(\"{expected.Id}\", \"{expected.EnglishName}\", \"{expected.ThaiName}\"");
            StringAssert.Contains(shell, $"<views:{expected.XamlType} x:Name=\"{expected.XamlName}\"");
        }

        foreach (var sharedSurface in new[] { "ShellRoot", "NavigationList", "StatusLegend", "LanguageSelector", "FooterConnectionText" })
        {
            StringAssert.Contains(shell, $"x:Name=\"{sharedSurface}\"");
        }
    }

    [TestMethod]
    public void WidgetCatalogAndGalleryExposeAllApprovedConceptsAndAccessibleActions()
    {
        var repositoryRoot = FindRepositoryRoot();
        var widgetCatalog = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Widgets", "WidgetVariant.cs");
        var gallery = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Widgets", "WidgetGalleryView.xaml");
        var galleryCode = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Widgets", "WidgetGalleryView.xaml.cs");
        var surface = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Widgets", "WidgetSurface.xaml");

        var enumBody = Regex.Match(
            widgetCatalog,
            @"public enum WidgetVariant\s*\{(?<body>.*?)\}",
            RegexOptions.Singleline | RegexOptions.CultureInvariant).Groups["body"].Value;
        Assert.IsFalse(string.IsNullOrWhiteSpace(enumBody), "WidgetVariant enum is missing.");
        var enumNames = Regex.Matches(enumBody, @"^\s*(?<name>[A-Za-z][A-Za-z0-9]*),?\s*$", RegexOptions.Multiline | RegexOptions.CultureInvariant)
            .Cast<Match>()
            .Select(match => match.Groups["name"].Value)
            .ToArray();
        CollectionAssert.AreEqual(ExpectedWidgets.Select(widget => widget.EnumName).ToArray(), enumNames, "WidgetVariant cardinality or order changed.");

        var catalogNames = Regex.Matches(widgetCatalog, @"new\(WidgetVariant\.(?<name>[A-Za-z][A-Za-z0-9]*),", RegexOptions.CultureInvariant)
            .Cast<Match>()
            .Select(match => match.Groups["name"].Value)
            .ToArray();
        CollectionAssert.AreEqual(ExpectedWidgets.Select(widget => widget.EnumName).ToArray(), catalogNames, "WidgetCatalog must expose every enum variant exactly once.");

        foreach (var expected in ExpectedWidgets)
        {
            StringAssert.Contains(gallery, $"x:Name=\"{expected.PreviewName}\"");
            StringAssert.Contains(gallery, $"Variant=\"{expected.EnumName}\"");
            StringAssert.Contains(gallery, $"Tag=\"{expected.GalleryTag}\"");
        }

        Assert.HasCount(
            8,
            Regex.Matches(gallery, @"<Run Text=""[1-8]\. """, RegexOptions.CultureInvariant).Cast<Match>(),
            "The widget board must contain eight numbered concepts.");
        StringAssert.Contains(gallery, "x:Name=\"DashboardPreviewHost\"");
        StringAssert.Contains(gallery, "Width=\"1672\" Height=\"941\"");
        StringAssert.Contains(gallery, "Tag=\"Dashboard\"");
        StringAssert.Contains(gallery, "automation:AutomationProperties.Name");
        StringAssert.Contains(galleryCode, "DashboardPreviewHost.Content = ShellView.CreateSyntheticPreview();");
        StringAssert.Contains(galleryCode, "WidgetCatalog.CreateAdaptiveGalleryItems");

        var document = ReadRepositoryFile(repositoryRoot, MappingDocument.Split('/'));
        foreach (var concept in new[]
                 {
                     "Compact Widget",
                     "Normal Widget",
                     "Expanded Widget",
                     "Floating Mini Widget",
                     "Floating Vertical Widget",
                     "Notification Widget",
                     "Agent Detail Popup",
                     "Dashboard launch/preview state",
                 })
        {
            StringAssert.Contains(document, concept);
        }

        foreach (var requiredSurfaceContract in new[]
                 {
                     "StatusBrushKey",
                     "automation:AutomationProperties.Name",
                     "IsKeyboardFocused",
                 })
        {
            StringAssert.Contains(surface, requiredSurfaceContract);
        }
    }

    [TestMethod]
    public void BrandLanguageAndStatusContractsRemainExplicitAndFailClosed()
    {
        var repositoryRoot = FindRepositoryRoot();
        var designContract = ReadRepositoryFile(repositoryRoot, "Plan", "DESIGN-CONTRACT.md");
        var document = ReadRepositoryFile(repositoryRoot, "docs", "design", "implementation", "v0.7-issue-35-design-parity.md");
        var shell = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Views", "ShellView.xaml");
        var gallery = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Widgets", "WidgetGalleryView.xaml");
        var language = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Localization", "UiLanguageService.cs");
        var statusPresentation = ReadRepositoryFile(repositoryRoot, "src", "HerdrOps.App", "Live", "AgentStatusPresentation.cs");

        StringAssert.Contains(designContract, "Preserve the blue circular HerdrOps symbol");
        StringAssert.Contains(designContract, "Preserve the white `HerdrOps` wordmark");
        StringAssert.Contains(shell, "ApprovedOverviewReference.png");
        StringAssert.Contains(shell, "x:Name=\"WideBrandMark\"");
        StringAssert.Contains(shell, "x:Name=\"CompactBrandMark\"");
        Assert.IsFalse(shell.Contains("Text=\"HERDROPS\"", StringComparison.Ordinal), "The shell must not replace the approved wordmark with an uppercase-only literal.");
        Assert.IsFalse(gallery.Contains("Text=\"HERDROPS\"", StringComparison.Ordinal), "The widget board must not introduce an uppercase-only replacement wordmark.");
        StringAssert.Contains(document, "blue circular HerdrOps mark");
        StringAssert.Contains(document, "white `HerdrOps` wordmark");

        var thaiKeys = ExtractCatalogKeys(language, "Thai");
        var englishKeys = ExtractCatalogKeys(language, "English");
        Assert.IsNotEmpty(thaiKeys, "Thai catalog is missing.");
        Assert.IsNotEmpty(englishKeys, "English catalog is missing.");
        Assert.IsTrue(thaiKeys.SetEquals(englishKeys), "Thai and English catalogs must expose the same complete key set.");
        StringAssert.Contains(shell, "UiLanguageService.Shared");
        StringAssert.Contains(gallery, "UiLanguageService.Shared");

        foreach (var expected in ExpectedStatuses)
        {
            StringAssert.Contains(designContract, $"| {expected.DesignName} | {expected.Color} |");
            StringAssert.Contains(language, $"[\"{expected.Key}\"]");
            StringAssert.Contains(statusPresentation, $"\"{expected.Name}\"");
            StringAssert.Contains(gallery, $"[{expected.Key}]");
        }

        StringAssert.Contains(language, "[\"StatusUnknown\"]");
        StringAssert.Contains(statusPresentation, "_ => text[\"StatusUnknown\"]");
        StringAssert.Contains(designContract, "Severity and workflow state are separate concepts.");
        StringAssert.Contains(statusPresentation, "\"Review\" => text[\"StatusReview\"]");
        StringAssert.Contains(statusPresentation, "\"Review\" => \"HerdrOps.Brush.Status.Review\"");
        StringAssert.Contains(shell, "StatusDone");
        StringAssert.Contains(document, "Severity and review workflow are separate concepts");
    }

    private static HashSet<string> ExtractCatalogKeys(string source, string catalogName)
    {
        var match = Regex.Match(
            source,
            $@"private static readonly IReadOnlyDictionary<string, string> {catalogName}\s*=\s*new Dictionary<string, string>\([^)]*\)\s*\{{(?<body>.*?)\n\s*\}};",
            RegexOptions.Singleline | RegexOptions.CultureInvariant);
        Assert.IsTrue(match.Success, $"Could not locate {catalogName} language catalog.");
        return Regex.Matches(match.Groups["body"].Value, @"\[""(?<key>[^""]+)""\]\s*=", RegexOptions.CultureInvariant)
            .Cast<Match>()
            .Select(item => item.Groups["key"].Value)
            .ToHashSet(StringComparer.Ordinal);
    }

    private static (int Width, int Height) ReadPngDimensions(byte[] bytes, string fileName)
    {
        var signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
        Assert.IsGreaterThanOrEqualTo(24, bytes.Length, $"Reference is too short to be a PNG: {fileName}");
        CollectionAssert.AreEqual(signature, bytes[..8], $"Reference is not a PNG: {fileName}");
        Assert.AreEqual("IHDR", Encoding.ASCII.GetString(bytes, 12, 4), $"PNG IHDR is missing: {fileName}");
        return (
            checked((int)ReadBigEndianUInt32(bytes, 16)),
            checked((int)ReadBigEndianUInt32(bytes, 20)));
    }

    private static uint ReadBigEndianUInt32(byte[] bytes, int offset) =>
        ((uint)bytes[offset] << 24) |
        ((uint)bytes[offset + 1] << 16) |
        ((uint)bytes[offset + 2] << 8) |
        bytes[offset + 3];

    private static int ParseInt(Match row, string groupName) =>
        int.Parse(row.Groups[groupName].Value, NumberStyles.None, CultureInfo.InvariantCulture);

    private static long ParseLong(Match row, string groupName) =>
        long.Parse(row.Groups[groupName].Value.Replace(",", string.Empty, StringComparison.Ordinal), NumberStyles.None, CultureInfo.InvariantCulture);

    private static void AssertTrackedByGit(string repositoryRoot, string relativePath)
    {
        var normalizedPath = relativePath.Replace(Path.DirectorySeparatorChar, '/');
        var startInfo = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = repositoryRoot,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("ls-files");
        startInfo.ArgumentList.Add("--cached");
        startInfo.ArgumentList.Add("--error-unmatch");
        startInfo.ArgumentList.Add("--");
        startInfo.ArgumentList.Add(normalizedPath);

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            Assert.Fail("Could not start Git to verify immutable reference tracking.");
            return;
        }

        var output = process.StandardOutput.ReadToEnd().Trim();
        var error = process.StandardError.ReadToEnd().Trim();
        process.WaitForExit();
        Assert.AreEqual(0, process.ExitCode, $"Immutable reference is not tracked by Git: {normalizedPath}. {error}");
        Assert.AreEqual(normalizedPath, output, $"Git tracked an unexpected path for immutable reference: {normalizedPath}");
    }

    private static string ReadRepositoryFile(string repositoryRoot, params string[] segments)
    {
        var path = segments.Aggregate(repositoryRoot, Path.Combine);
        Assert.IsTrue(File.Exists(path), $"Required contract file is missing: {path}");
        return File.ReadAllText(path);
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "HerdrOps.sln")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        Assert.Fail("Could not locate HerdrOps.sln from the contract test output directory.");
        return string.Empty;
    }

    private sealed record ReferenceEntry(string FileName, int Width, int Height, long Bytes, string Sha256, string DestinationMarker);

    private sealed record PageEntry(string Id, string EnglishName, string ThaiName, string XamlType, string XamlName);

    private sealed record WidgetEntry(string EnumName, string PreviewName, string GalleryTag);

    private sealed record StatusEntry(string Name, string DesignName, string Color, string Key);
}
