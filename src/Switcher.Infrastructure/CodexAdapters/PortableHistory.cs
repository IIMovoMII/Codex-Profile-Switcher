#nullable disable
using System;
using System.Collections.Generic;
using System.Text;
using System.Security.Cryptography;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace CodexHistoryCompat {
    public sealed class PortableRecord {
        public int LineNumber;
        public long? RolloutOrdinal;
        public string Type = "portable_input";
        public string OldId = "";
        public string NewId;
        public string Action = "clear_input_ids";
        public string CallId = "";
        public string OldLineSha256;
        public string UnsupportedReason;
        public bool NonVisualOnly;
    }
    // Locate only model-input IDs. No text, UI event, retained-source reference,
    // call_id, encrypted content, or guardian-history field is rewritten.
    public sealed class InputIdSlot {
        public int Start;
        public int Length;
        public string Type;
        public string Id;
        public bool HasReplayData;
        public string RecordType;
        public long? Ordinal;
    }

    public static class PortableHistory {
        // PowerShell 7 already includes this strict JSON parser. Reflection keeps
        // the helper compatible with Windows PowerShell 5.1 (which uses the
        // existing PowerShell validation fallback).
        private static readonly Type jsonDocument = Type.GetType("System.Text.Json.JsonDocument, System.Text.Json", false);
        private static readonly Type jsonOptions = Type.GetType("System.Text.Json.JsonDocumentOptions, System.Text.Json", false);
        public static bool SupportsFastJson { get { return jsonDocument != null && jsonOptions != null; } }
        private sealed class JsonAccess {
            public readonly object Options = Activator.CreateInstance(jsonOptions);
            public readonly MethodInfo Parse = jsonDocument.GetMethod("Parse", new Type[] { typeof(string), jsonOptions });
            private readonly PropertyInfo root = jsonDocument.GetProperty("RootElement");
            private readonly MethodInfo property, text, integer, tryProperty;
            private readonly PropertyInfo kind;
            public JsonAccess() {
                Type element = root.PropertyType;
                property = element.GetMethod("GetProperty", new Type[] { typeof(string) });
                text = element.GetMethod("GetString", Type.EmptyTypes);
                integer = element.GetMethod("GetInt64", Type.EmptyTypes);
                tryProperty = element.GetMethod("TryGetProperty", new Type[] { typeof(string), element.MakeByRefType() });
                kind = element.GetProperty("ValueKind");
            }
            public IDisposable Read(string value) { return (IDisposable)Parse.Invoke(null, new object[] { value, Options }); }
            public object Root(object doc) { return root.GetValue(doc, null); }
            public object Field(object value, string key) { return property.Invoke(value, new object[] { key }); }
            public string Text(object value, string key) { return (string)text.Invoke(Field(value, key), null); }
            public long Number(object value, string key) { return (long)integer.Invoke(Field(value, key), null); }
            public object OptionalField(object value, string key) {
                object[] args = new object[] { key, null };
                if (!(bool)tryProperty.Invoke(value, args) || kind.GetValue(args[1], null).ToString() == "Null") return null;
                return args[1];
            }
            public string OptionalText(object value, string key) {
                object field = OptionalField(value, key);
                return field == null ? null : (string)text.Invoke(field, null);
            }
        }
        private sealed class ExpectedEvent {
            public string Turn, Id, Type;
        }
        // Same provenance checks as the PowerShell path, without constructing
        // giant tool-output objects or crossing the shell boundary per field.
        public static bool VerifyEventSources(string path, string logicalThread, string[] projectedRows, bool nonVisualOnly, bool noDanglingTurns) {
            return VerifyEventSources(path, logicalThread, projectedRows, nonVisualOnly, noDanglingTurns, 0);
        }
        public static bool VerifyEventSources(string path, string logicalThread, string[] projectedRows, bool nonVisualOnly, bool noDanglingTurns, long startOffset) {
            var json = new JsonAccess();
            var wanted = new Dictionary<long, List<ExpectedEvent>>();
            foreach (string row in projectedRows) {
                using (var doc = json.Read(row)) {
                    object root = json.Root(doc);
                    var expected = new ExpectedEvent { Turn = json.Text(root, "turn"), Id = json.Text(root, "id"), Type = json.Text(root, "type") };
                    if (expected.Id != json.Text(root, "json_id") || expected.Type != json.Text(root, "json_type")) return false;
                    foreach (long ordinal in new HashSet<long> { json.Number(root, "ordinal"), json.Number(root, "updated") }) {
                        List<ExpectedEvent> list;
                        if (!wanted.TryGetValue(ordinal, out list)) { list = new List<ExpectedEvent>(); wanted.Add(ordinal, list); }
                        list.Add(expected);
                    }
                }
            }
            var found = new HashSet<long>();
            int nativeEvents = 0;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1048576, FileOptions.SequentialScan))
            {
            stream.Position = startOffset;
            using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), startOffset == 0, 1048576)) {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    using (var doc = json.Read(line)) {
                        object root = json.Root(doc);
                        long ordinal = json.Number(root, "ordinal");
                        List<ExpectedEvent> expected;
                        bool needed = wanted.TryGetValue(ordinal, out expected);
                        if (!needed && projectedRows.Length != 0) continue;
                        if (json.Text(root, "type") != "event_msg") { if (needed) return false; continue; }
                        object payload = json.Field(root, "payload");
                        if (json.Text(payload, "type") != "item_completed") { if (needed) return false; continue; }
                        object item = json.Field(payload, "item");
                        string turn = json.Text(payload, "turn_id"), id = json.Text(item, "id"), type = json.Text(item, "type");
                        if (json.Text(payload, "thread_id") != logicalThread || String.IsNullOrWhiteSpace(turn) ||
                            String.IsNullOrWhiteSpace(id) || String.IsNullOrWhiteSpace(type)) return false;
                        ++nativeEvents;
                        if (!needed) continue;
                        string mapped = Char.ToLowerInvariant(type[0]) + type.Substring(1);
                        if (type == "Extension") {
                            string kind = json.Text(item, "kind");
                            if (kind == "clock.sleep") mapped = "sleep";
                            else if (kind == "web.search") mapped = "webSearch";
                        }
                        foreach (var entry in expected)
                            if (entry.Turn != turn || entry.Id != id || entry.Type != mapped) return false;
                        found.Add(ordinal);
                    }
                }
            }
            }
            return projectedRows.Length == 0 ? noDanglingTurns && (nativeEvents > 0 || nonVisualOnly) : found.Count == wanted.Count;
        }
        public static long ValidateJsonFile(string path, bool requireOrdinals) {
            return ValidateJsonFile(path, requireOrdinals, null);
        }
        public static long ValidateJsonFile(string path, bool requireOrdinals, string independentThread) {
            if (!SupportsFastJson) throw new NotSupportedException("Native JSON parser unavailable.");
            MethodInfo parse = jsonDocument.GetMethod("Parse", new Type[] { typeof(string), jsonOptions });
            PropertyInfo rootProperty = jsonDocument.GetProperty("RootElement");
            Type element = rootProperty.PropertyType;
            MethodInfo property = element.GetMethod("GetProperty", new Type[] { typeof(string) });
            MethodInfo integer = element.GetMethod("GetInt64", Type.EmptyTypes);
            object options = Activator.CreateInstance(jsonOptions);
            var identity = String.IsNullOrEmpty(independentThread) ? null : new JsonAccess();
            long last = -1; int number = 0;
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1048576, FileOptions.SequentialScan))
            using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), true, 1048576)) {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    ++number;
                    try {
                        using (var doc = (IDisposable)parse.Invoke(null, new object[] { line, options })) {
                            if (!requireOrdinals) continue;
                            object root = rootProperty.GetValue(doc, null);
                            long ordinal = (long)integer.Invoke(property.Invoke(root, new object[] { "ordinal" }), null);
                            if (ordinal < 0 || ordinal <= last) throw new FormatException("Invalid or non-increasing ordinal.");
                            if (identity != null) {
                                if (ordinal != number - 1) throw new FormatException("Independent segment must have contiguous ordinals from zero.");
                                string recordType = identity.Text(root, "type");
                                if (number == 1 && recordType != "session_meta") throw new FormatException("Independent segment has no initial session metadata.");
                                if (recordType == "session_meta") {
                                    object meta = identity.Field(root, "payload");
                                    string session = identity.OptionalText(meta, "session_id");
                                    if (identity.Text(meta, "id") != independentThread || identity.Text(meta, "history_mode") != "paginated" ||
                                        (session != null && session != independentThread) || identity.OptionalField(meta, "history_base") != null ||
                                        identity.OptionalField(meta, "forked_from_id") != null || identity.OptionalField(meta, "forked_from_ordinal_exclusive") != null)
                                        throw new FormatException("Independent segment has conflicting ownership or unresolved ancestry.");
                                } else if (recordType == "event_msg") {
                                    string owner = identity.OptionalText(identity.Field(root, "payload"), "thread_id");
                                    if (owner != null && owner != independentThread) throw new FormatException("Independent segment contains a foreign event.");
                                }
                            }
                            last = ordinal;
                        }
                    } catch (Exception error) {
                        throw new FormatException("Invalid JSONL/ordinal at " + path + ":" + number, error);
                    }
                }
            }
            if (requireOrdinals && last < 0) throw new FormatException("Empty paginated journal.");
            return last;
        }
        private static readonly HashSet<string> optionalIdTypes = new HashSet<string>(StringComparer.Ordinal) {
            "message", "reasoning", "compaction", "function_call", "function_call_output", "custom_tool_call",
            "custom_tool_call_output", "additional_tools", "agent_message", "local_shell_call", "tool_search_call",
            "tool_search_output", "web_search_call", "image_generation_call", "context_compaction"
        };
        public static PortableRecord Inspect(string json, int lineNumber) {
            var slots = Find(json);
            if (slots.Length == 0) return null;
            if (slots.Length == 1 && slots[0].RecordType == "response_item" &&
                slots[0].Type == "reasoning" && !slots[0].HasReplayData) return null;
            var record = new PortableRecord { LineNumber = lineNumber, RolloutOrdinal = slots[0].Ordinal, NonVisualOnly = true };
            foreach (var slot in slots) {
                record.NonVisualOnly &= slot.Type == "compaction" || slot.Type == "context_compaction";
                if (!optionalIdTypes.Contains(slot.Type)) record.UnsupportedReason = "Unverified optional ID type: " + slot.Type;
                if ((slot.Type == "reasoning" || slot.Type == "compaction") && !slot.HasReplayData)
                    record.UnsupportedReason = "Unreplayable reasoning/compaction inside replacement history.";
            }
            try { Validate(slots); } catch (FormatException e) { record.UnsupportedReason = e.Message; }
            using (var sha = SHA256.Create()) {
                record.OldLineSha256 = BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(json))).Replace("-", "").ToLowerInvariant();
            }
            return record;
        }

        public static InputIdSlot[] Find(string json) { return new Reader(json).Find(); }

        public static Dictionary<int, PortableRecord> ScanFile(string path) {
            return ScanFile(path, 0, 0);
        }
        public static Dictionary<int, PortableRecord> ScanFile(string path, long offset, int firstLine) {
            var records = new Dictionary<int, PortableRecord>();
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1048576, FileOptions.SequentialScan))
            {
                stream.Position = offset;
                using (var reader = new StreamReader(stream, new UTF8Encoding(false, true), offset == 0, 1048576)) {
                string line; int number = firstLine;
                while ((line = reader.ReadLine()) != null) {
                    ++number;
                    if (!line.Contains("\"response_item\"") && !line.Contains("\"compacted\"")) continue;
                    var record = Inspect(line, number);
                    if (record != null) records.Add(number, record);
                }
                }
            }
            return records;
        }

        public static JournalRange ValidateRange(string path, long offset, int firstLine, bool paginated, long previousOrdinal) {
            if (!SupportsFastJson) throw new NotSupportedException("Native JSON parser unavailable.");
            var result = new JournalRange { LastOrdinal = previousOrdinal };
            var json = new JsonAccess();
            foreach (var line in IncrementalIo.ReadLines(path, offset, firstLine)) {
                using (var doc = json.Read(line.Text)) {
                    object root = json.Root(doc);
                    if (paginated) {
                        long ordinal = json.Number(root, "ordinal");
                        if (ordinal < 0 || ordinal <= result.LastOrdinal) throw new FormatException("Invalid appended ordinal at line " + line.Number);
                        result.LastOrdinal = ordinal;
                    }
                    if (json.OptionalText(root, "type") == "session_meta") result.HasMetadata = true;
                }
                ++result.Lines;
            }
            result.EndsWithNewline = IncrementalIo.EndsWithNewline(path);
            return result;
        }

        public static void Validate(InputIdSlot[] slots) {
            foreach (var slot in slots) {
                if (slot.Length < 4 || slot.Id.IndexOf('\\') >= 0)
                    throw new FormatException("Unverified input ID encoding or insufficient byte slot.");
                foreach (char c in slot.Id)
                    if (c > 127 || c < 32) throw new FormatException("Non-ASCII input ID.");
            }
        }

        public static string Clear(string json) {
            InputIdSlot[] slots = Find(json);
            Validate(slots);
            var result = json.ToCharArray();
            foreach (var slot in slots) {
                result[slot.Start] = 'n'; result[slot.Start + 1] = 'u';
                result[slot.Start + 2] = 'l'; result[slot.Start + 3] = 'l';
                for (int index = slot.Start + 4; index < slot.Start + slot.Length; ++index) result[index] = ' ';
            }
            return new string(result);
        }

        public static void WriteFile(string source, string destination, PortableRecord[] records, bool bom, string newline, bool finalNewline) {
            var expected = new Dictionary<int, PortableRecord>();
            foreach (var record in records) {
                if (record.Action != "clear_input_ids" || record.UnsupportedReason != null)
                    throw new FormatException("Non-portable operation in fixed-slot writer.");
                expected.Add(record.LineNumber, record);
            }
            var utf8 = new UTF8Encoding(false, true);
            using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
            using (var reader = new StreamReader(input, utf8, true, 1048576))
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1048576, FileOptions.WriteThrough))
            using (var writer = new StreamWriter(output, new UTF8Encoding(bom, true), 1048576, true))
            using (var sha = SHA256.Create()) {
                int number = 0, changed = 0;
                string line;
                while ((line = reader.ReadLine()) != null) {
                    ++number;
                    PortableRecord record;
                    if (expected.TryGetValue(number, out record)) {
                        byte[] bytes = utf8.GetBytes(line);
                        string hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
                        int originalLength = bytes.Length;
                        Array.Clear(bytes, 0, bytes.Length);
                        if (hash != record.OldLineSha256) throw new IOException("History changed since scan: " + source + ":" + number);
                        line = Clear(line);
                        if (utf8.GetByteCount(line) != originalLength) throw new IOException("Portable repair changed a byte boundary.");
                        ++changed;
                    }
                    writer.Write(line);
                    if (reader.Peek() != -1 || finalNewline) writer.Write(newline);
                }
                if (changed != records.Length) throw new IOException("History record disappeared since scan.");
                writer.Flush();
                output.Flush(true);
            }
        }

        private sealed class Node {
            public int Route;
            public string Type;
            public InputIdSlot Slot;
            public bool HasReplayData;
        }

        // JSON has already been produced by Codex; callers also parse candidate
        // records semantically before any writes. This lexer retains exact offsets.
        private sealed class Reader {
            private readonly string text;
            private int pos;
            private string rootType;
            private long? rootOrdinal;
            private readonly List<Node> nodes = new List<Node>();
            public Reader(string value) { text = value; }
            public InputIdSlot[] Find() {
                Value(0, 0); White();
                if (pos != text.Length) throw new FormatException("Trailing JSON data.");
                var slots = new List<InputIdSlot>();
                foreach (var node in nodes) {
                    if (node.Slot == null) continue;
                    if ((rootType == "response_item" && node.Route == 1) ||
                        (rootType == "compacted" && node.Route == 3)) {
                        node.Slot.Type = node.Type;
                        node.Slot.HasReplayData = node.HasReplayData;
                        node.Slot.RecordType = rootType;
                        node.Slot.Ordinal = rootOrdinal;
                        slots.Add(node.Slot);
                    }
                }
                slots.Sort((a, b) => a.Start.CompareTo(b.Start));
                return slots.ToArray();
            }
            private void White() { while (pos < text.Length && char.IsWhiteSpace(text[pos])) ++pos; }
            private void Expect(char c) {
                White();
                if (pos >= text.Length || text[pos++] != c) throw new FormatException("Invalid JSON structure.");
            }
            private string StringToken(bool retain) {
                int start = pos;
                Expect('"');
                while (pos < text.Length) {
                    char c = text[pos++];
                    if (c == '\\') { if (pos >= text.Length) break; ++pos; }
                    else if (c == '"') return retain ? text.Substring(start + 1, pos - start - 2) : null;
                }
                throw new FormatException("Unterminated JSON string.");
            }
            private void Value(int route, int depth) {
                if (depth > 100) throw new FormatException("Unverified JSON nesting depth.");
                White();
                if (pos >= text.Length) throw new FormatException("Missing JSON value.");
                if (route == 4 && (text[pos] == '{' || text[pos] == '[')) {
                    // Skip values outside the two model-input paths without
                    // materializing tools, images, UI data or audit histories.
                    var ends = new Stack<char>();
                    do {
                        char c = text[pos];
                        if (c == '"') { StringToken(false); continue; }
                        ++pos;
                        if (c == '{') ends.Push('}');
                        else if (c == '[') ends.Push(']');
                        else if (c == '}' || c == ']') {
                            if (ends.Count == 0 || ends.Pop() != c) throw new FormatException("Invalid JSON nesting.");
                        }
                    } while (pos < text.Length && ends.Count > 0);
                    if (ends.Count != 0) throw new FormatException("Unterminated JSON value.");
                    return;
                }
                if (text[pos] == '{') {
                    ++pos; White();
                    var node = new Node { Route = route };
                    bool idSeen = false;
                    if (pos < text.Length && text[pos] != '}') while (true) {
                        White(); string key = StringToken(true); Expect(':'); White();
                        if (key.IndexOf('\\') >= 0) throw new FormatException("Unverified escaped structural JSON key.");
                        if (route == 0 && key == "ordinal") {
                            int start = pos;
                            Value(4, depth + 1);
                            long ordinal;
                            if (Int64.TryParse(text.Substring(start, pos - start), out ordinal)) rootOrdinal = ordinal;
                        } else if ((route == 0 || route == 1 || route == 3) && key == "type" && text[pos] == '"') {
                            node.Type = StringToken(true);
                            if (route == 0) rootType = node.Type;
                        } else if ((route == 1 || route == 3) && key == "encrypted_content" && text[pos] == '"') {
                            node.HasReplayData |= !String.IsNullOrWhiteSpace(StringToken(true));
                        } else if ((route == 1 || route == 3) && key == "content" && text[pos] == '[') {
                            int probe = pos + 1;
                            while (probe < text.Length && char.IsWhiteSpace(text[probe])) ++probe;
                            node.HasReplayData |= probe < text.Length && text[probe] == '{';
                            Value(4, depth + 1);
                        } else if ((route == 1 || route == 3) && key == "id") {
                            if (idSeen) throw new FormatException("Duplicate model input ID field.");
                            idSeen = true;
                            if (text[pos] == '"') {
                                int start = pos;
                                string id = StringToken(true);
                                node.Slot = new InputIdSlot { Start = start, Length = pos - start, Id = id };
                            } else {
                                int start = pos;
                                Value(4, depth + 1);
                                if (text.Substring(start, pos - start) != "null") throw new FormatException("Model input ID is neither a string nor null.");
                            }
                        } else {
                            int child = route == 0 && key == "payload" ? 1 :
                                route == 1 && key == "replacement_history" ? 2 : 4;
                            Value(child, depth + 1);
                        }
                        White();
                        if (pos < text.Length && text[pos] == ',') { ++pos; continue; }
                        break;
                    }
                    Expect('}'); nodes.Add(node);
                } else if (text[pos] == '[') {
                    ++pos; White();
                    if (pos < text.Length && text[pos] != ']') while (true) {
                        Value(route == 2 ? 3 : 4, depth + 1); White();
                        if (pos < text.Length && text[pos] == ',') { ++pos; continue; }
                        break;
                    }
                    Expect(']');
                } else if (text[pos] == '"') StringToken(false);
                else {
                    int start = pos;
                    while (pos < text.Length && !char.IsWhiteSpace(text[pos]) && text[pos] != ',' && text[pos] != ']' && text[pos] != '}') ++pos;
                    if (pos == start) throw new FormatException("Invalid JSON value.");
                }
            }
        }
    }

    public sealed class JournalRange {
        public int Lines;
        public long LastOrdinal = -1;
        public bool HasMetadata, EndsWithNewline;
    }
    public sealed class FileStamp {
        public string Identity;
        public long Length, WriteTicks;
    }
    public sealed class JournalLine {
        public int Number;
        public long Offset;
        public string Text;
    }
    public sealed class FixedSlot {
        public long Offset;
        public byte[] Before, After;
    }

    // File identity + verified prefix hashes permit tail parsing without trusting
    // timestamps as evidence that a growing file was only appended to.
    public static class IncrementalIo {
        [StructLayout(LayoutKind.Sequential)] private struct FileInfoNative {
            public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(IntPtr handle, out FileInfoNative info);
        public static FileStamp Stamp(string path) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                return Stamp(stream);
            }
        }
        private static FileStamp Stamp(FileStream stream) {
            FileInfoNative info;
            if (!GetFileInformationByHandle(stream.SafeFileHandle.DangerousGetHandle(), out info)) throw new IOException("Cannot identify history file.");
            return new FileStamp {
                Identity = info.Volume.ToString("x8") + ":" + info.IndexHigh.ToString("x8") + info.IndexLow.ToString("x8") + ":" + info.CreationHigh.ToString("x8") + info.CreationLow.ToString("x8"),
                Length = stream.Length,
                WriteTicks = DateTime.FromFileTimeUtc(unchecked((long)(((ulong)info.WriteHigh << 32) | info.WriteLow))).Ticks
            };
        }
        private static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        public static string HashPrefix(string path, long length) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1048576))
            using (var sha = SHA256.Create()) {
                if (length < 0 || length > stream.Length) throw new IOException("History prefix disappeared.");
                HashBytes(stream, sha, length);
                sha.TransformFinalBlock(new byte[0], 0, 0);
                return Hex(sha.Hash);
            }
        }
        private static void HashBytes(Stream stream, HashAlgorithm sha, long length) {
            if (length == 0) return;
            byte[] buffer = new byte[(int)Math.Min(1048576, length)];
            while (length > 0) {
                int read = stream.Read(buffer, 0, (int)Math.Min(buffer.Length, length));
                if (read == 0) throw new IOException("History shortened during validation.");
                sha.TransformBlock(buffer, 0, read, buffer, 0);
                length -= read;
            }
        }
        public static bool EndsWithNewline(string path) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                if (stream.Length == 0) return false;
                stream.Position = stream.Length - 1;
                return stream.ReadByte() == 10;
            }
        }
        public static IEnumerable<JournalLine> ReadLines(string path, long offset, int firstLine) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1048576, FileOptions.SequentialScan))
            using (var body = new MemoryStream()) {
                if (offset < 0 || offset > stream.Length) throw new IOException("Invalid journal start offset.");
                if (offset > 0) { stream.Position = offset - 1; if (stream.ReadByte() != 10) throw new IOException("Tail is not on a complete line boundary."); }
                stream.Position = offset;
                byte[] buffer = new byte[1048576];
                long position = offset, startOffset = offset; int number = firstLine, count;
                var utf8 = new UTF8Encoding(false, true);
                while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                    int start = 0;
                    for (int i = 0; i < count; ++i) {
                        if (buffer[i] != 10) continue;
                        body.Write(buffer, start, i - start);
                        yield return DecodeLine(body, utf8, ++number, startOffset);
                        body.SetLength(0); start = i + 1; startOffset = position + start;
                    }
                    body.Write(buffer, start, count - start); position += count;
                }
                if (body.Length > 0) yield return DecodeLine(body, utf8, ++number, startOffset);
            }
        }
        private static JournalLine DecodeLine(MemoryStream body, Encoding utf8, int number, long offset) {
            byte[] bytes = body.ToArray(); int start = 0, length = bytes.Length;
            if (number == 1 && offset == 0 && length >= 3 && bytes[0] == 239 && bytes[1] == 187 && bytes[2] == 191) { start = 3; length -= 3; offset += 3; }
            if (length > 0 && bytes[start + length - 1] == 13) --length;
            return new JournalLine { Number = number, Offset = offset, Text = utf8.GetString(bytes, start, length) };
        }
        public static FixedSlot[] BuildSlots(string path, long offset, int firstLine, PortableRecord[] records) {
            var wanted = new Dictionary<int, PortableRecord>(); var slots = new List<FixedSlot>();
            foreach (var record in records) wanted.Add(record.LineNumber, record);
            var utf8 = new UTF8Encoding(false, true); int found = 0;
            foreach (var line in ReadLines(path, offset, firstLine)) {
                PortableRecord record;
                if (!wanted.TryGetValue(line.Number, out record)) continue;
                if (record.Action != "clear_input_ids" || record.UnsupportedReason != null) throw new IOException("Unverified fixed-slot operation.");
                using (var sha = SHA256.Create())
                    if (Hex(sha.ComputeHash(utf8.GetBytes(line.Text))) != record.OldLineSha256) throw new IOException("Model record changed after scan.");
                var input = PortableHistory.Find(line.Text); PortableHistory.Validate(input);
                foreach (var slot in input) {
                    byte[] before = utf8.GetBytes(line.Text.Substring(slot.Start, slot.Length));
                    byte[] after = new byte[before.Length]; for (int i = 0; i < after.Length; ++i) after[i] = 32;
                    after[0] = 110; after[1] = 117; after[2] = 108; after[3] = 108;
                    slots.Add(new FixedSlot { Offset = line.Offset + utf8.GetByteCount(line.Text.Substring(0, slot.Start)), Before = before, After = after });
                }
                ++found;
            }
            if (found != wanted.Count || slots.Count == 0) throw new IOException("Fixed-slot records disappeared.");
            slots.Sort(delegate(FixedSlot a, FixedSlot b) { return a.Offset.CompareTo(b.Offset); });
            return slots.ToArray();
        }
        public static void SaveSlots(string path, FixedSlot[] slots) {
            using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.WriteThrough))
            using (var writer = new BinaryWriter(stream, Encoding.UTF8, true)) {
                writer.Write(0x43535031); writer.Write(slots.Length);
                foreach (var slot in slots) { writer.Write(slot.Offset); writer.Write(slot.Before.Length); writer.Write(slot.Before); writer.Write(slot.After); }
                writer.Flush(); stream.Flush(true);
            }
        }
        public static FixedSlot[] LoadSlots(string path) {
            using (var stream = File.OpenRead(path))
            using (var reader = new BinaryReader(stream)) {
                if (reader.ReadInt32() != 0x43535031) throw new IOException("Unknown fixed-slot backup format.");
                int count = reader.ReadInt32();
                if (count <= 0 || count > 1000000) throw new IOException("Invalid fixed-slot backup size.");
                var slots = new FixedSlot[count]; long end = 0;
                for (int i = 0; i < count; ++i) {
                    long offset = reader.ReadInt64(); int length = reader.ReadInt32();
                    if (offset < end || length < 4 || length > 1048576 || offset > long.MaxValue - length) throw new IOException("Invalid fixed-slot backup boundary.");
                    byte[] before = reader.ReadBytes(length), after = reader.ReadBytes(length);
                    if (before.Length != length || after.Length != length) throw new IOException("Incomplete fixed-slot backup.");
                    slots[i] = new FixedSlot { Offset = offset, Before = before, After = after }; end = offset + length;
                }
                if (stream.Position != stream.Length) throw new IOException("Unexpected fixed-slot backup suffix.");
                return slots;
            }
        }
        private static bool IsInterruptedSlot(byte[] actual, FixedSlot slot) {
            for (int i = 0; i < actual.Length; ++i)
                if (actual[i] != slot.Before[i] && actual[i] != slot.After[i]) return false;
            return true;
        }
        private static string VirtualHash(FileStream stream, FixedSlot[] slots, bool original) {
            stream.Position = 0;
            using (var sha = SHA256.Create()) {
                foreach (var slot in slots) {
                    if (slot.Offset < stream.Position || slot.Offset + slot.Before.Length > stream.Length) throw new IOException("Fixed-slot boundary no longer exists.");
                    HashBytes(stream, sha, slot.Offset - stream.Position);
                    byte[] actual = new byte[slot.Before.Length]; int used = 0;
                    while (used < actual.Length) { int read = stream.Read(actual, used, actual.Length - used); if (read == 0) throw new IOException("Incomplete history slot."); used += read; }
                    if (!IsInterruptedSlot(actual, slot)) throw new IOException("History slot changed outside this transaction.");
                    byte[] value = original ? slot.Before : slot.After;
                    sha.TransformBlock(value, 0, value.Length, value, 0);
                }
                HashBytes(stream, sha, stream.Length - stream.Position);
                sha.TransformFinalBlock(new byte[0], 0, 0); return Hex(sha.Hash);
            }
        }
        public static string RepairedHash(string path, FixedSlot[] slots) {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) return VirtualHash(stream, slots, false);
        }
        // Validate the entire normalized file before any write. Recovery accepts
        // a partially applied journal, but refuses unrelated edits or appends.
        public static void ApplySlots(string path, string backup, long length, string originalHash, string repairedHash, bool restore, int failAfter) {
            ApplySlots(path, backup, length, originalHash, repairedHash, restore, failAfter, null);
        }
        public static void ApplySlots(string path, string backup, long length, string originalHash, string repairedHash, bool restore, int failAfter, string identity) {
            var slots = LoadSlots(backup);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None, 65536, FileOptions.WriteThrough)) {
                if (identity != null && Stamp(stream).Identity != identity) throw new IOException("History file was replaced before fixed-slot access.");
                if (stream.Length != length || VirtualHash(stream, slots, true) != originalHash || VirtualHash(stream, slots, false) != repairedHash)
                    throw new IOException("History differs from the durable fixed-slot transaction.");
                int changed = 0;
                foreach (var slot in slots) {
                    byte[] value = restore ? slot.Before : slot.After;
                    stream.Position = slot.Offset; stream.Write(value, 0, value.Length);
                    if (failAfter > 0 && ++changed == failAfter) { stream.Flush(true); throw new IOException("Injected interrupted write."); }
                }
                stream.Flush(true);
            }
        }
    }
}
