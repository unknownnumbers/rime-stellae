// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class StellaeCandidateFontNative {
    [DllImport("dwrite.dll")]
    private static extern int DWriteCreateFactory(int type, ref Guid iid, out IntPtr factory);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern int AddFontResourceEx(string path, uint flags, IntPtr reserved);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    private static extern bool RemoveFontResourceEx(string path, uint flags, IntPtr reserved);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam,
        IntPtr lParam, uint flags, uint milliseconds, out IntPtr result);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetFontCollection(IntPtr factory, out IntPtr collection, int refresh);
    [UnmanagedFunctionPointer(CallingConvention.StdCall, CharSet = CharSet.Unicode)]
    private delegate int FindFamily(IntPtr collection, string family, out uint index, out int exists);

    private static T Method<T>(IntPtr instance, int index) where T : class {
        IntPtr pointer = Marshal.ReadIntPtr(Marshal.ReadIntPtr(instance), index * IntPtr.Size);
        return Marshal.GetDelegateForFunctionPointer(pointer, typeof(T)) as T;
    }

    public static string[] GetMissingFamilies(string[] families) {
        var iid = new Guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");
        IntPtr factory, collection = IntPtr.Zero;
        Marshal.ThrowExceptionForHR(DWriteCreateFactory(0, ref iid, out factory));
        try {
            var getCollection = Method<GetFontCollection>(factory, 3);
            Marshal.ThrowExceptionForHR(getCollection(factory, out collection, 1));
            var lookup = Method<FindFamily>(collection, 5);
            var missing = new List<string>();
            foreach (string family in families) {
                uint index;
                int exists;
                Marshal.ThrowExceptionForHR(lookup(collection, family, out index, out exists));
                if (exists == 0) missing.Add(family);
            }
            return missing.ToArray();
        } finally {
            if (collection != IntPtr.Zero) Marshal.Release(collection);
            Marshal.Release(factory);
        }
    }

    public static bool HasFontFamily(string family) {
        return GetMissingFamilies(new[] { family }).Length == 0;
    }

    public static bool LoadFont(string path) {
        return AddFontResourceEx(path, 0, IntPtr.Zero) > 0;
    }

    public static bool UnloadFont(string path) {
        return RemoveFontResourceEx(path, 0, IntPtr.Zero);
    }

    public static void NotifyFontChange() {
        IntPtr result;
        SendMessageTimeout(new IntPtr(0xFFFF), 0x001D, IntPtr.Zero, IntPtr.Zero, 2, 500, out result);
    }
}
