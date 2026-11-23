// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// Isolated capability probe; API pointer offsets account for pointer alignment.
public static class RimeProbe {
    const string Dll = @"__RIME_ENGINE_DLL__";
    [StructLayout(LayoutKind.Sequential)] public struct Traits {
        public int data_size;
        public IntPtr shared_data_dir,user_data_dir,distribution_name,distribution_code_name,distribution_version,app_name,modules;
        public int min_log_level;
        public IntPtr log_dir,prebuilt_data_dir,staging_dir;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Composition {
        public int length,cursor_pos,sel_start,sel_end; public IntPtr preedit;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Menu {
        public int page_size,page_no,is_last_page,highlighted_candidate_index,num_candidates;
        public IntPtr candidates,select_keys;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Context {
        public int data_size; public Composition composition; public Menu menu;
        public IntPtr commit_text_preview,select_labels;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Candidate {
        public IntPtr text,comment,reserved;
    }
    [StructLayout(LayoutKind.Sequential)] public struct Commit { public int data_size; public IntPtr text; }
    [StructLayout(LayoutKind.Sequential)] public struct Iterator {
        public IntPtr ptr; public int index; public Candidate candidate;
    }
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeSetup(ref Traits traits);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeInitialize(ref Traits traits);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeDeployerInitialize(ref Traits traits);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeFinalize();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeDeployWorkspace();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeDeploySchema([MarshalAs(UnmanagedType.LPStr)]string file);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern UIntPtr RimeCreateSession();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeDestroySession(UIntPtr session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeSelectSchema(UIntPtr session,[MarshalAs(UnmanagedType.LPStr)]string schema);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeGetCurrentSchema(UIntPtr session,byte[] schema,UIntPtr size);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeProcessKey(UIntPtr session,int key,int mask);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeClearComposition(UIntPtr session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeCommitComposition(UIntPtr session);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeGetContext(UIntPtr session,ref Context context);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeFreeContext(ref Context context);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeCandidateListBegin(UIntPtr session,ref Iterator iterator);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeCandidateListNext(ref Iterator iterator);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeCandidateListEnd(ref Iterator iterator);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern void RimeSetOption(UIntPtr session,[MarshalAs(UnmanagedType.LPStr)]string option,int value);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeGetOption(UIntPtr session,[MarshalAs(UnmanagedType.LPStr)]string option);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeGetCommit(UIntPtr session,ref Commit commit);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeFreeCommit(ref Commit commit);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr rime_get_api();
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr RimeFindModule([MarshalAs(UnmanagedType.LPStr)]string module);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetVersion();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int SelectCandidateFunc(UIntPtr session,UIntPtr index);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetInputFunc(UIntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate UIntPtr GetCaretFunc(UIntPtr session);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void SetCaretFunc(UIntPtr session, UIntPtr position);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetModuleApiFunc();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int ExportUserDictFunc([MarshalAs(UnmanagedType.LPStr)]string name,[MarshalAs(UnmanagedType.LPStr)]string path);
    [DllImport(Dll,CallingConvention=CallingConvention.Cdecl)] public static extern int RimeGetProperty(UIntPtr session,[MarshalAs(UnmanagedType.LPStr)]string name,byte[] value,UIntPtr size);
    static string Utf8(IntPtr p) {
        if(p==IntPtr.Zero)return null;
        int n=0; while(Marshal.ReadByte(p,n)!=0)n++;
        byte[] b=new byte[n]; Marshal.Copy(p,b,0,n); return Encoding.UTF8.GetString(b);
    }
    public static string Version() {
        // get_version is function pointer number 72; first pointer is pointer-aligned.
        IntPtr p = rime_get_api();
        IntPtr f = Marshal.ReadIntPtr(p,IntPtr.Size+72*IntPtr.Size);
        return Utf8(((GetVersion)Marshal.GetDelegateForFunctionPointer(f,typeof(GetVersion)))());
    }
    public static int ExportUserDict(string name,string path) {
        IntPtr module=RimeFindModule("levers");
        if(module==IntPtr.Zero)throw new InvalidOperationException("Levers module unavailable");
        int moduleOffset=IntPtr.Size+3*IntPtr.Size;
        if(Marshal.ReadInt32(module)+4<moduleOffset+IntPtr.Size)throw new InvalidOperationException("Levers module API missing");
        IntPtr getApi=Marshal.ReadIntPtr(module,moduleOffset);
        if(getApi==IntPtr.Zero)throw new InvalidOperationException("Levers get_api is null");
        IntPtr api=((GetModuleApiFunc)Marshal.GetDelegateForFunctionPointer(getApi,typeof(GetModuleApiFunc)))();
        if(api==IntPtr.Zero)throw new InvalidOperationException("Levers API is null");
        int exportOffset=IntPtr.Size+29*IntPtr.Size;
        if(Marshal.ReadInt32(api)+4<exportOffset+IntPtr.Size)throw new InvalidOperationException("Export API missing");
        IntPtr export=Marshal.ReadIntPtr(api,exportOffset);
        if(export==IntPtr.Zero)throw new InvalidOperationException("Levers export is null");
        return ((ExportUserDictFunc)Marshal.GetDelegateForFunctionPointer(export,typeof(ExportUserDictFunc)))(name,path);
    }
    public static int SelectCandidate(UIntPtr session,int index) {
        IntPtr f=Marshal.ReadIntPtr(rime_get_api(),IntPtr.Size+71*IntPtr.Size);
        return ((SelectCandidateFunc)Marshal.GetDelegateForFunctionPointer(f,typeof(SelectCandidateFunc)))(session,new UIntPtr((uint)index));
    }
    public static string Input(UIntPtr session) {
        IntPtr f=Marshal.ReadIntPtr(rime_get_api(),IntPtr.Size+69*IntPtr.Size);
        return Utf8(((GetInputFunc)Marshal.GetDelegateForFunctionPointer(f,typeof(GetInputFunc)))(session));
    }
    public static string ReadCommit(UIntPtr session) {
        Commit c=new Commit(); c.data_size=Marshal.SizeOf(typeof(Commit))-4;
        if(RimeGetCommit(session,ref c)==0)return null;
        string result=Utf8(c.text); RimeFreeCommit(ref c); return result;
    }
    public static int Caret(UIntPtr session) {
        IntPtr f=Marshal.ReadIntPtr(rime_get_api(),IntPtr.Size+70*IntPtr.Size);
        return (int)((GetCaretFunc)Marshal.GetDelegateForFunctionPointer(f,typeof(GetCaretFunc)))(session).ToUInt32();
    }
    public static void SetCaret(UIntPtr session,int position) {
        IntPtr f=Marshal.ReadIntPtr(rime_get_api(),IntPtr.Size+73*IntPtr.Size);
        ((SetCaretFunc)Marshal.GetDelegateForFunctionPointer(f,typeof(SetCaretFunc)))(session,new UIntPtr((uint)position));
    }
    public static string Property(UIntPtr session,string name) {
        var value=new byte[16384];
        if(RimeGetProperty(session,name,value,new UIntPtr((uint)value.Length))==0)return null;
        int length=Array.IndexOf(value,(byte)0);
        return Encoding.UTF8.GetString(value,0,length<0?value.Length:length);
    }
    public static object Snapshot(UIntPtr session,int limit) {
        Context c=new Context(); c.data_size=Marshal.SizeOf(typeof(Context))-4;
        string preedit=null,preview=null; int length=0,cursor=0,highlightedIndex=-1;
        if(RimeGetContext(session,ref c)!=0) {
            preedit=Utf8(c.composition.preedit); preview=Utf8(c.commit_text_preview);
            length=c.composition.length; cursor=c.composition.cursor_pos;
            if(c.menu.num_candidates>0)highlightedIndex=c.menu.page_no*c.menu.page_size+c.menu.highlighted_candidate_index;
            RimeFreeContext(ref c);
        }
        List<string> candidates=new List<string>(); List<string> comments=new List<string>(); Iterator it=new Iterator();
        if(RimeCandidateListBegin(session,ref it)!=0) {
            try { while(candidates.Count<limit && RimeCandidateListNext(ref it)!=0) { candidates.Add(Utf8(it.candidate.text)); comments.Add(Utf8(it.candidate.comment)); } }
            finally { RimeCandidateListEnd(ref it); }
        }
        return new {Preedit=preedit,Preview=preview,Length=length,Cursor=cursor,HighlightedIndex=highlightedIndex,Candidates=candidates,Comments=comments};
    }
}
