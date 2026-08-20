# HerdrOps v0.7 Performance Budget Policy Module
# Issue #39: Non-Runtime Preparation for Performance Budgets and 8-Hour Soak Contract

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Plan-Derived Non-Functional Target Constants (Plan/RELEASE-GATES.md, Issue #39)
# -----------------------------------------------------------------------------
$script:V07PlanBudgets = [ordered]@{
    # Metric 1: Core + App idle CPU (<= 1% average on reference host)
    MaxIdleCpuAveragePercent          = 1.0

    # Metric 2: Core + App idle working set (<= 180 MB combined = 188,743,680 bytes)
    MaxIdleWorkingSetCombinedBytes    = [long](180 * 1024 * 1024)

    # Metric 3: Widget state-delta latency (p95 <= 250 ms after Core receives event)
    MaxWidgetStateDeltaLatencyP95Ms   = 250.0

    # Metric 4: Dashboard cold launch (p95 <= 2.0 s = 2000 ms on reference host)
    MaxDashboardColdLaunchP95Ms       = 2000.0

    # Metric 5: Herdr reconnect and reconcile (<= 5 s after endpoint becomes available)
    MaxHerdrReconnectReconcileSeconds = 5.0

    # Metric 6: Unbounded terminal reads (0)
    MaxUnboundedTerminalReads         = 0

    # Metric 7: Unhandled crash during v0.7 soak (0 in 8 hours)
    MaxUnhandledCrashesDuringSoak     = 0
    MinSoakDurationHours              = 8.0
    MinSoakDurationSeconds            = [double](8.0 * 3600.0)

    # Metric 8: Normal-mode Administrator requirement (None / false)
    AdministratorRequired             = $false
}

$script:MaxJsonReportBytes = 4 * 1024 * 1024 # 4 MiB max for reports

# -----------------------------------------------------------------------------
# C# High-Performance Strict JSON Validator, Schema Checker, and P95 Engine
# Built with C# 5 / .NET Framework 4.x and .NET Core / PS 5.1 / PS 7+ compatibility
# Zero external assembly dependencies (no System.Text.Json required)
# -----------------------------------------------------------------------------
if (-not ('HerdrOps.BudgetValidation.StrictJsonValidator' -as [type])) {
    $strictValidatorCode = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace HerdrOps.BudgetValidation
{
    public static class StrictJsonValidator
    {
        public static object ParseStrict(string json, string sourceDescription)
        {
            if (string.IsNullOrEmpty(json) || json.Trim().Length == 0)
            {
                throw new ArgumentException(string.Format("{0} is empty or whitespace.", sourceDescription));
            }
            int pos = 0;
            object val = ParseValue(json, ref pos, json.Length, 0, sourceDescription);
            SkipWhitespace(json, ref pos, json.Length);
            if (pos < json.Length)
            {
                throw new InvalidOperationException(string.Format("Strict JSON violation: Trailing content after root JSON value in {0} at character index {1}.", sourceDescription, pos));
            }
            return val;
        }

        public static void CheckStrictStructureAndDuplicates(string json, string sourceDescription)
        {
            ParseStrict(json, sourceDescription);
        }

        public static void ValidateSchemaDocument(string json, string sourceDescription)
        {
            object parsed = ParseStrict(json, sourceDescription);
            Dictionary<string, object> root = parsed as Dictionary<string, object>;
            if (root == null)
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: Root must be an object in {0}.", sourceDescription));
            }

            HashSet<string> allowedTopLevel = new HashSet<string>(StringComparer.Ordinal)
            {
                "SchemaVersion", "RunId", "TimestampUtc", "EvidenceClass", "HostEnvironment",
                "Candidate", "Metrics", "Waivers", "EvidenceBoundary", "ProcessTelemetry", "Reconciliation"
            };

            foreach (KeyValuePair<string, object> kvp in root)
            {
                if (!allowedTopLevel.Contains(kvp.Key))
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown top-level property '{0}' in {1}.", kvp.Key, sourceDescription));
                }
            }

            string[] requiredTop = new string[] { "SchemaVersion", "RunId", "TimestampUtc", "Candidate", "Metrics", "EvidenceBoundary" };
            foreach (string req in requiredTop)
            {
                if (!root.ContainsKey(req) || root[req] == null)
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Missing required top-level property '{0}' in {1}.", req, sourceDescription));
                }
            }

            string schemaVersion = root["SchemaVersion"] as string;
            if (schemaVersion != "v0.7.0")
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: SchemaVersion must be exactly 'v0.7.0'; found '{0}' in {1}.", schemaVersion, sourceDescription));
            }

            string timestamp = root["TimestampUtc"] as string;
            if (timestamp == null || !Regex.IsMatch(timestamp, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"))
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: TimestampUtc must be a valid ISO 8601 UTC timestamp ending in 'Z'; found '{0}' in {1}.", timestamp, sourceDescription));
            }

            Dictionary<string, object> candidate = root["Candidate"] as Dictionary<string, object>;
            if (candidate == null)
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: Candidate must be an object in {0}.", sourceDescription));
            }
            HashSet<string> allowedCandProps = new HashSet<string>(StringComparer.Ordinal) { "SourceCommit", "GitTreeClean", "Binaries" };
            foreach (KeyValuePair<string, object> cp in candidate)
            {
                if (!allowedCandProps.Contains(cp.Key))
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown property '{0}' in Candidate in {1}.", cp.Key, sourceDescription));
                }
            }
            string sourceCommit = candidate.ContainsKey("SourceCommit") ? (candidate["SourceCommit"] as string) : null;
            if (sourceCommit == null || !Regex.IsMatch(sourceCommit, @"^[0-9a-f]{40}$"))
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: Candidate.SourceCommit must be a 40-hex lowercase string in {0}.", sourceDescription));
            }

            if (candidate.ContainsKey("Binaries") && candidate["Binaries"] != null)
            {
                List<object> binaries = candidate["Binaries"] as List<object>;
                if (binaries == null)
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Candidate.Binaries must be an array in {0}.", sourceDescription));
                }
                HashSet<string> allowedBinProps = new HashSet<string>(StringComparer.Ordinal) { "RelativePath", "LengthBytes", "Sha256" };
                foreach (object binObj in binaries)
                {
                    Dictionary<string, object> bin = binObj as Dictionary<string, object>;
                    if (bin == null)
                    {
                        throw new InvalidOperationException(string.Format("Strict schema violation: Binary item must be an object in {0}.", sourceDescription));
                    }
                    foreach (KeyValuePair<string, object> bp in bin)
                    {
                        if (!allowedBinProps.Contains(bp.Key))
                        {
                            throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown property '{0}' in Binary in {1}.", bp.Key, sourceDescription));
                        }
                    }
                    string[] reqBin = new string[] { "RelativePath", "LengthBytes", "Sha256" };
                    foreach (string rb in reqBin)
                    {
                        if (!bin.ContainsKey(rb) || bin[rb] == null)
                        {
                            throw new InvalidOperationException(string.Format("Strict schema violation: Missing required binary property '{0}' in {1}.", rb, sourceDescription));
                        }
                    }
                    string sha = bin["Sha256"] as string;
                    if (sha == null || !Regex.IsMatch(sha, @"^[0-9a-f]{64}$"))
                    {
                        throw new InvalidOperationException(string.Format("Strict schema violation: Binary Sha256 must be a 64-hex lowercase string in {0}.", sourceDescription));
                    }
                    long length = Convert.ToInt64(bin["LengthBytes"], CultureInfo.InvariantCulture);
                    if (length < 0)
                    {
                        throw new InvalidOperationException(string.Format("Strict schema violation: Binary LengthBytes must be >= 0 in {0}.", sourceDescription));
                    }
                }
            }

            Dictionary<string, object> metrics = root["Metrics"] as Dictionary<string, object>;
            if (metrics == null)
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: Metrics must be an object in {0}.", sourceDescription));
            }
            HashSet<string> allowedMetricsProps = new HashSet<string>(StringComparer.Ordinal)
            {
                "IdleCpuAveragePercent", "IdleWorkingSetCombinedBytes",
                "WidgetStateDeltaLatencyP95Ms", "WidgetDeltaLatencySamplesMs",
                "DashboardColdLaunchP95Ms", "DashboardColdLaunchSamplesMs",
                "HerdrReconnectReconcileSeconds", "UnboundedTerminalReads",
                "UnhandledCrashesDuringSoak", "SoakDurationHours",
                "UnreconciledStateCount", "UnhandledFaultCount", "AdministratorRequired"
            };
            foreach (KeyValuePair<string, object> mp in metrics)
            {
                if (!allowedMetricsProps.Contains(mp.Key))
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown property '{0}' in Metrics in {1}.", mp.Key, sourceDescription));
                }
            }

            string[] reqMetrics = new string[]
            {
                "IdleCpuAveragePercent", "IdleWorkingSetCombinedBytes",
                "WidgetStateDeltaLatencyP95Ms", "DashboardColdLaunchP95Ms",
                "HerdrReconnectReconcileSeconds", "UnboundedTerminalReads",
                "UnhandledCrashesDuringSoak", "AdministratorRequired"
            };
            foreach (string rm in reqMetrics)
            {
                if (!metrics.ContainsKey(rm) || metrics[rm] == null)
                {
                    throw new InvalidOperationException(string.Format("Strict schema violation: Missing required metric '{0}' in {1}.", rm, sourceDescription));
                }
            }

            double cpu = Convert.ToDouble(metrics["IdleCpuAveragePercent"], CultureInfo.InvariantCulture);
            if (cpu < 0.0 || cpu > 100.0) throw new InvalidOperationException(string.Format("Strict schema violation: IdleCpuAveragePercent must be 0.0-100.0; found {0} in {1}.", cpu, sourceDescription));

            long ws = Convert.ToInt64(metrics["IdleWorkingSetCombinedBytes"], CultureInfo.InvariantCulture);
            if (ws < 0) throw new InvalidOperationException(string.Format("Strict schema violation: IdleWorkingSetCombinedBytes must be >= 0; found {0} in {1}.", ws, sourceDescription));

            double lat = Convert.ToDouble(metrics["WidgetStateDeltaLatencyP95Ms"], CultureInfo.InvariantCulture);
            if (lat < 0.0) throw new InvalidOperationException(string.Format("Strict schema violation: WidgetStateDeltaLatencyP95Ms must be >= 0; found {0} in {1}.", lat, sourceDescription));

            double launch = Convert.ToDouble(metrics["DashboardColdLaunchP95Ms"], CultureInfo.InvariantCulture);
            if (launch < 0.0) throw new InvalidOperationException(string.Format("Strict schema violation: DashboardColdLaunchP95Ms must be >= 0; found {0} in {1}.", launch, sourceDescription));

            double rec = Convert.ToDouble(metrics["HerdrReconnectReconcileSeconds"], CultureInfo.InvariantCulture);
            if (rec < 0.0) throw new InvalidOperationException(string.Format("Strict schema violation: HerdrReconnectReconcileSeconds must be >= 0; found {0} in {1}.", rec, sourceDescription));

            long term = Convert.ToInt64(metrics["UnboundedTerminalReads"], CultureInfo.InvariantCulture);
            if (term < 0) throw new InvalidOperationException(string.Format("Strict schema violation: UnboundedTerminalReads must be >= 0; found {0} in {1}.", term, sourceDescription));

            long crash = Convert.ToInt64(metrics["UnhandledCrashesDuringSoak"], CultureInfo.InvariantCulture);
            if (crash < 0) throw new InvalidOperationException(string.Format("Strict schema violation: UnhandledCrashesDuringSoak must be >= 0; found {0} in {1}.", crash, sourceDescription));

            object adminObj = metrics["AdministratorRequired"];
            if (!(adminObj is bool))
            {
                throw new InvalidOperationException(string.Format("Strict schema violation: AdministratorRequired must be a boolean in {0}.", sourceDescription));
            }

            if (metrics.ContainsKey("SoakDurationHours") && metrics["SoakDurationHours"] != null)
            {
                double soak = Convert.ToDouble(metrics["SoakDurationHours"], CultureInfo.InvariantCulture);
                if (soak < 0.0) throw new InvalidOperationException(string.Format("Strict schema violation: SoakDurationHours must be >= 0; found {0} in {1}.", soak, sourceDescription));
            }

            if (metrics.ContainsKey("UnreconciledStateCount") && metrics["UnreconciledStateCount"] != null)
            {
                long unrec = Convert.ToInt64(metrics["UnreconciledStateCount"], CultureInfo.InvariantCulture);
                if (unrec < 0) throw new InvalidOperationException(string.Format("Strict schema violation: UnreconciledStateCount must be >= 0; found {0} in {1}.", unrec, sourceDescription));
            }

            if (metrics.ContainsKey("UnhandledFaultCount") && metrics["UnhandledFaultCount"] != null)
            {
                long fault = Convert.ToInt64(metrics["UnhandledFaultCount"], CultureInfo.InvariantCulture);
                if (fault < 0) throw new InvalidOperationException(string.Format("Strict schema violation: UnhandledFaultCount must be >= 0; found {0} in {1}.", fault, sourceDescription));
            }

            if (root.ContainsKey("Waivers") && root["Waivers"] != null)
            {
                List<object> waivers = root["Waivers"] as List<object>;
                if (waivers == null) throw new InvalidOperationException(string.Format("Strict schema violation: Waivers must be an array in {0}.", sourceDescription));
                HashSet<string> allowedWProps = new HashSet<string>(StringComparer.Ordinal) { "Metric", "Target", "Observed", "Cause", "Impact", "ApprovedBy", "ApprovalDateUtc", "WaiverSha256" };
                foreach (object wObj in waivers)
                {
                    Dictionary<string, object> w = wObj as Dictionary<string, object>;
                    if (w == null) throw new InvalidOperationException(string.Format("Strict schema violation: Waiver element must be an object in {0}.", sourceDescription));
                    foreach (KeyValuePair<string, object> wp in w)
                    {
                        if (!allowedWProps.Contains(wp.Key)) throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown property '{0}' in Waiver in {1}.", wp.Key, sourceDescription));
                    }
                    string[] reqW = new string[] { "Metric", "Target", "Observed", "Cause", "Impact", "ApprovedBy", "ApprovalDateUtc", "WaiverSha256" };
                    foreach (string rw in reqW)
                    {
                        string val = w.ContainsKey(rw) ? (w[rw] as string) : null;
                        if (string.IsNullOrEmpty(val) || val.Trim().Length == 0)
                        {
                            throw new InvalidOperationException(string.Format("Strict schema violation: Missing or empty required waiver property '{0}' in {1}.", rw, sourceDescription));
                        }
                    }
                    string wSha = w["WaiverSha256"] as string;
                    if (wSha == null || !Regex.IsMatch(wSha, @"^[0-9a-f]{64}$"))
                    {
                        throw new InvalidOperationException(string.Format("Strict schema violation: WaiverSha256 must be 64-hex lowercase in {0}.", sourceDescription));
                    }
                }
            }

            Dictionary<string, object> ev = root["EvidenceBoundary"] as Dictionary<string, object>;
            if (ev == null) throw new InvalidOperationException(string.Format("Strict schema violation: EvidenceBoundary must be an object in {0}.", sourceDescription));
            HashSet<string> allowedEv = new HashSet<string>(StringComparer.Ordinal) { "StaticEvidence", "SyntheticEvidence", "ContractEvidence", "ActualHerdrRuntime", "SoakExecution", "HumanUatDecision", "ReleaseEvidence" };
            foreach (KeyValuePair<string, object> ep in ev)
            {
                if (!allowedEv.Contains(ep.Key)) throw new InvalidOperationException(string.Format("Strict schema violation: Disallowed unknown property '{0}' in EvidenceBoundary in {1}.", ep.Key, sourceDescription));
            }
        }

        public static double CalculateP95(double[] samples)
        {
            if (samples == null || samples.Length == 0) return 0.0;
            double[] sorted = (double[])samples.Clone();
            Array.Sort(sorted);
            int index = (int)Math.Ceiling(0.95 * sorted.Length) - 1;
            if (index < 0) index = 0;
            if (index >= sorted.Length) index = sorted.Length - 1;
            return sorted[index];
        }

        private static void SkipWhitespace(string json, ref int pos, int length)
        {
            while (pos < length)
            {
                char c = json[pos];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') pos++;
                else break;
            }
        }

        private static object ParseValue(string json, ref int pos, int length, int depth, string source)
        {
            if (depth > 32) throw new InvalidOperationException(string.Format("Strict JSON violation: Exceeded maximum nesting depth of 32 in {0}.", source));
            SkipWhitespace(json, ref pos, length);
            if (pos >= length) throw new InvalidOperationException(string.Format("Strict JSON violation: Unexpected end of input in {0}.", source));
            char c = json[pos];
            if (c == '{') return ParseObject(json, ref pos, length, depth + 1, source);
            if (c == '[') return ParseArray(json, ref pos, length, depth + 1, source);
            if (c == '"') return ParseString(json, ref pos, length, source);
            if (c == 't' || c == 'f') return ParseBoolean(json, ref pos, length, source);
            if (c == 'n') return ParseNull(json, ref pos, length, source);
            if (c == '-' || (c >= '0' && c <= '9')) return ParseNumber(json, ref pos, length, source);
            throw new InvalidOperationException(string.Format("Strict JSON violation: Unexpected character '{0}' in {1} at position {2}.", c, source, pos));
        }

        private static Dictionary<string, object> ParseObject(string json, ref int pos, int length, int depth, string source)
        {
            pos++; // consume '{'
            Dictionary<string, object> dict = new Dictionary<string, object>(StringComparer.Ordinal);
            SkipWhitespace(json, ref pos, length);
            if (pos < length && json[pos] == '}')
            {
                pos++;
                return dict;
            }
            while (pos < length)
            {
                SkipWhitespace(json, ref pos, length);
                if (pos >= length || json[pos] != '"')
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Expected quoted property name in object in {0} at position {1}.", source, pos));
                }
                string key = ParseString(json, ref pos, length, source);
                if (dict.ContainsKey(key))
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Duplicate property '{0}' detected in {1}.", key, source));
                }
                SkipWhitespace(json, ref pos, length);
                if (pos >= length || json[pos] != ':')
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Expected ':' after property name '{0}' in {1} at position {2}.", key, source, pos));
                }
                pos++; // consume ':'
                object val = ParseValue(json, ref pos, length, depth, source);
                dict.Add(key, val);
                SkipWhitespace(json, ref pos, length);
                if (pos >= length) throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated object in {0}.", source));
                if (json[pos] == ',')
                {
                    pos++;
                    SkipWhitespace(json, ref pos, length);
                    if (pos < length && json[pos] == '}')
                    {
                        throw new InvalidOperationException(string.Format("Strict JSON violation: Trailing comma in object in {0} at position {1}.", source, pos));
                    }
                }
                else if (json[pos] == '}')
                {
                    pos++;
                    return dict;
                }
                else
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Expected ',' or '}' in object in {0} at position {1}.", source, pos));
                }
            }
            throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated object in {0}.", source));
        }

        private static List<object> ParseArray(string json, ref int pos, int length, int depth, string source)
        {
            pos++; // consume '['
            List<object> list = new List<object>();
            SkipWhitespace(json, ref pos, length);
            if (pos < length && json[pos] == ']')
            {
                pos++;
                return list;
            }
            while (pos < length)
            {
                object val = ParseValue(json, ref pos, length, depth, source);
                list.Add(val);
                SkipWhitespace(json, ref pos, length);
                if (pos >= length) throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated array in {0}.", source));
                if (json[pos] == ',')
                {
                    pos++;
                    SkipWhitespace(json, ref pos, length);
                    if (pos < length && json[pos] == ']')
                    {
                        throw new InvalidOperationException(string.Format("Strict JSON violation: Trailing comma in array in {0} at position {1}.", source, pos));
                    }
                }
                else if (json[pos] == ']')
                {
                    pos++;
                    return list;
                }
                else
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Expected ',' or ']' in array in {0} at position {1}.", source, pos));
                }
            }
            throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated array in {0}.", source));
        }

        private static string ParseString(string json, ref int pos, int length, string source)
        {
            pos++; // consume opening '"'
            StringBuilder sb = new StringBuilder();
            while (pos < length)
            {
                char c = json[pos++];
                if (c == '"') return sb.ToString();
                if (c == '\\')
                {
                    if (pos >= length) throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated escape sequence in {0}.", source));
                    char esc = json[pos++];
                    switch (esc)
                    {
                        case '"': sb.Append('"'); break;
                        case '\\': sb.Append('\\'); break;
                        case '/': sb.Append('/'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'u':
                            if (pos + 4 > length) throw new InvalidOperationException(string.Format("Strict JSON violation: Incomplete unicode escape in {0}.", source));
                            string hex = json.Substring(pos, 4);
                            pos += 4;
                            int codePoint;
                            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out codePoint))
                            {
                                throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid unicode escape '\\u{0}' in {1}.", hex, source));
                            }
                            sb.Append((char)codePoint);
                            break;
                        default:
                            throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid escape character '\\{0}' in {1}.", esc, source));
                    }
                }
                else if (c < 0x20)
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Unescaped control character (0x{0:X2}) in string in {1}.", (int)c, source));
                }
                else
                {
                    sb.Append(c);
                }
            }
            throw new InvalidOperationException(string.Format("Strict JSON violation: Unterminated string in {0}.", source));
        }

        private static bool ParseBoolean(string json, ref int pos, int length, string source)
        {
            if (pos + 4 <= length && json.Substring(pos, 4) == "true")
            {
                pos += 4;
                return true;
            }
            if (pos + 5 <= length && json.Substring(pos, 5) == "false")
            {
                pos += 5;
                return false;
            }
            throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid boolean literal in {0} at position {1}.", source, pos));
        }

        private static object ParseNull(string json, ref int pos, int length, string source)
        {
            if (pos + 4 <= length && json.Substring(pos, 4) == "null")
            {
                pos += 4;
                return null;
            }
            throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid null literal in {0} at position {1}.", source, pos));
        }

        private static object ParseNumber(string json, ref int pos, int length, string source)
        {
            int start = pos;
            if (json[pos] == '-') pos++;
            if (pos >= length) throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid number in {0} at position {1}.", source, start));
            if (json[pos] == '0')
            {
                pos++;
            }
            else if (json[pos] >= '1' && json[pos] <= '9')
            {
                while (pos < length && json[pos] >= '0' && json[pos] <= '9') pos++;
            }
            else
            {
                throw new InvalidOperationException(string.Format("Strict JSON violation: Invalid number in {0} at position {1}.", source, start));
            }

            bool isFloating = false;
            if (pos < length && json[pos] == '.')
            {
                isFloating = true;
                pos++;
                int fracStart = pos;
                while (pos < length && json[pos] >= '0' && json[pos] <= '9') pos++;
                if (pos == fracStart) throw new InvalidOperationException(string.Format("Strict JSON violation: Number missing fractional digits in {0} at position {1}.", source, start));
            }

            if (pos < length && (json[pos] == 'e' || json[pos] == 'E'))
            {
                isFloating = true;
                pos++;
                if (pos < length && (json[pos] == '+' || json[pos] == '-')) pos++;
                int expStart = pos;
                while (pos < length && json[pos] >= '0' && json[pos] <= '9') pos++;
                if (pos == expStart) throw new InvalidOperationException(string.Format("Strict JSON violation: Number missing exponent digits in {0} at position {1}.", source, start));
            }

            string numText = json.Substring(start, pos - start);
            if (numText.IndexOf("nan", StringComparison.OrdinalIgnoreCase) >= 0 ||
                numText.IndexOf("infinity", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                throw new InvalidOperationException(string.Format("Strict JSON violation: Disallowed numeric value '{0}' in {1}.", numText, source));
            }

            if (isFloating)
            {
                double dVal;
                if (!double.TryParse(numText, NumberStyles.Float, CultureInfo.InvariantCulture, out dVal))
                {
                    throw new InvalidOperationException(string.Format("Strict JSON violation: Cannot parse floating number '{0}' in {1}.", numText, source));
                }
                return dVal;
            }
            else
            {
                long lVal;
                if (!long.TryParse(numText, NumberStyles.Integer, CultureInfo.InvariantCulture, out lVal))
                {
                    double dVal;
                    if (!double.TryParse(numText, NumberStyles.Float, CultureInfo.InvariantCulture, out dVal))
                    {
                        throw new InvalidOperationException(string.Format("Strict JSON violation: Cannot parse integer '{0}' in {1}.", numText, source));
                    }
                    return dVal;
                }
                return lVal;
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $strictValidatorCode
}

# -----------------------------------------------------------------------------
# Cryptographic & Hash Functions
# -----------------------------------------------------------------------------
function Get-Sha256DigestHex {
    [CmdletBinding(DefaultParameterSetName = 'Bytes')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Bytes', Position = 0)]
        [byte[]]$Bytes,

        [Parameter(Mandatory, ParameterSetName = 'Text', Position = 0)]
        [string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]$Path
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Text') {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $hashBytes = $sha256.ComputeHash($utf8.GetBytes($Text))
        } elseif ($PSCmdlet.ParameterSetName -eq 'Path') {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "File not found for SHA-256 calculation: $Path"
            }
            $fileStream = [System.IO.File]::OpenRead($Path)
            try {
                $hashBytes = $sha256.ComputeHash($fileStream)
            } finally {
                $fileStream.Dispose()
            }
        } else {
            $hashBytes = $sha256.ComputeHash($Bytes)
        }

        $builder = New-Object System.Text.StringBuilder ($hashBytes.Length * 2)
        foreach ($b in $hashBytes) {
            [void]$builder.Append($b.ToString('x2', [Globalization.CultureInfo]::InvariantCulture))
        }
        return $builder.ToString()
    } finally {
        $sha256.Dispose()
    }
}

function ConvertTo-NormalizedSha256Hex {
    param([Parameter(Mandatory)][string]$Value)

    $trimmed = $Value.Trim().ToLowerInvariant()
    if ($trimmed -notmatch '^[0-9a-f]{64}$') {
        throw "SHA-256 digest must be exactly 64 lowercase hexadecimal characters; received '$Value'"
    }
    return $trimmed
}

# -----------------------------------------------------------------------------
# Path Safety, Traversal, and Reparse Point Protections
# -----------------------------------------------------------------------------
function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$AllowedRoots,
        [string]$Description = 'Path'
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Description cannot be null or whitespace."
    }

    if ($Path.Contains('..')) {
        throw "$Description contains disallowed relative traversal segment ('..'): $Path"
    }

    $separatorChars = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $normalizedPath = [IO.Path]::GetFullPath($Path)

    $isAllowed = $false
    foreach ($root in $AllowedRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $normalizedRoot = [IO.Path]::GetFullPath($root).TrimEnd($separatorChars)
        $rootPrefix = $normalizedRoot + [IO.Path]::DirectorySeparatorChar

        if ($normalizedPath.Equals($normalizedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            $normalizedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $isAllowed = $true
            break
        }
    }

    if (-not $isAllowed) {
        $rootsText = ($AllowedRoots | ForEach-Object { [IO.Path]::GetFullPath($_) }) -join '; '
        throw "$Description '$normalizedPath' resolves outside allowed roots ($rootsText)."
    }

    return $normalizedPath
}

function Assert-NotReparsePoint {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = 'Path'
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description is a reparse point (symlink/junction/mount) which is disallowed for security: $Path"
        }
    }
}

function Get-BoundedUtf8FileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaxBytes = $script:MaxJsonReportBytes,
        [string]$Description = 'File'
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description does not exist: $Path"
    }

    Assert-NotReparsePoint -Path $Path -Description $Description

    $fileInfo = New-Object System.IO.FileInfo($Path)
    if ($fileInfo.Length -gt $MaxBytes) {
        throw "$Description exceeds maximum allowed size ($($fileInfo.Length) bytes > $MaxBytes bytes): $Path"
    }
    if ($fileInfo.Length -eq 0) {
        throw "$Description is unexpectedly empty (0 bytes): $Path"
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        return $utf8NoBom.GetString($bytes)
    } catch {
        throw "$Description is not valid UTF-8 text: $Path ($($_.Exception.Message))"
    }
}

# -----------------------------------------------------------------------------
# Clean Repository Verification
# -----------------------------------------------------------------------------
function Test-CleanRepositoryState {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [switch]$SkipCleanCheck
    )

    $resolvedRoot = [IO.Path]::GetFullPath($RepositoryRoot)
    Assert-NotReparsePoint -Path $resolvedRoot -Description 'Repository root'

    $sourceCommitOutput = @(& git -C $resolvedRoot rev-parse --verify 'HEAD^{commit}' 2>&1)
    $sourceCommit = ($sourceCommitOutput -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceCommit -notmatch '^[0-9a-f]{40}$') {
        throw "Could not resolve source commit at $resolvedRoot (exit code $LASTEXITCODE): $sourceCommit"
    }

    $pending = @(& git -C $resolvedRoot status --porcelain=v1 --untracked-files=all 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect git status at $resolvedRoot (exit code $LASTEXITCODE)."
    }
    if ($pending.Count -ne 0 -and -not $SkipCleanCheck) {
        throw "Repository working tree is not clean at $resolvedRoot. Pending items: $($pending -join '; ')"
    }

    return $sourceCommit.ToLowerInvariant()
}

# -----------------------------------------------------------------------------
# Strict JSON Parser & Schema Validator (PS 5.1 & PS 7+ Compatible)
# -----------------------------------------------------------------------------
function ConvertFrom-StrictPerformanceBudgetJson {
    param(
        [Parameter(Mandatory)][string]$JsonText,
        [string]$SourceDescription = 'JSON input'
    )

    [HerdrOps.BudgetValidation.StrictJsonValidator]::ValidateSchemaDocument($JsonText, $SourceDescription)
    return ($JsonText | ConvertFrom-Json)
}

# -----------------------------------------------------------------------------
# Waiver Cryptographic Binding Helper & No-Native-Trim Enforcement
# -----------------------------------------------------------------------------
function Get-WaiverCanonicalSha256 {
    param([Parameter(Mandatory)]$Waiver)

    $dateStr = if ($Waiver.ApprovalDateUtc -is [DateTime]) {
        $Waiver.ApprovalDateUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    } else {
        [string]$Waiver.ApprovalDateUtc
    }

    $canonicalText = "$($Waiver.Metric):$($Waiver.Target):$($Waiver.Observed):$($Waiver.Cause):$($Waiver.Impact):$($Waiver.ApprovedBy):$dateStr"
    return Get-Sha256DigestHex -Text $canonicalText
}

function Test-WaiverIntegrity {
    param(
        [Parameter(Mandatory)]$Waiver,
        [Parameter(Mandatory)][string]$ExpectedMetric
    )

    if ($Waiver.Metric -ne $ExpectedMetric) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "Waiver target metric '$($Waiver.Metric)' does not match expected metric '$ExpectedMetric'."
        }
    }

    # Strict "No Native Trim" waiver check (DECISIONS.md D-011 / docs/protocol/v0.2-runtime-monitor-contract.md)
    $disallowedTrimPattern = '(?i)(native.*trim|working[- ]?set.*trim|SetProcessWorkingSetSize|EmptyWorkingSet|force.*trim)'
    if ($Waiver.Cause -match $disallowedTrimPattern -or $Waiver.Impact -match $disallowedTrimPattern) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "Disallowed waiver reason: Plan/DECISIONS.md D-011 forbids native working-set trim waivers."
        }
    }

    $computedSha = Get-WaiverCanonicalSha256 -Waiver $Waiver
    $declaredSha = ($Waiver.WaiverSha256).ToLowerInvariant()
    if ($computedSha -ne $declaredSha) {
        return [pscustomobject]@{
            IsValid = $false
            Reason  = "Waiver SHA-256 mismatch (declared: $declaredSha, computed: $computedSha)."
        }
    }

    return [pscustomobject]@{
        IsValid = $true
        Reason  = "Valid waiver approved by $($Waiver.ApprovedBy) on $($Waiver.ApprovalDateUtc)."
    }
}

# -----------------------------------------------------------------------------
# Performance Budget Evaluation Engine
# -----------------------------------------------------------------------------
function Test-PerformanceBudgetReport {
    param(
        [Parameter(Mandatory)]$ReportObject,
        [string]$CandidateDirectory = '',
        [string]$RepositoryRoot = ''
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $waiversApplied = [System.Collections.Generic.List[object]]::new()
    $allPassed = $true

    $metrics = $ReportObject.Metrics
    $waiversList = if ($null -ne $ReportObject.PSObject.Properties['Waivers'] -and $null -ne $ReportObject.Waivers) { @($ReportObject.Waivers) } else { @() }

    $findWaiverForMetric = {
        param([string]$MetricName)
        foreach ($w in $waiversList) {
            if ($w.Metric -eq $MetricName) {
                return $w
            }
        }
        return $null
    }

    # 1. Core + App idle CPU (<= 1.0%)
    $cpuObs = [double]$metrics.IdleCpuAveragePercent
    $cpuTarget = "<= $($script:V07PlanBudgets.MaxIdleCpuAveragePercent)%"
    if ($cpuObs -le $script:V07PlanBudgets.MaxIdleCpuAveragePercent) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-01-CPU'
            Metric        = 'Core + App idle CPU'
            Target        = $cpuTarget
            Observed      = "$($cpuObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))%"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Observed idle CPU average ($cpuObs%) meets Plan target ($cpuTarget)."
        })
    } else {
        $waiver = & $findWaiverForMetric 'IdleCpuAveragePercent'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'IdleCpuAveragePercent'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-01-CPU'
                    Metric        = 'Core + App idle CPU'
                    Target        = $cpuTarget
                    Observed      = "$($cpuObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))%"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Idle CPU ($cpuObs%) exceeded target ($cpuTarget); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-01-CPU'
                    Metric        = 'Core + App idle CPU'
                    Target        = $cpuTarget
                    Observed      = "$($cpuObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))%"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Idle CPU ($cpuObs%) exceeded target ($cpuTarget); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-01-CPU'
                Metric        = 'Core + App idle CPU'
                Target        = $cpuTarget
                Observed      = "$($cpuObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture))%"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Idle CPU ($cpuObs%) exceeded target ($cpuTarget) with no waiver."
            })
        }
    }

    # 2. Core + App idle working set (<= 180 MB = 188,743,680 bytes)
    $wsBytes = [long]$metrics.IdleWorkingSetCombinedBytes
    $wsMb = $wsBytes / (1024.0 * 1024.0)
    $wsTarget = "<= 180.0 MB (188,743,680 bytes)"
    if ($wsBytes -le $script:V07PlanBudgets.MaxIdleWorkingSetCombinedBytes) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-02-WORKINGSET'
            Metric        = 'Core + App idle working set'
            Target        = $wsTarget
            Observed      = "$($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB ($wsBytes bytes)"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Combined working set ($($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB) meets Plan target ($wsTarget)."
        })
    } else {
        $waiver = & $findWaiverForMetric 'IdleWorkingSetCombinedBytes'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'IdleWorkingSetCombinedBytes'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-02-WORKINGSET'
                    Metric        = 'Core + App idle working set'
                    Target        = $wsTarget
                    Observed      = "$($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB ($wsBytes bytes)"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Working set ($($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB) exceeded target ($wsTarget); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-02-WORKINGSET'
                    Metric        = 'Core + App idle working set'
                    Target        = $wsTarget
                    Observed      = "$($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB ($wsBytes bytes)"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Working set ($($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB) exceeded target ($wsTarget); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-02-WORKINGSET'
                Metric        = 'Core + App idle working set'
                Target        = $wsTarget
                Observed      = "$($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB ($wsBytes bytes)"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Working set ($($wsMb.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) MB) exceeded target ($wsTarget) with no waiver."
            })
        }
    }

    # 3. Widget state-delta latency (p95 <= 250 ms)
    $latObs = [double]$metrics.WidgetStateDeltaLatencyP95Ms
    $latTarget = "p95 <= 250.0 ms"

    # p95 Sample Recomputation verification (if raw samples provided)
    if ($null -ne $metrics.PSObject.Properties['WidgetDeltaLatencySamplesMs'] -and $null -ne $metrics.WidgetDeltaLatencySamplesMs) {
        $samples = [double[]]@($metrics.WidgetDeltaLatencySamplesMs)
        if ($samples.Length -gt 0) {
            $recomputedP95 = [HerdrOps.BudgetValidation.StrictJsonValidator]::CalculateP95($samples)
            if ([Math]::Abs($recomputedP95 - $latObs) -gt 0.05) {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-03-LATENCY-RECOMPUTE'
                    Metric        = 'Widget delta latency p95 recomputation'
                    Target        = "Reported p95 ($latObs ms) equals recomputed p95 ($recomputedP95 ms)"
                    Observed      = "Discrepancy: reported=$latObs ms, recomputed=$recomputedP95 ms"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Reported p95 latency does not match recomputed sample distribution."
                })
            }
        }
    }

    if ($latObs -le $script:V07PlanBudgets.MaxWidgetStateDeltaLatencyP95Ms) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-03-LATENCY'
            Metric        = 'Widget state-delta latency'
            Target        = $latTarget
            Observed      = "$($latObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Widget state-delta latency p95 ($latObs ms) meets Plan target ($latTarget)."
        })
    } else {
        $waiver = & $findWaiverForMetric 'WidgetStateDeltaLatencyP95Ms'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'WidgetStateDeltaLatencyP95Ms'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-03-LATENCY'
                    Metric        = 'Widget state-delta latency'
                    Target        = $latTarget
                    Observed      = "$($latObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Widget delta latency ($latObs ms) exceeded target ($latTarget); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-03-LATENCY'
                    Metric        = 'Widget state-delta latency'
                    Target        = $latTarget
                    Observed      = "$($latObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Widget delta latency ($latObs ms) exceeded target ($latTarget); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-03-LATENCY'
                Metric        = 'Widget state-delta latency'
                Target        = $latTarget
                Observed      = "$($latObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Widget delta latency ($latObs ms) exceeded target ($latTarget) with no waiver."
            })
        }
    }

    # 4. Dashboard cold launch (p95 <= 2.0 s = 2000 ms)
    $launchObs = [double]$metrics.DashboardColdLaunchP95Ms
    $launchTarget = "p95 <= 2.0 s (2000.0 ms)"

    if ($null -ne $metrics.PSObject.Properties['DashboardColdLaunchSamplesMs'] -and $null -ne $metrics.DashboardColdLaunchSamplesMs) {
        $launchSamples = [double[]]@($metrics.DashboardColdLaunchSamplesMs)
        if ($launchSamples.Length -gt 0) {
            $recomputedLaunchP95 = [HerdrOps.BudgetValidation.StrictJsonValidator]::CalculateP95($launchSamples)
            if ([Math]::Abs($recomputedLaunchP95 - $launchObs) -gt 0.05) {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-04-COLDLAUNCH-RECOMPUTE'
                    Metric        = 'Dashboard cold launch p95 recomputation'
                    Target        = "Reported p95 ($launchObs ms) equals recomputed p95 ($recomputedLaunchP95 ms)"
                    Observed      = "Discrepancy: reported=$launchObs ms, recomputed=$recomputedLaunchP95 ms"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Reported p95 cold launch does not match recomputed sample distribution."
                })
            }
        }
    }

    if ($launchObs -le $script:V07PlanBudgets.MaxDashboardColdLaunchP95Ms) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-04-COLDLAUNCH'
            Metric        = 'Dashboard cold launch'
            Target        = $launchTarget
            Observed      = "$($launchObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Dashboard cold launch p95 ($launchObs ms) meets Plan target ($launchTarget)."
        })
    } else {
        $waiver = & $findWaiverForMetric 'DashboardColdLaunchP95Ms'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'DashboardColdLaunchP95Ms'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-04-COLDLAUNCH'
                    Metric        = 'Dashboard cold launch'
                    Target        = $launchTarget
                    Observed      = "$($launchObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Cold launch ($launchObs ms) exceeded target ($launchTarget); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-04-COLDLAUNCH'
                    Metric        = 'Dashboard cold launch'
                    Target        = $launchTarget
                    Observed      = "$($launchObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Cold launch ($launchObs ms) exceeded target ($launchTarget); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-04-COLDLAUNCH'
                Metric        = 'Dashboard cold launch'
                Target        = $launchTarget
                Observed      = "$($launchObs.ToString('F2', [Globalization.CultureInfo]::InvariantCulture)) ms"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Cold launch ($launchObs ms) exceeded target ($launchTarget) with no waiver."
            })
        }
    }

    # 5. Herdr reconnect and reconcile (<= 5.0 s)
    $recObs = [double]$metrics.HerdrReconnectReconcileSeconds
    $recTarget = "<= 5.0 s"
    if ($recObs -le $script:V07PlanBudgets.MaxHerdrReconnectReconcileSeconds) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-05-RECONNECT'
            Metric        = 'Herdr reconnect and reconcile'
            Target        = $recTarget
            Observed      = "$($recObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) s"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Reconnect and reconcile ($recObs s) meets Plan target ($recTarget)."
        })
    } else {
        $waiver = & $findWaiverForMetric 'HerdrReconnectReconcileSeconds'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'HerdrReconnectReconcileSeconds'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-05-RECONNECT'
                    Metric        = 'Herdr reconnect and reconcile'
                    Target        = $recTarget
                    Observed      = "$($recObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) s"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Reconnect time ($recObs s) exceeded target ($recTarget); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-05-RECONNECT'
                    Metric        = 'Herdr reconnect and reconcile'
                    Target        = $recTarget
                    Observed      = "$($recObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) s"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Reconnect time ($recObs s) exceeded target ($recTarget); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-05-RECONNECT'
                Metric        = 'Herdr reconnect and reconcile'
                Target        = $recTarget
                Observed      = "$($recObs.ToString('F3', [Globalization.CultureInfo]::InvariantCulture)) s"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Reconnect time ($recObs s) exceeded target ($recTarget) with no waiver."
            })
        }
    }

    # 6. Unbounded terminal reads (0)
    $termObs = [int]$metrics.UnboundedTerminalReads
    $termTarget = "0"
    if ($termObs -eq 0) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-06-TERMINAL'
            Metric        = 'Unbounded terminal reads'
            Target        = $termTarget
            Observed      = "$termObs"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Zero unbounded terminal reads observed."
        })
    } else {
        $waiver = & $findWaiverForMetric 'UnboundedTerminalReads'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'UnboundedTerminalReads'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-06-TERMINAL'
                    Metric        = 'Unbounded terminal reads'
                    Target        = $termTarget
                    Observed      = "$termObs"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Unbounded terminal reads ($termObs) exceeded target (0); approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-06-TERMINAL'
                    Metric        = 'Unbounded terminal reads'
                    Target        = $termTarget
                    Observed      = "$termObs"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Unbounded terminal reads ($termObs) exceeded target (0); waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-06-TERMINAL'
                Metric        = 'Unbounded terminal reads'
                Target        = $termTarget
                Observed      = "$termObs"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Unbounded terminal reads ($termObs) exceeded target (0) with no waiver."
            })
        }
    }

    # 7. Unhandled crash during v0.7 soak (0 in 8 hours)
    # Preservation of preparation boundary: preparation slice reports NOT OBSERVED for 0h soak, NEVER PASS as runtime.
    # Actual Runtime admission requires full >= 8.0h soak execution and cannot treat zero-hour soak as pass.
    $crashObs = [int]$metrics.UnhandledCrashesDuringSoak
    $soakDuration = if ($null -ne $metrics.PSObject.Properties['SoakDurationHours'] -and $null -ne $metrics.SoakDurationHours) {
        [double]$metrics.SoakDurationHours
    } else {
        0.0
    }
    $crashTarget = "0 crashes in >= 8.0 hours"

    $evidenceClass = if ($null -ne $ReportObject.PSObject.Properties['EvidenceClass']) { [string]$ReportObject.EvidenceClass } else { 'Preparation' }
    $isRuntimeAdmission = ($evidenceClass -inotmatch 'Preparation') -or
        ($null -ne $ReportObject.PSObject.Properties['EvidenceBoundary'] -and
         ($ReportObject.EvidenceBoundary.ActualHerdrRuntime -match '^OBSERVED' -or $ReportObject.EvidenceBoundary.SoakExecution -match '^OBSERVED'))

    if ($crashObs -eq 0 -and $soakDuration -ge $script:V07PlanBudgets.MinSoakDurationHours) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-07-SOAK'
            Metric        = 'Unhandled crash during v0.7 soak'
            Target        = $crashTarget
            Observed      = "$crashObs crashes in $($soakDuration.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) hours"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Zero unhandled crashes over full 8-hour soak duration."
        })
    } elseif ($crashObs -eq 0 -and $soakDuration -eq 0.0 -and -not $isRuntimeAdmission) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-07-SOAK'
            Metric        = 'Unhandled crash during v0.7 soak'
            Target        = $crashTarget
            Observed      = "$crashObs crashes (Soak duration: NOT EXECUTED / PREPARATION)"
            Status        = 'NOT OBSERVED'
            WaiverApplied = $false
            Detail        = "Zero unhandled crashes recorded in preparation slice; sustained 8-hour live soak execution is NOT OBSERVED."
        })
    } else {
        $waiver = & $findWaiverForMetric 'UnhandledCrashesDuringSoak'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'UnhandledCrashesDuringSoak'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-07-SOAK'
                    Metric        = 'Unhandled crash during v0.7 soak'
                    Target        = $crashTarget
                    Observed      = "$crashObs crashes in $($soakDuration.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) hours"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Soak crashes ($crashObs) or duration ($soakDuration h) violated target; approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-07-SOAK'
                    Metric        = 'Unhandled crash during v0.7 soak'
                    Target        = $crashTarget
                    Observed      = "$crashObs crashes in $($soakDuration.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) hours"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Soak crashes ($crashObs) or duration ($soakDuration h) violated target; waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $failDetail = if ($isRuntimeAdmission -and $soakDuration -lt $script:V07PlanBudgets.MinSoakDurationHours) {
                "Actual Runtime admission requires sustained 8-hour soak (observed: $soakDuration h < 8.0 h); zero-hour or partial soak cannot satisfy runtime requirement without waiver."
            } else {
                "Soak crashes ($crashObs) or insufficient soak duration ($soakDuration h < 8.0 h) without waiver."
            }
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-07-SOAK'
                Metric        = 'Unhandled crash during v0.7 soak'
                Target        = $crashTarget
                Observed      = "$crashObs crashes in $($soakDuration.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) hours"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = $failDetail
            })
        }
    }

    # 8. Normal-mode Administrator requirement (None / false)
    $adminObs = [bool]$metrics.AdministratorRequired
    $adminTarget = "None (AdministratorRequired = False)"
    if (-not $adminObs) {
        $checks.Add([pscustomobject]@{
            Id            = 'V07-PERF-08-PRIVILEGE'
            Metric        = 'Normal-mode Administrator requirement'
            Target        = $adminTarget
            Observed      = "AdministratorRequired = $adminObs"
            Status        = 'PASS'
            WaiverApplied = $false
            Detail        = "Normal operation requires no Administrator elevation."
        })
    } else {
        $waiver = & $findWaiverForMetric 'AdministratorRequired'
        if ($null -ne $waiver) {
            $wCheck = Test-WaiverIntegrity -Waiver $waiver -ExpectedMetric 'AdministratorRequired'
            if ($wCheck.IsValid) {
                $waiversApplied.Add($waiver)
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-08-PRIVILEGE'
                    Metric        = 'Normal-mode Administrator requirement'
                    Target        = $adminTarget
                    Observed      = "AdministratorRequired = $adminObs"
                    Status        = 'PASS (WAIVED)'
                    WaiverApplied = $true
                    Detail        = "Administrator requirement ($adminObs) violated target; approved waiver applied: $($wCheck.Reason)"
                })
            } else {
                $allPassed = $false
                $checks.Add([pscustomobject]@{
                    Id            = 'V07-PERF-08-PRIVILEGE'
                    Metric        = 'Normal-mode Administrator requirement'
                    Target        = $adminTarget
                    Observed      = "AdministratorRequired = $adminObs"
                    Status        = 'FAIL'
                    WaiverApplied = $false
                    Detail        = "Administrator requirement ($adminObs) violated target; waiver invalid: $($wCheck.Reason)"
                })
            }
        } else {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-PERF-08-PRIVILEGE'
                Metric        = 'Normal-mode Administrator requirement'
                Target        = $adminTarget
                Observed      = "AdministratorRequired = $adminObs"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Administrator requirement ($adminObs) violated target with no waiver."
            })
        }
    }

    # 9. Fault & Unreconciled-State Fail-Closed Verification
    if ($null -ne $metrics.PSObject.Properties['UnreconciledStateCount'] -and [int]$metrics.UnreconciledStateCount -gt 0) {
        $allPassed = $false
        $checks.Add([pscustomobject]@{
            Id            = 'V07-FAULT-01-UNRECONCILED'
            Metric        = 'Unreconciled state count'
            Target        = '0 unreconciled states'
            Observed      = "$($metrics.UnreconciledStateCount) unreconciled states"
            Status        = 'FAIL'
            WaiverApplied = $false
            Detail        = "Unreconciled state count ($($metrics.UnreconciledStateCount)) indicates state synchronization divergence."
        })
    }

    if ($null -ne $metrics.PSObject.Properties['UnhandledFaultCount'] -and [int]$metrics.UnhandledFaultCount -gt 0) {
        $allPassed = $false
        $checks.Add([pscustomobject]@{
            Id            = 'V07-FAULT-02-UNHANDLED'
            Metric        = 'Unhandled fault count'
            Target        = '0 unhandled faults'
            Observed      = "$($metrics.UnhandledFaultCount) unhandled faults"
            Status        = 'FAIL'
            WaiverApplied = $false
            Detail        = "Unhandled fault count ($($metrics.UnhandledFaultCount)) indicates unhandled crash or fault."
        })
    }

    if ($null -ne $ReportObject.PSObject.Properties['Reconciliation'] -and $null -ne $ReportObject.Reconciliation) {
        $recObj = $ReportObject.Reconciliation
        if ($recObj.ReconciliationStatus -ne 'Reconciled' -or [bool]$recObj.HasUnreconciledState -eq $true) {
            $allPassed = $false
            $checks.Add([pscustomobject]@{
                Id            = 'V07-FAULT-03-RECONCILIATION'
                Metric        = 'Reconciliation state'
                Target        = 'Reconciled with no divergence'
                Observed      = "Status=$($recObj.ReconciliationStatus), HasUnreconciledState=$($recObj.HasUnreconciledState)"
                Status        = 'FAIL'
                WaiverApplied = $false
                Detail        = "Reconciliation status is not reconciled or reports unreconciled state."
            })
        }
    }

    # 10. Process Telemetry PID + Start Time Binding / PID Reuse Protection (DECISIONS.md D-010/D-011)
    if ($null -ne $ReportObject.PSObject.Properties['ProcessTelemetry'] -and $null -ne $ReportObject.ProcessTelemetry) {
        $observedPids = [ordered]@{}
        $pidReuseDetected = $false
        foreach ($proc in @($ReportObject.ProcessTelemetry)) {
            $pKey = [string]$proc.ProcessId
            if ($observedPids.Contains($pKey)) {
                $priorStart = $observedPids[$pKey]
                if ($priorStart -ne $proc.ProcessStartUtc) {
                    $pidReuseDetected = $true
                    $allPassed = $false
                    $checks.Add([pscustomobject]@{
                        Id            = "V07-PID-REUSE-$pKey"
                        Metric        = "Process PID+StartUtc binding"
                        Target        = "PID $pKey preserves constant ProcessStartUtc ($priorStart)"
                        Observed      = "PID $pKey changed start time to $($proc.ProcessStartUtc) (PID reuse anomaly)"
                        Status        = 'FAIL'
                        WaiverApplied = $false
                        Detail        = "PID reuse without distinct process start time correlation fails closed."
                    })
                }
            } else {
                $observedPids[$pKey] = $proc.ProcessStartUtc
            }
        }
        if (-not $pidReuseDetected) {
            $checks.Add([pscustomobject]@{
                Id            = "V07-PID-BINDING"
                Metric        = "Process PID+StartUtc binding"
                Target        = "PID+ProcessStartUtc immutable pairing"
                Observed      = "$($observedPids.Count) unique process identities bound"
                Status        = 'PASS'
                WaiverApplied = $false
                Detail        = "Process telemetry strictly binds PID and start time with zero PID reuse anomalies."
            })
        }
    }

    # 11. Candidate Binaries Verification (if CandidateDirectory and Binaries are present)
    $candidateBindings = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $ReportObject.PSObject.Properties['Candidate'] -and
        $null -ne $ReportObject.Candidate.PSObject.Properties['Binaries'] -and
        $null -ne $ReportObject.Candidate.Binaries -and
        -not [string]::IsNullOrWhiteSpace($CandidateDirectory) -and
        -not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $allowedRoots = @($RepositoryRoot, $CandidateDirectory)
        foreach ($bin in @($ReportObject.Candidate.Binaries)) {
            $fullBinPath = Join-Path $RepositoryRoot $bin.RelativePath
            if (Test-Path -LiteralPath $fullBinPath -PathType Leaf) {
                $resolvedBinPath = Assert-PathWithinRoot -Path $fullBinPath -AllowedRoots $allowedRoots -Description "Candidate binary $($bin.RelativePath)"
                Assert-NotReparsePoint -Path $resolvedBinPath -Description "Candidate binary $($bin.RelativePath)"

                $actualLength = (Get-Item -LiteralPath $resolvedBinPath).Length
                $actualSha = Get-Sha256DigestHex -Path $resolvedBinPath
                $declaredSha = ($bin.Sha256).ToLowerInvariant()

                if ($actualLength -eq $bin.LengthBytes -and $actualSha -eq $declaredSha) {
                    $candidateBindings.Add([pscustomobject]@{
                        Path     = $bin.RelativePath
                        Status   = 'BOUND_AND_VERIFIED'
                        Length   = $actualLength
                        Sha256   = $actualSha
                    })
                } else {
                    $allPassed = $false
                    $candidateBindings.Add([pscustomobject]@{
                        Path     = $bin.RelativePath
                        Status   = 'TAMPER_OR_MISMATCH'
                        Length   = $actualLength
                        Sha256   = $actualSha
                    })
                    $checks.Add([pscustomobject]@{
                        Id            = "V07-CANDIDATE-HASH-$([IO.Path]::GetFileNameWithoutExtension($bin.RelativePath))"
                        Metric        = "Candidate binary hash verification"
                        Target        = "Exact byte length and SHA-256 match ($($bin.Sha256))"
                        Observed      = "Actual length=$actualLength bytes, SHA-256=$actualSha"
                        Status        = 'FAIL'
                        WaiverApplied = $false
                        Detail        = "Candidate binary $($bin.RelativePath) does not match declared SHA-256 or length."
                    })
                }
            }
        }
    }

    $overallStatus = if ($allPassed -and $waiversApplied.Count -gt 0) {
        'PASS (WITH WAIVER)'
    } elseif ($allPassed) {
        'PASS'
    } else {
        'FAIL'
    }

    return [pscustomobject]@{
        OverallStatus     = $overallStatus
        Passed            = $allPassed
        Checks            = @($checks)
        WaiversApplied    = @($waiversApplied)
        CandidateBindings = @($candidateBindings)
    }
}

# -----------------------------------------------------------------------------
# Deterministic Self-Test Suite
# -----------------------------------------------------------------------------
function Invoke-PerformanceBudgetSelfTests {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$FixturesDirectory
    )

    $selfTestResults = [System.Collections.Generic.List[object]]::new()

    $recordSelfTest = {
        param([string]$TestName, [bool]$Passed, [string]$Detail)
        $selfTestResults.Add([pscustomobject]@{
            TestName = $TestName
            Status   = if ($Passed) { 'PASS' } else { 'FAIL' }
            Detail   = $Detail
        })
    }

    # Test 1: Passing golden fixture
    $passingPath = Join-Path $FixturesDirectory 'passing-budget-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $passingPath -Description 'Passing fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'passing fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        & $recordSelfTest 'Positive: Golden passing budget report' ($eval.Passed -and $eval.OverallStatus -eq 'PASS') "All 8 checks PASS"
    } catch {
        & $recordSelfTest 'Positive: Golden passing budget report' $false $_.Exception.Message
    }

    # Test 2: Waived budget fixture
    $waivedPath = Join-Path $FixturesDirectory 'waived-budget-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $waivedPath -Description 'Waived fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'waived fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        & $recordSelfTest 'Positive: Budget overrun with valid waiver' ($eval.Passed -and $eval.OverallStatus -eq 'PASS (WITH WAIVER)') "Waiver correctly transitions failing metric to PASS (WAIVED)"
    } catch {
        & $recordSelfTest 'Positive: Budget overrun with valid waiver' $false $_.Exception.Message
    }

    # Test 3: Exact boundary pass fixture (CPU=1.0%, WS=188743680, Lat=250.0ms, Launch=2000.0ms, Rec=5.0s, Crash=0 in 8.0h)
    $exactBoundaryPath = Join-Path $FixturesDirectory 'boundary-exact-pass.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $exactBoundaryPath -Description 'Exact boundary pass fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'exact boundary fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        & $recordSelfTest 'Positive: Exact boundary values pass' ($eval.Passed -and $eval.OverallStatus -eq 'PASS') "Exact boundary thresholds pass without waiver"
    } catch {
        & $recordSelfTest 'Positive: Exact boundary values pass' $false $_.Exception.Message
    }

    # Negative Test 4: CPU boundary + epsilon failure (1.001%)
    $failingCpuEpsilonPath = Join-Path $FixturesDirectory 'boundary-cpu-plus-epsilon-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingCpuEpsilonPath -Description 'CPU + epsilon failure'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'CPU + epsilon fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $cpuCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-01-CPU')[0]
        & $recordSelfTest 'Negative: CPU boundary + epsilon (1.001%) fails' (-not $eval.Passed -and $cpuCheck.Status -eq 'FAIL') "CPU 1.001% fails closed"
    } catch {
        & $recordSelfTest 'Negative: CPU boundary + epsilon (1.001%) fails' $false $_.Exception.Message
    }

    # Negative Test 5: Working set boundary + epsilon failure (188,743,681 bytes)
    $failingWsEpsilonPath = Join-Path $FixturesDirectory 'boundary-ws-plus-epsilon-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingWsEpsilonPath -Description 'WS + epsilon failure'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'WS + epsilon fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $wsCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-02-WORKINGSET')[0]
        & $recordSelfTest 'Negative: Working set boundary + 1 byte fails' (-not $eval.Passed -and $wsCheck.Status -eq 'FAIL') "WS 188,743,681 bytes fails closed"
    } catch {
        & $recordSelfTest 'Negative: Working set boundary + 1 byte fails' $false $_.Exception.Message
    }

    # Negative Test 6: Latency boundary + epsilon failure (250.1 ms)
    $failingLatEpsilonPath = Join-Path $FixturesDirectory 'boundary-latency-plus-epsilon-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingLatEpsilonPath -Description 'Latency + epsilon failure'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'Latency + epsilon fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $latCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-03-LATENCY')[0]
        & $recordSelfTest 'Negative: Latency boundary + epsilon (250.1 ms) fails' (-not $eval.Passed -and $latCheck.Status -eq 'FAIL') "Latency 250.1 ms fails closed"
    } catch {
        & $recordSelfTest 'Negative: Latency boundary + epsilon (250.1 ms) fails' $false $_.Exception.Message
    }

    # Negative Test 7: Cold launch boundary + epsilon failure (2000.1 ms)
    $failingLaunchEpsilonPath = Join-Path $FixturesDirectory 'boundary-launch-plus-epsilon-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingLaunchEpsilonPath -Description 'Launch + epsilon failure'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'Launch + epsilon fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $launchCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-04-COLDLAUNCH')[0]
        & $recordSelfTest 'Negative: Cold launch boundary + epsilon (2000.1 ms) fails' (-not $eval.Passed -and $launchCheck.Status -eq 'FAIL') "Cold launch 2000.1 ms fails closed"
    } catch {
        & $recordSelfTest 'Negative: Cold launch boundary + epsilon (2000.1 ms) fails' $false $_.Exception.Message
    }

    # Negative Test 8: Reconnect boundary + epsilon failure (5.001 s)
    $failingRecEpsilonPath = Join-Path $FixturesDirectory 'boundary-reconnect-plus-epsilon-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingRecEpsilonPath -Description 'Reconnect + epsilon failure'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'Reconnect + epsilon fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $recCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-05-RECONNECT')[0]
        & $recordSelfTest 'Negative: Reconnect boundary + epsilon (5.001 s) fails' (-not $eval.Passed -and $recCheck.Status -eq 'FAIL') "Reconnect 5.001 s fails closed"
    } catch {
        & $recordSelfTest 'Negative: Reconnect boundary + epsilon (5.001 s) fails' $false $_.Exception.Message
    }

    # Negative Test 9: p95 recomputation mismatch detection
    $p95TamperPath = Join-Path $FixturesDirectory 'p95-tampered-sample-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $p95TamperPath -Description 'p95 tampered sample fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'p95 tampered fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $p95Check = @($eval.Checks | Where-Object Id -eq 'V07-PERF-03-LATENCY-RECOMPUTE')[0]
        & $recordSelfTest 'Negative: Tampered p95 sample distribution fails' (-not $eval.Passed -and $p95Check.Status -eq 'FAIL') "Discrepancy between reported p95 and recomputed p95 fails closed"
    } catch {
        & $recordSelfTest 'Negative: Tampered p95 sample distribution fails' $false $_.Exception.Message
    }

    # Negative Test 10: PID reuse detection without stable start time
    $pidReusePath = Join-Path $FixturesDirectory 'pid-reuse-tampered-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $pidReusePath -Description 'PID reuse fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'PID reuse fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $pidCheck = @($eval.Checks | Where-Object Id -match '^V07-PID-REUSE')[0]
        & $recordSelfTest 'Negative: PID reuse with altered start time fails' (-not $eval.Passed -and $pidCheck.Status -eq 'FAIL') "PID reuse detected and fails closed"
    } catch {
        & $recordSelfTest 'Negative: PID reuse with altered start time fails' $false $_.Exception.Message
    }

    # Negative Test 11: Disallowed native trim waiver
    $disallowedTrimWaiverPath = Join-Path $FixturesDirectory 'disallowed-native-trim-waiver-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $disallowedTrimWaiverPath -Description 'Disallowed trim waiver fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'disallowed trim waiver fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $wsCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-02-WORKINGSET')[0]
        & $recordSelfTest 'Negative: Disallowed native trim waiver fails' (-not $eval.Passed -and $wsCheck.Status -eq 'FAIL') "Waiver claiming native trim is rejected"
    } catch {
        & $recordSelfTest 'Negative: Disallowed native trim waiver fails' $false $_.Exception.Message
    }

    # Negative Test 12: Fault & unreconciled state fails closed
    $unreconciledPath = Join-Path $FixturesDirectory 'unreconciled-state-fail.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $unreconciledPath -Description 'Unreconciled state fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'unreconciled state fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $unrecCheck = @($eval.Checks | Where-Object Id -eq 'V07-FAULT-01-UNRECONCILED')[0]
        & $recordSelfTest 'Negative: Unreconciled state fails closed' (-not $eval.Passed -and $unrecCheck.Status -eq 'FAIL') "Unreconciled states fail closed"
    } catch {
        & $recordSelfTest 'Negative: Unreconciled state fails closed' $false $_.Exception.Message
    }

    # Negative Test 13: CPU budget exceeded (> 1.0%)
    $failingCpuPath = Join-Path $FixturesDirectory 'failing-cpu-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingCpuPath -Description 'Failing CPU fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing CPU fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $cpuCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-01-CPU')[0]
        & $recordSelfTest 'Negative: CPU budget exceeded' (-not $eval.Passed -and $cpuCheck.Status -eq 'FAIL') "CPU > 1.0% fails closed"
    } catch {
        & $recordSelfTest 'Negative: CPU budget exceeded' $false $_.Exception.Message
    }

    # Negative Test 14: Working set budget exceeded (> 180 MB)
    $failingWsPath = Join-Path $FixturesDirectory 'failing-working-set-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingWsPath -Description 'Failing working set fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing WS fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $wsCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-02-WORKINGSET')[0]
        & $recordSelfTest 'Negative: Working set budget exceeded' (-not $eval.Passed -and $wsCheck.Status -eq 'FAIL') "Working set > 180 MB fails closed"
    } catch {
        & $recordSelfTest 'Negative: Working set budget exceeded' $false $_.Exception.Message
    }

    # Negative Test 15: Latency exceeded (> 250 ms)
    $failingLatPath = Join-Path $FixturesDirectory 'failing-latency-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingLatPath -Description 'Failing latency fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing latency fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $latCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-03-LATENCY')[0]
        & $recordSelfTest 'Negative: Widget delta latency exceeded' (-not $eval.Passed -and $latCheck.Status -eq 'FAIL') "Latency p95 > 250 ms fails closed"
    } catch {
        & $recordSelfTest 'Negative: Widget delta latency exceeded' $false $_.Exception.Message
    }

    # Negative Test 16: Cold launch exceeded (> 2.0 s)
    $failingLaunchPath = Join-Path $FixturesDirectory 'failing-cold-launch-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingLaunchPath -Description 'Failing cold launch fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing cold launch fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $launchCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-04-COLDLAUNCH')[0]
        & $recordSelfTest 'Negative: Cold launch exceeded' (-not $eval.Passed -and $launchCheck.Status -eq 'FAIL') "Launch p95 > 2.0 s fails closed"
    } catch {
        & $recordSelfTest 'Negative: Cold launch exceeded' $false $_.Exception.Message
    }

    # Negative Test 17: Reconnect exceeded (> 5.0 s)
    $failingRecPath = Join-Path $FixturesDirectory 'failing-reconnect-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingRecPath -Description 'Failing reconnect fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing reconnect fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $recCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-05-RECONNECT')[0]
        & $recordSelfTest 'Negative: Reconnect exceeded' (-not $eval.Passed -and $recCheck.Status -eq 'FAIL') "Reconnect > 5.0 s fails closed"
    } catch {
        & $recordSelfTest 'Negative: Reconnect exceeded' $false $_.Exception.Message
    }

    # Negative Test 18: Unbounded terminal reads > 0
    $failingTermPath = Join-Path $FixturesDirectory 'failing-terminal-reads-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingTermPath -Description 'Failing terminal reads fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing terminal reads fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $termCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-06-TERMINAL')[0]
        & $recordSelfTest 'Negative: Unbounded terminal reads > 0' (-not $eval.Passed -and $termCheck.Status -eq 'FAIL') "Unbounded terminal reads > 0 fails closed"
    } catch {
        & $recordSelfTest 'Negative: Unbounded terminal reads > 0' $false $_.Exception.Message
    }

    # Negative Test 19: Soak unhandled crashes > 0
    $failingCrashesPath = Join-Path $FixturesDirectory 'failing-soak-crashes-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingCrashesPath -Description 'Failing soak crashes fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing soak crashes fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $crashCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
        & $recordSelfTest 'Negative: Soak unhandled crashes > 0' (-not $eval.Passed -and $crashCheck.Status -eq 'FAIL') "Soak crashes > 0 fails closed"
    } catch {
        & $recordSelfTest 'Negative: Soak unhandled crashes > 0' $false $_.Exception.Message
    }

    # Negative Test 20: Insufficient soak duration (< 8 hours)
    $failingSoakDurPath = Join-Path $FixturesDirectory 'failing-soak-duration-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingSoakDurPath -Description 'Failing soak duration fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing soak duration fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $soakCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
        & $recordSelfTest 'Negative: Soak duration < 8 hours' (-not $eval.Passed -and $soakCheck.Status -eq 'FAIL') "Soak duration < 8 hours fails closed"
    } catch {
        & $recordSelfTest 'Negative: Soak duration < 8 hours' $false $_.Exception.Message
    }

    # Negative Test 21: Elevation required
    $failingElevPath = Join-Path $FixturesDirectory 'failing-elevation-report.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $failingElevPath -Description 'Failing elevation fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'failing elevation fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $elevCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-08-PRIVILEGE')[0]
        & $recordSelfTest 'Negative: Administrator elevation required' (-not $eval.Passed -and $elevCheck.Status -eq 'FAIL') "Elevation required fails closed"
    } catch {
        & $recordSelfTest 'Negative: Administrator elevation required' $false $_.Exception.Message
    }

    # Negative Test 22: Invalid waiver (missing cause)
    $invalidWaiverCausePath = Join-Path $FixturesDirectory 'invalid-waiver-missing-cause.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $invalidWaiverCausePath -Description 'Invalid waiver missing cause'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'invalid waiver fixture'
        & $recordSelfTest 'Negative: Waiver missing cause fails schema' $false "Expected schema exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Waiver missing cause fails schema' $true "Rejected empty/missing cause: $($_.Exception.Message)"
    }

    # Negative Test 23: Invalid waiver (wrong metric)
    $invalidWaiverMetricPath = Join-Path $FixturesDirectory 'invalid-waiver-wrong-metric.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $invalidWaiverMetricPath -Description 'Invalid waiver wrong metric'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'invalid waiver metric fixture'
        $eval = Test-PerformanceBudgetReport -ReportObject $report
        $cpuCheck = @($eval.Checks | Where-Object Id -eq 'V07-PERF-01-CPU')[0]
        & $recordSelfTest 'Negative: Waiver for wrong metric fails closed' (-not $eval.Passed -and $cpuCheck.Status -eq 'FAIL') "Mismatched waiver metric fails closed"
    } catch {
        & $recordSelfTest 'Negative: Waiver for wrong metric fails closed' $false $_.Exception.Message
    }

    # Negative Test 24: Strict JSON schema unknown property
    $unknownPropPath = Join-Path $FixturesDirectory 'schema-unknown-property.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $unknownPropPath -Description 'Unknown property fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'unknown prop fixture'
        & $recordSelfTest 'Negative: Disallowed unknown property fails schema' $false "Expected schema exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Disallowed unknown property fails schema' $true "Rejected unknown property: $($_.Exception.Message)"
    }

    # Negative Test 25: Strict JSON duplicate key
    $dupKeyPath = Join-Path $FixturesDirectory 'schema-duplicate-key.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $dupKeyPath -Description 'Duplicate key fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'duplicate key fixture'
        & $recordSelfTest 'Negative: Duplicate JSON key fails schema' $false "Expected duplicate key exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Duplicate JSON key fails schema' $true "Rejected duplicate key: $($_.Exception.Message)"
    }

    # Negative Test 26: Strict JSON negative metric
    $negMetricPath = Join-Path $FixturesDirectory 'schema-negative-metric.json'
    try {
        $json = Get-BoundedUtf8FileText -Path $negMetricPath -Description 'Negative metric fixture'
        $report = ConvertFrom-StrictPerformanceBudgetJson -JsonText $json -SourceDescription 'negative metric fixture'
        & $recordSelfTest 'Negative: Negative metric value fails schema' $false "Expected negative metric exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Negative metric value fails schema' $true "Rejected negative metric: $($_.Exception.Message)"
    }

    # Negative Test 27: Path traversal outside repository root
    try {
        $disallowedPath = Join-Path $RepositoryRoot '..\..\..\escaped-file.json'
        $null = Assert-PathWithinRoot -Path $disallowedPath -AllowedRoots @($RepositoryRoot) -Description 'Escaped path'
        & $recordSelfTest 'Negative: Path traversal outside root fails' $false "Expected path traversal exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Path traversal outside root fails' $true "Rejected escaped path: $($_.Exception.Message)"
    }

    # Test 28: Zero-hour soak in Preparation mode (reports NOT OBSERVED, never PASS as runtime)
    try {
        $prep0hJson = Get-BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'passing-budget-report.json')
        $prep0hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $prep0hJson -SourceDescription 'prep 0h test'
        $prep0hReport.Metrics.SoakDurationHours = 0.0
        $prep0hReport.EvidenceClass = 'Preparation'
        $prep0hEval = Test-PerformanceBudgetReport -ReportObject $prep0hReport
        $soakCheck = @($prep0hEval.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
        & $recordSelfTest 'Preparation: Zero-hour soak reports NOT OBSERVED (never PASS as runtime)' ($prep0hEval.Passed -and $soakCheck.Status -eq 'NOT OBSERVED') "Preparation reports NOT OBSERVED: $($soakCheck.Detail)"
    } catch {
        & $recordSelfTest 'Preparation: Zero-hour soak reports NOT OBSERVED (never PASS as runtime)' $false $_.Exception.Message
    }

    # Negative Test 29: Zero-hour soak in Runtime admission fails closed (cannot satisfy 8-hour requirement)
    try {
        $run0hJson = Get-BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'passing-budget-report.json')
        $run0hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $run0hJson -SourceDescription 'runtime 0h test'
        $run0hReport.Metrics.SoakDurationHours = 0.0
        $run0hReport.EvidenceClass = 'Runtime'
        $run0hReport.EvidenceBoundary.ActualHerdrRuntime = 'OBSERVED'
        $run0hReport.EvidenceBoundary.SoakExecution = 'OBSERVED'
        $run0hEval = Test-PerformanceBudgetReport -ReportObject $run0hReport
        $soakCheck = @($run0hEval.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
        & $recordSelfTest 'Negative: Zero-hour soak in Runtime admission fails closed' (-not $run0hEval.Passed -and $soakCheck.Status -eq 'FAIL') "Runtime admission requires 8h soak; 0h fails closed"
    } catch {
        & $recordSelfTest 'Negative: Zero-hour soak in Runtime admission fails closed' $false $_.Exception.Message
    }

    # Test 30: Full 8-hour soak in Runtime admission passes
    try {
        $run8hJson = Get-BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'passing-budget-report.json')
        $run8hReport = ConvertFrom-StrictPerformanceBudgetJson -JsonText $run8hJson -SourceDescription 'runtime 8h test'
        $run8hReport.Metrics.SoakDurationHours = 8.0
        $run8hReport.EvidenceClass = 'Runtime'
        $run8hReport.EvidenceBoundary.ActualHerdrRuntime = 'OBSERVED'
        $run8hReport.EvidenceBoundary.SoakExecution = 'OBSERVED'
        $run8hEval = Test-PerformanceBudgetReport -ReportObject $run8hReport
        $soakCheck = @($run8hEval.Checks | Where-Object Id -eq 'V07-PERF-07-SOAK')[0]
        & $recordSelfTest 'Positive: 8-hour soak in Runtime admission passes' ($run8hEval.Passed -and $soakCheck.Status -eq 'PASS') "8h soak passes runtime admission"
    } catch {
        & $recordSelfTest 'Positive: 8-hour soak in Runtime admission passes' $false $_.Exception.Message
    }

    # Negative Test 31: Trailing content after root JSON object fails closed
    try {
        $trailingJson = (Get-BoundedUtf8FileText -Path (Join-Path $FixturesDirectory 'passing-budget-report.json')) + ' {"extra":"trailing"}'
        $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $trailingJson -SourceDescription 'trailing content test'
        & $recordSelfTest 'Negative: Trailing content after root JSON fails' $false "Expected trailing content exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Trailing content after root JSON fails' $true "Rejected trailing content: $($_.Exception.Message)"
    }

    # Negative Test 32: Trailing comma in JSON object fails closed
    try {
        $trailingCommaJson = '{"SchemaVersion":"v0.7.0",}'
        $null = ConvertFrom-StrictPerformanceBudgetJson -JsonText $trailingCommaJson -SourceDescription 'trailing comma test'
        & $recordSelfTest 'Negative: Trailing comma in JSON object fails' $false "Expected trailing comma exception was not thrown"
    } catch {
        & $recordSelfTest 'Negative: Trailing comma in JSON object fails' $true "Rejected trailing comma: $($_.Exception.Message)"
    }

    return @($selfTestResults)
}
