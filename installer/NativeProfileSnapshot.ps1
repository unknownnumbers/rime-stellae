#Requires -Version 5.1
param([string]$OutputFile,[switch]$LibraryOnly)
$ErrorActionPreference='Stop'

if(-not ('StellaeInstallerProfileProbe.NativeSnapshot' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace StellaeInstallerProfileProbe {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  internal struct LayoutProfile {
    public uint Type;
    public ushort Language;
    public Guid ClassId;
    public Guid ProfileId;
    public Guid Category;
    public uint Substitute;
    public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Id;
  }

  [StructLayout(LayoutKind.Sequential)]
  internal struct ProcessorProfile {
    public uint Type;
    public ushort Language;
    public Guid ClassId;
    public Guid ProfileId;
    public Guid Category;
    public IntPtr SubstituteLayout;
    public uint Capabilities;
    public IntPtr Layout;
    public uint Flags;
  }

  [ComImport]
  [Guid("71C6E74C-0F28-11D8-A82A-00065B84435C")]
  [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  internal interface IProfileManager {
    // Required vtable slots; this read-only probe never calls these methods.
    [PreserveSig]
    int ReservedActivate(uint type, ushort language, ref Guid classId,
      ref Guid profileId, IntPtr layout, uint flags);
    [PreserveSig]
    int ReservedDeactivate(uint type, ushort language, ref Guid classId,
      ref Guid profileId, IntPtr layout, uint flags);
    [PreserveSig]
    int GetProfile(uint type, ushort language, ref Guid classId,
      ref Guid profileId, IntPtr layout, out ProcessorProfile profile);
  }

  public sealed class ProfileRow {
    public string Id;
    public uint Type;
    public string Language;
    public uint Flags;
    public bool EnabledBySetting;
    public string ClassId;
    public string ProfileId;
    public string EnumeratedSubstitute;
    public string QueryHResult;
    public bool QuerySucceeded;
    public string TipSubstituteLayout;
    public uint? TipFlags;
    public bool? TipEnabled;
    public bool? TipSubstituted;
  }

  public static class NativeSnapshot {
    [DllImport("input.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    static extern uint EnumEnabledLayoutOrTip(string user, string system,
      string software, [Out] LayoutProfile[] rows, uint count);
    [DllImport("user32.dll")]
    static extern int GetKeyboardLayoutList(int count, [Out] IntPtr[] layouts);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern int GetCurrentPackageFullName(ref uint length, IntPtr name);

    public static void AssertUnpackaged() {
      uint length=0;
      int status=GetCurrentPackageFullName(ref length, IntPtr.Zero);
      if(status != 15700)
        throw new InvalidOperationException("Run this snapshot in an unpackaged Windows process.");
    }

    public static int ProcessorProfileSize {
      get { return Marshal.SizeOf(typeof(ProcessorProfile)); }
    }

    public static ProfileRow[] Read() {
      AssertUnpackaged();
      int expected=IntPtr.Size == 8 ? 88 : 72;
      if(ProcessorProfileSize != expected)
        throw new InvalidOperationException("Unexpected TF_INPUTPROCESSORPROFILE structure layout.");
      uint count=EnumEnabledLayoutOrTip(null,null,null,null,0);
      var native=new LayoutProfile[count];
      uint copied=EnumEnabledLayoutOrTip(null,null,null,native,count);
      if(copied > count)
        throw new InvalidOperationException("Input-profile list changed during capture.");
      var rows=new List<ProfileRow>();
      object instance=null;
      IProfileManager manager=null;
      try {
        if(copied > 0) {
          instance=Activator.CreateInstance(Type.GetTypeFromCLSID(
            new Guid("33C53A50-F456-4884-B049-85FD643ECFED"),true));
          manager=(IProfileManager)instance;
        }
        for(int index=0;index<copied;index++) {
          LayoutProfile item=native[index];
          var row=new ProfileRow {
            Id=item.Id, Type=item.Type, Language=item.Language.ToString("X4"),
            Flags=item.Flags, EnabledBySetting=(item.Flags & 2)==0,
            ClassId=item.ClassId.ToString("B"), ProfileId=item.ProfileId.ToString("B"),
            EnumeratedSubstitute=item.Substitute.ToString("X8")
          };
          if(item.Type == 1) {
            ProcessorProfile profile;
            int hr=manager.GetProfile(1,item.Language,ref item.ClassId,
              ref item.ProfileId,IntPtr.Zero,out profile);
            row.QueryHResult="0x"+unchecked((uint)hr).ToString("X8");
            row.QuerySucceeded=hr == 0;
            if(hr == 0) {
              row.TipSubstituteLayout=unchecked((ulong)profile.SubstituteLayout.ToInt64()).ToString(IntPtr.Size == 8 ? "X16" : "X8");
              row.TipFlags=profile.Flags;
              row.TipEnabled=(profile.Flags & 2)!=0;
              row.TipSubstituted=(profile.Flags & 4)!=0;
            }
          }
          rows.Add(row);
        }
      } finally {
        if(instance != null && Marshal.IsComObject(instance))
          Marshal.FinalReleaseComObject(instance);
      }
      return rows.ToArray();
    }

    public static string[] LoadedLayouts() {
      int count=GetKeyboardLayoutList(0,null);
      var layouts=new IntPtr[count];
      int copied=GetKeyboardLayoutList(count,layouts);
      var result=new string[copied];
      for(int index=0;index<copied;index++)
        result[index]=unchecked((ulong)layouts[index].ToInt64()).ToString(IntPtr.Size == 8 ? "X16" : "X8");
      return result;
    }
  }
}
'@
}

function Get-StellaeNativeProfileSnapshot {
  [StellaeInstallerProfileProbe.NativeSnapshot]::AssertUnpackaged()
  $languageList=Get-WinUserLanguageList
  # The cmdlet writes its WinUserLanguage list as one pipeline object.
  # Index it explicitly; member enumeration would flatten every group.
  $languages=@(for($index=0;$index -lt $languageList.Count;$index++) {
    $language=$languageList[$index]
    [ordered]@{LanguageTag=[string]$language.LanguageTag;Tips=@($language.InputMethodTips | ForEach-Object {[string]$_});Spellchecking=[bool]$language.Spellchecking;Handwriting=[bool]$language.Handwriting}
  })
  $rows=@([StellaeInstallerProfileProbe.NativeSnapshot]::Read())
  $enabled=@($rows | Where-Object {$_.EnabledBySetting})
  $dependencies=@(foreach($row in $enabled | Where-Object {$_.Type -eq 1 -and $_.QuerySucceeded -and $_.TipSubstituteLayout -notmatch '^0+$'}) {
    [ordered]@{Tip=$row.Id;Language=$row.Language;Layout=$row.TipSubstituteLayout}
  })
  [ordered]@{
    SchemaVersion=1;AtUtc=[DateTime]::UtcNow.ToString('o');ReadOnly=$true;Unpackaged=$true
    PowerShellVersion=[string]$PSVersionTable.PSVersion;PSEdition=[string]$PSVersionTable.PSEdition
    Languages=$languages;Enabled=$enabled;Raw=$rows;Dependencies=$dependencies
    LoadedLayouts=@([StellaeInstallerProfileProbe.NativeSnapshot]::LoadedLayouts())
    ProcessorProfileSize=[StellaeInstallerProfileProbe.NativeSnapshot]::ProcessorProfileSize
    NativeProbe='Get-WinUserLanguageList + EnumEnabledLayoutOrTip + GetProfile per actual TIP'
    QueriesComplete=(@($rows | Where-Object {$_.Type -eq 1 -and -not $_.QuerySucceeded}).Count -eq 0)
  }
}

if(-not $LibraryOnly) {
  $json=Get-StellaeNativeProfileSnapshot | ConvertTo-Json -Depth 9
  if($OutputFile){$json | Set-Content -LiteralPath $OutputFile -Encoding UTF8}
  else {$json}
}
