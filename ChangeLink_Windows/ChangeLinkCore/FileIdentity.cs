using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace ChangeLinkCore
{
    /// <summary>
    /// A stable identity for a file or folder, independent of its path. On NTFS this is the
    /// volume serial number plus the MFT file-index pair, read through the same Win32 call
    /// Windows Explorer and backup tools use (<c>GetFileInformationByHandle</c>). This is the
    /// direct analogue of <c>URLResourceValues.fileResourceIdentifier</c> on macOS: it survives
    /// a rename or a move to another folder on the same volume, which is exactly what the
    /// comparator needs to tell a rename/move apart from a delete followed by a create.
    ///
    /// When the handle can't be opened (permissions, a locked file, a non-NTFS volume, or
    /// running on a non-Windows platform for local testing), the identity falls back to the
    /// file's path, same as the macOS build's own fallback -- that fallback is not a stable
    /// identity across moves, only a placeholder so the scan does not fail outright.
    /// </summary>
    public static class FileIdentity
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_READ_ATTRIBUTES = 0x0080;
        private const uint FILE_SHARE_READ = 0x1;
        private const uint FILE_SHARE_WRITE = 0x2;
        private const uint FILE_SHARE_DELETE = 0x4;
        private const uint OPEN_EXISTING = 3;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandleWrapper CreateFileW(
            string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
            uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandleWrapper hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private sealed class SafeFileHandleWrapper : Microsoft.Win32.SafeHandles.SafeHandleZeroOrMinusOneIsInvalid
        {
            public SafeFileHandleWrapper() : base(true) { }
            protected override bool ReleaseHandle() => CloseHandle(handle);
        }

        /// <summary>
        /// Returns a stable identity string for the item at <paramref name="path"/> (a folder
        /// or a file), or a path-derived fallback if the real identity can't be read.
        /// </summary>
        public static string Resolve(string path)
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                try
                {
                    var id = ResolveWindows(path);
                    if (id != null) return id;
                }
                catch
                {
                    // Fall through to the path-based fallback below.
                }
            }
            return "path:" + System.IO.Path.GetFullPath(path);
        }

        [SupportedOSPlatform("windows")]
        private static string? ResolveWindows(string path)
        {
            var handle = CreateFileW(
                path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) return null;
            using (handle)
            {
                if (!GetFileInformationByHandle(handle, out var info)) return null;
                ulong fileIndex = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
                return $"ntfs:{info.VolumeSerialNumber:x8}:{fileIndex:x16}";
            }
        }
    }
}
