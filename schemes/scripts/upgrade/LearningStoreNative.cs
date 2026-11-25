// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class StellaeLearningStoreNative {
  [StructLayout(LayoutKind.Sequential)]
  struct Traits {
    public int data_size;
    public IntPtr shared_data_dir, user_data_dir, distribution_name, distribution_code_name;
    public IntPtr distribution_version, app_name, modules;
    public int min_log_level;
    public IntPtr log_dir, prebuilt_data_dir, staging_dir;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
  [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
  static extern IntPtr GetProcAddress(IntPtr module, string name);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Setup(ref Traits traits);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void Initialize(IntPtr traits);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void FinalizeEngine();

  static IntPtr Utf8(string value) {
    byte[] bytes=Encoding.UTF8.GetBytes(value+"\0");
    IntPtr result=Marshal.AllocHGlobal(bytes.Length);
    Marshal.Copy(bytes,0,result,bytes.Length);
    return result;
  }
  static Delegate Export(IntPtr module, string name, Type type) {
    IntPtr entry=GetProcAddress(module,name);
    if(entry==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"Missing native API: "+name);
    return Marshal.GetDelegateForFunctionPointer(entry,type);
  }

  // The caller supplies a dedicated offline clone containing only its generated
  // rime.lua. No input session or normal profile configuration is loaded.
  public static void Run(string engineDirectory, string cloneDirectory) {
    string root=Path.GetFullPath(cloneDirectory);
    if(!File.Exists(Path.Combine(root,"rime.lua")))throw new InvalidOperationException("Offline clone script is missing.");
    IntPtr module=LoadLibraryEx(Path.Combine(Path.GetFullPath(engineDirectory),"rime.dll"),IntPtr.Zero,0x1100);
    if(module==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot load the installed input engine.");
    Traits traits=new Traits();
    IntPtr defaultModule=IntPtr.Zero, leverModule=IntPtr.Zero, luaModule=IntPtr.Zero;
    bool initialized=false;
    try {
      traits.data_size=Marshal.SizeOf(typeof(Traits))-sizeof(int);
      traits.shared_data_dir=Utf8(root); traits.user_data_dir=Utf8(root);
      traits.log_dir=Utf8(Path.Combine(root,"logs"));
      traits.prebuilt_data_dir=Utf8(Path.Combine(root,"empty"));
      traits.staging_dir=Utf8(Path.Combine(root,"build"));
      traits.app_name=Utf8("rime.stellae.offline_learning_upgrade");
      traits.min_log_level=2;
      defaultModule=Utf8("default"); leverModule=Utf8("levers"); luaModule=Utf8("lua");
      traits.modules=Marshal.AllocHGlobal(IntPtr.Size*4);
      Marshal.WriteIntPtr(traits.modules,0,defaultModule);
      Marshal.WriteIntPtr(traits.modules,IntPtr.Size,leverModule);
      Marshal.WriteIntPtr(traits.modules,IntPtr.Size*2,luaModule);
      Marshal.WriteIntPtr(traits.modules,IntPtr.Size*3,IntPtr.Zero);
      ((Setup)Export(module,"RimeSetup",typeof(Setup)))(ref traits);
      initialized=true;
      ((Initialize)Export(module,"RimeInitialize",typeof(Initialize)))(IntPtr.Zero);
    } finally {
      if(initialized)((FinalizeEngine)Export(module,"RimeFinalize",typeof(FinalizeEngine)))();
      foreach(IntPtr pointer in new IntPtr[] {traits.shared_data_dir,traits.user_data_dir,traits.log_dir,
          traits.prebuilt_data_dir,traits.staging_dir,traits.app_name,traits.modules,
          defaultModule,leverModule,luaModule}) {
        if(pointer!=IntPtr.Zero)Marshal.FreeHGlobal(pointer);
      }
      // This host is a short-lived child process. Keep the native plugin DLL
      // loaded through process exit, as normal Rime hosts do; unloading its
      // C++ registries manually can race deferred native destruction.
    }
  }
}
