using System.Buffers;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace Hv2Pve.Rct;

internal static class Program
{
    private const uint ErrorSuccess = 0;
    private const uint ErrorMoreData = 234;
    private const uint VirtualDiskAccessNone = 0x00000000;
    private const uint VirtualDiskAccessAttachRo = 0x00010000;
    private const uint VirtualDiskAccessDetach = 0x00040000;
    private const uint VirtualDiskAccessGetInfo = 0x00080000;
    private const uint OpenVirtualDiskFlagNone = 0;
    private const uint AttachVirtualDiskFlagReadOnly = 0x1;
    private const uint AttachVirtualDiskFlagNoDriveLetter = 0x2;
    private const uint AttachVirtualDiskFlagPermanentLifetime = 0x4;
    private const uint DetachVirtualDiskFlagNone = 0;
    private const int GetVirtualDiskInfoSize = 1;
    private const int GetVirtualDiskInfoChangeTrackingState = 15;
    private const uint QueryChangesVirtualDiskFlagNone = 0;
    private const int RangeBatchSize = 4096;
    private static readonly Guid MicrosoftVirtualDiskVendor = new("EC984AEC-A0F9-47E9-901F-71415A66345B");

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
    };

    private static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.Error.WriteLine("Hv2Pve.Rct must run on Windows.");
            return 2;
        }

        try
        {
            if (args.Length == 0)
            {
                PrintUsage();
                return 2;
            }

            var command = args[0].ToLowerInvariant();
            var options = ParseOptions(args.Skip(1).ToArray());
            return command switch
            {
                "info" => RunInfo(options),
                "query" => RunQuery(options),
                "attach" => RunAttach(options),
                "detach" => RunDetach(options),
                "pack" => RunPack(options),
                _ => throw new ArgumentException($"Unknown command: {command}"),
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"ERROR: {ex.Message}");
            return 1;
        }
    }

    private static int RunInfo(Dictionary<string, string> options)
    {
        var disk = Require(options, "disk");
        using var handle = OpenDisk(disk, VirtualDiskAccessGetInfo, readOnly: true, getInfoOnly: true);
        var size = GetDiskSize(handle);
        var tracking = GetChangeTrackingState(handle);
        var result = new
        {
            disk = Path.GetFullPath(disk),
            virtual_size = size.VirtualSize,
            physical_size = size.PhysicalSize,
            block_size = size.BlockSize,
            sector_size = size.SectorSize,
            rct_enabled = tracking.Enabled,
            newer_changes = tracking.NewerChanges,
            most_recent_rct_id = tracking.MostRecentId,
        };
        Console.WriteLine(JsonSerializer.Serialize(result, JsonOptions));
        return 0;
    }

    private static int RunQuery(Dictionary<string, string> options)
    {
        var disk = Require(options, "disk");
        var rctId = Require(options, "rct-id");
        var output = Require(options, "output");

        using var handle = OpenDisk(disk, VirtualDiskAccessGetInfo, readOnly: true, getInfoOnly: true);
        var size = GetDiskSize(handle);
        var ranges = QueryChangedRanges(handle, rctId, size.VirtualSize);
        ValidateRanges(ranges, size.VirtualSize);

        var result = new RangesDocument(
            1,
            Path.GetFullPath(disk),
            rctId,
            size.VirtualSize,
            ranges,
            DateTimeOffset.UtcNow.ToString("O"));
        WriteJsonAtomic(output, result);
        Console.WriteLine(output);
        return 0;
    }

    private static int RunAttach(Dictionary<string, string> options)
    {
        var disk = Require(options, "disk");
        using var handle = OpenDisk(
            disk,
            VirtualDiskAccessAttachRo | VirtualDiskAccessGetInfo,
            readOnly: true,
            getInfoOnly: false);

        var parameters = new AttachVirtualDiskParameters
        {
            Version = 1,
            Reserved = 0,
        };
        var flags = AttachVirtualDiskFlagReadOnly |
                    AttachVirtualDiskFlagNoDriveLetter |
                    AttachVirtualDiskFlagPermanentLifetime;
        CheckWin32(Native.AttachVirtualDisk(handle, IntPtr.Zero, flags, 0, ref parameters, IntPtr.Zero), "AttachVirtualDisk");
        var physicalPath = GetPhysicalPath(handle);
        Console.WriteLine(physicalPath);
        return 0;
    }

    private static int RunDetach(Dictionary<string, string> options)
    {
        var disk = Require(options, "disk");
        using var handle = OpenDisk(disk, VirtualDiskAccessDetach, readOnly: true, getInfoOnly: false);
        CheckWin32(Native.DetachVirtualDisk(handle, DetachVirtualDiskFlagNone, 0), "DetachVirtualDisk");
        return 0;
    }

    private static int RunPack(Dictionary<string, string> options)
    {
        var sourceRaw = Require(options, "source-raw");
        var rangesPath = Require(options, "ranges");
        var payloadPath = Require(options, "payload");
        var metadataPath = Require(options, "metadata");
        var migrationId = Require(options, "migration-id");
        var diskId = Require(options, "disk-id");
        var referenceFrom = Require(options, "reference-from");
        var referenceTo = Require(options, "reference-to");
        if (!ulong.TryParse(Require(options, "sequence"), out var sequence))
            throw new ArgumentException("--sequence must be an unsigned integer");

        var rangesDoc = JsonSerializer.Deserialize<RangesDocument>(File.ReadAllText(rangesPath), JsonOptions)
            ?? throw new InvalidDataException("Could not parse ranges document");
        ValidateRanges(rangesDoc.Ranges, rangesDoc.VirtualSize);
        var metadata = PackRanges(
            sourceRaw,
            rangesDoc,
            payloadPath,
            migrationId,
            diskId,
            sequence,
            referenceFrom,
            referenceTo);
        WriteJsonAtomic(metadataPath, metadata);
        Console.WriteLine(metadataPath);
        return 0;
    }

    private static DeltaMetadata PackRanges(
        string sourceRaw,
        RangesDocument rangesDoc,
        string payloadPath,
        string migrationId,
        string diskId,
        ulong sequence,
        string referenceFrom,
        string referenceTo)
    {
        var payloadDir = Path.GetDirectoryName(Path.GetFullPath(payloadPath));
        if (!string.IsNullOrEmpty(payloadDir)) Directory.CreateDirectory(payloadDir);
        var tempPayload = payloadPath + ".tmp-" + Guid.NewGuid().ToString("N");
        var entries = new List<DeltaRangeMetadata>();
        ulong payloadOffset = 0;

        try
        {
            using var input = new FileStream(
                sourceRaw,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete,
                1024 * 1024,
                FileOptions.SequentialScan);
            using var output = new FileStream(
                tempPayload,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                1024 * 1024,
                FileOptions.SequentialScan);

            foreach (var range in rangesDoc.Ranges)
            {
                input.Seek(checked((long)range.Offset), SeekOrigin.Begin);
                using var rangeHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                ulong remaining = range.Length;
                var buffer = ArrayPool<byte>.Shared.Rent(1024 * 1024);
                try
                {
                    while (remaining > 0)
                    {
                        var requested = (int)Math.Min((ulong)buffer.Length, remaining);
                        var read = input.Read(buffer, 0, requested);
                        if (read <= 0)
                            throw new EndOfStreamException($"Source raw device ended inside range offset={range.Offset} length={range.Length}");
                        output.Write(buffer, 0, read);
                        rangeHash.AppendData(buffer, 0, read);
                        remaining -= (ulong)read;
                    }
                }
                finally
                {
                    ArrayPool<byte>.Shared.Return(buffer);
                }

                entries.Add(new DeltaRangeMetadata(
                    range.Offset,
                    range.Length,
                    payloadOffset,
                    Convert.ToHexString(rangeHash.GetHashAndReset()).ToLowerInvariant()));
                payloadOffset += range.Length;
            }
            output.Flush(true);
            File.Move(tempPayload, payloadPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(tempPayload)) File.Delete(tempPayload);
        }

        var payloadSha = Sha256File(payloadPath);
        return new DeltaMetadata(
            1,
            migrationId,
            diskId,
            rangesDoc.VirtualSize,
            sequence,
            referenceFrom,
            referenceTo,
            entries,
            payloadOffset,
            payloadSha,
            DateTimeOffset.UtcNow.ToString("O"));
    }

    private static List<ChangedRange> QueryChangedRanges(SafeFileHandle handle, string rctId, ulong virtualSize)
    {
        var results = new List<ChangedRange>();
        ulong cursor = 0;
        var buffer = new QueryChangesVirtualDiskRange[RangeBatchSize];

        while (cursor < virtualSize)
        {
            uint rangeCount = RangeBatchSize;
            var remaining = virtualSize - cursor;
            var rc = Native.QueryChangesVirtualDisk(
                handle,
                rctId,
                cursor,
                remaining,
                QueryChangesVirtualDiskFlagNone,
                buffer,
                ref rangeCount,
                out var processedLength);

            if (rc != ErrorSuccess && rc != ErrorMoreData)
                CheckWin32(rc, "QueryChangesVirtualDisk");

            for (var i = 0; i < rangeCount; i++)
            {
                results.Add(new ChangedRange(buffer[i].ByteOffset, buffer[i].ByteLength));
            }

            if (processedLength == 0)
            {
                if (rc == ErrorSuccess) break;
                throw new InvalidOperationException("QueryChangesVirtualDisk returned no processed length while more data remained");
            }

            cursor = checked(cursor + processedLength);
            if (rc == ErrorSuccess && cursor >= virtualSize) break;
        }

        return results
            .Where(r => r.Length > 0)
            .OrderBy(r => r.Offset)
            .ToList();
    }

    private static void ValidateRanges(IReadOnlyList<ChangedRange> ranges, ulong virtualSize)
    {
        ulong previousEnd = 0;
        var first = true;
        foreach (var range in ranges.OrderBy(r => r.Offset))
        {
            if (range.Length == 0) throw new InvalidDataException("Changed range length cannot be zero");
            var end = checked(range.Offset + range.Length);
            if (end > virtualSize) throw new InvalidDataException("Changed range extends past virtual disk size");
            if (!first && range.Offset < previousEnd) throw new InvalidDataException("Changed ranges overlap");
            previousEnd = end;
            first = false;
        }
    }

    private static SafeFileHandle OpenDisk(string path, uint access, bool readOnly, bool getInfoOnly)
    {
        var storageType = new VirtualStorageType
        {
            DeviceId = DeviceIdForPath(path),
            VendorId = MicrosoftVirtualDiskVendor,
        };
        var parameters = new OpenVirtualDiskParametersV2
        {
            Version = 2,
            GetInfoOnly = getInfoOnly,
            ReadOnly = readOnly,
            ResiliencyGuid = Guid.Empty,
        };
        var rc = Native.OpenVirtualDisk(ref storageType, path, access, OpenVirtualDiskFlagNone, ref parameters, out var handle);
        CheckWin32(rc, "OpenVirtualDisk");
        return handle;
    }

    private static uint DeviceIdForPath(string path)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        return ext switch
        {
            ".vhd" => 2,
            ".avhd" => 2,
            ".vhdx" => 3,
            ".avhdx" => 3,
            ".vhds" => 4,
            _ => 0,
        };
    }

    private static DiskSizeInfo GetDiskSize(SafeFileHandle handle)
    {
        const uint bytes = 128;
        var ptr = Marshal.AllocHGlobal((int)bytes);
        try
        {
            Span<byte> zero = new byte[(int)bytes];
            Marshal.Copy(zero.ToArray(), 0, ptr, (int)bytes);
            Marshal.WriteInt32(ptr, GetVirtualDiskInfoSize);
            var size = bytes;
            uint used = 0;
            CheckWin32(Native.GetVirtualDiskInformation(handle, ref size, ptr, ref used), "GetVirtualDiskInformation(size)");
            return new DiskSizeInfo(
                checked((ulong)Marshal.ReadInt64(ptr, 8)),
                checked((ulong)Marshal.ReadInt64(ptr, 16)),
                checked((uint)Marshal.ReadInt32(ptr, 24)),
                checked((uint)Marshal.ReadInt32(ptr, 28)));
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    private static ChangeTrackingInfo GetChangeTrackingState(SafeFileHandle handle)
    {
        uint bytes = 64 * 1024;
        var ptr = Marshal.AllocHGlobal((int)bytes);
        try
        {
            var zero = new byte[(int)bytes];
            Marshal.Copy(zero, 0, ptr, zero.Length);
            Marshal.WriteInt32(ptr, GetVirtualDiskInfoChangeTrackingState);
            uint used = 0;
            CheckWin32(Native.GetVirtualDiskInformation(handle, ref bytes, ptr, ref used), "GetVirtualDiskInformation(change-tracking)");
            var enabled = Marshal.ReadInt32(ptr, 8) != 0;
            var newer = Marshal.ReadInt32(ptr, 12) != 0;
            var id = Marshal.PtrToStringUni(IntPtr.Add(ptr, 16)) ?? string.Empty;
            return new ChangeTrackingInfo(enabled, newer, id);
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    private static string GetPhysicalPath(SafeFileHandle handle)
    {
        uint bytes = 0;
        _ = Native.GetVirtualDiskPhysicalPath(handle, ref bytes, null);
        if (bytes == 0) bytes = 1024;
        var builder = new StringBuilder(checked((int)(bytes / 2 + 2)));
        CheckWin32(Native.GetVirtualDiskPhysicalPath(handle, ref bytes, builder), "GetVirtualDiskPhysicalPath");
        return builder.ToString();
    }

    private static string Sha256File(string path)
    {
        using var stream = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    private static void WriteJsonAtomic<T>(string path, T value)
    {
        var full = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        var temp = full + ".tmp-" + Guid.NewGuid().ToString("N");
        File.WriteAllText(temp, JsonSerializer.Serialize(value, JsonOptions) + Environment.NewLine, new UTF8Encoding(false));
        File.Move(temp, full, true);
    }

    private static Dictionary<string, string> ParseOptions(string[] args)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var i = 0; i < args.Length; i++)
        {
            var token = args[i];
            if (!token.StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException($"Unexpected argument: {token}");
            var name = token[2..];
            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                throw new ArgumentException($"Missing value for {token}");
            result[name] = args[++i];
        }
        return result;
    }

    private static string Require(Dictionary<string, string> options, string name)
    {
        if (!options.TryGetValue(name, out var value) || string.IsNullOrWhiteSpace(value))
            throw new ArgumentException($"--{name} is required");
        return value;
    }

    private static void CheckWin32(uint rc, string operation)
    {
        if (rc == ErrorSuccess) return;
        throw new Win32Exception(checked((int)rc), $"{operation} failed with Win32 error {rc}");
    }

    private static void PrintUsage()
    {
        Console.Error.WriteLine("""
Hv2Pve.Rct
  info   --disk PATH
  query  --disk PATH --rct-id ID --output ranges.json
  attach --disk PATH
  detach --disk PATH
  pack   --source-raw \\.\PhysicalDriveN --ranges ranges.json --payload delta.bin --metadata delta.json
         --migration-id ID --disk-id ID --sequence N --reference-from ID --reference-to ID
""");
    }

    private sealed record RangesDocument(
        int FormatVersion,
        string Disk,
        string RctId,
        ulong VirtualSize,
        List<ChangedRange> Ranges,
        string CreatedAtUtc);

    private sealed record ChangedRange(ulong Offset, ulong Length);
    private sealed record DiskSizeInfo(ulong VirtualSize, ulong PhysicalSize, uint BlockSize, uint SectorSize);
    private sealed record ChangeTrackingInfo(bool Enabled, bool NewerChanges, string MostRecentId);
    private sealed record DeltaRangeMetadata(ulong Offset, ulong Length, ulong PayloadOffset, string Sha256);
    private sealed record DeltaMetadata(
        int FormatVersion,
        string MigrationId,
        string DiskId,
        ulong VirtualSize,
        ulong Sequence,
        string ReferenceFrom,
        string ReferenceTo,
        List<DeltaRangeMetadata> Ranges,
        ulong PayloadSize,
        string PayloadSha256,
        string CreatedAtUtc);

    [StructLayout(LayoutKind.Sequential)]
    private struct VirtualStorageType
    {
        public uint DeviceId;
        public Guid VendorId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct OpenVirtualDiskParametersV2
    {
        public int Version;
        [MarshalAs(UnmanagedType.Bool)] public bool GetInfoOnly;
        [MarshalAs(UnmanagedType.Bool)] public bool ReadOnly;
        public Guid ResiliencyGuid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct AttachVirtualDiskParameters
    {
        public int Version;
        public uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct QueryChangesVirtualDiskRange
    {
        public ulong ByteOffset;
        public ulong ByteLength;
        public ulong Reserved;
    }

    private static class Native
    {
        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern uint OpenVirtualDisk(
            ref VirtualStorageType virtualStorageType,
            string path,
            uint virtualDiskAccessMask,
            uint flags,
            ref OpenVirtualDiskParametersV2 parameters,
            out SafeFileHandle handle);

        [DllImport("virtdisk.dll", SetLastError = false)]
        internal static extern uint GetVirtualDiskInformation(
            SafeFileHandle virtualDiskHandle,
            ref uint virtualDiskInfoSize,
            IntPtr virtualDiskInfo,
            ref uint sizeUsed);

        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern uint QueryChangesVirtualDisk(
            SafeFileHandle virtualDiskHandle,
            string changeTrackingId,
            ulong byteOffset,
            ulong byteLength,
            uint flags,
            [Out] QueryChangesVirtualDiskRange[] ranges,
            ref uint rangeCount,
            out ulong processedLength);

        [DllImport("virtdisk.dll", SetLastError = false)]
        internal static extern uint AttachVirtualDisk(
            SafeFileHandle virtualDiskHandle,
            IntPtr securityDescriptor,
            uint flags,
            uint providerSpecificFlags,
            ref AttachVirtualDiskParameters parameters,
            IntPtr overlapped);

        [DllImport("virtdisk.dll", SetLastError = false)]
        internal static extern uint DetachVirtualDisk(
            SafeFileHandle virtualDiskHandle,
            uint flags,
            uint providerSpecificFlags);

        [DllImport("virtdisk.dll", CharSet = CharSet.Unicode, SetLastError = false)]
        internal static extern uint GetVirtualDiskPhysicalPath(
            SafeFileHandle virtualDiskHandle,
            ref uint diskPathSizeInBytes,
            StringBuilder? diskPath);
    }
}
