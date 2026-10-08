using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Ses.Core;

namespace Ses.Desktop;
internal static class GameDetector
{
    [StructLayout(LayoutKind.Sequential)]private struct Rect{public int Left,Top,Right,Bottom;}
    [StructLayout(LayoutKind.Sequential)]private struct Monitor{public uint Size;public Rect Bounds,Work;public uint Flags;}
    // UTF-16 code units keep PROCESSENTRY32W blittable: no string is marshalled per process.
    [InlineArray(260)]private struct ExecutableBuffer{private ushort first;}
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size,Usage,ProcessId;
        public UIntPtr DefaultHeapId;
        public uint ModuleId,Threads,ParentProcessId;
        public int BasePriority;
        public uint Flags;
        public ExecutableBuffer ExecutableName;
    }
    static GameDetector()
    {
        int expectedSize=IntPtr.Size==8?568:556,expectedNameOffset=IntPtr.Size==8?44:36;
        if(Marshal.SizeOf<ProcessEntry>()!=expectedSize||Marshal.OffsetOf<ProcessEntry>(nameof(ProcessEntry.ExecutableName)).ToInt32()!=expectedNameOffset)
            throw new InvalidOperationException("Unexpected PROCESSENTRY32W layout.");
    }
    private sealed class ProcessSnapshot:SafeHandleZeroOrMinusOneIsInvalid
    {
        private ProcessSnapshot():base(true){}
        protected override bool ReleaseHandle()=>CloseHandle(handle);
    }
    [DllImport("kernel32.dll",SetLastError=true)]private static extern ProcessSnapshot CreateToolhelp32Snapshot(uint flags,uint processId);
    [DllImport("kernel32.dll",EntryPoint="Process32FirstW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]private static extern bool Process32First(ProcessSnapshot snapshot,ref ProcessEntry entry);
    [DllImport("kernel32.dll",EntryPoint="Process32NextW",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]private static extern bool Process32Next(ProcessSnapshot snapshot,ref ProcessEntry entry);
    [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool CloseHandle(IntPtr handle);
    [DllImport("user32.dll")]private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr window,out uint id);
    [DllImport("user32.dll")][return:MarshalAs(UnmanagedType.Bool)]private static extern bool GetWindowRect(IntPtr window,out Rect rect);
    [DllImport("user32.dll")]private static extern IntPtr MonitorFromWindow(IntPtr window,uint flags);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool GetMonitorInfo(IntPtr monitor,ref Monitor info);
    private static (uint ProcessId,bool Fullscreen) Foreground()
    {
        var foreground=GetForegroundWindow();GetWindowThreadProcessId(foreground,out uint foregroundId);
        bool fullscreen=false;
        var monitor=new Monitor{Size=(uint)Marshal.SizeOf<Monitor>()};
        if(foreground!=IntPtr.Zero&&GetWindowRect(foreground,out var rect)&&GetMonitorInfo(MonitorFromWindow(foreground,2),ref monitor))
            fullscreen=Math.Abs(rect.Left-monitor.Bounds.Left)<=2&&Math.Abs(rect.Top-monitor.Bounds.Top)<=2&&Math.Abs(rect.Right-monitor.Bounds.Right)<=2&&Math.Abs(rect.Bottom-monitor.Bounds.Bottom)<=2;
        return(foregroundId,fullscreen);
    }
    private static ReadOnlySpan<char> ProcessName(ref ProcessEntry entry)
    {
        var name=MemoryMarshal.Cast<ushort,char>(MemoryMarshal.CreateReadOnlySpan(ref entry.ExecutableName[0],260));
        int terminator=name.IndexOf('\0');if(terminator>=0)name=name[..terminator];
        // Match Process.ProcessName, including the Windows Idle pseudo-process.
        return name.IsEmpty?name:entry.ProcessId==0?"Idle".AsSpan():GameModePolicy.Normalize(name);
    }
    internal static GameObservation[] Read()
    {
        var foreground=Foreground();
        // Process-only snapshots avoid allocating managed Process objects and thread metadata.
        // Names remain untrusted metadata: no process is opened and no executable path is read.
        using var snapshot=CreateToolhelp32Snapshot(0x00000002,0); // TH32CS_SNAPPROCESS
        if(snapshot.IsInvalid)return Array.Empty<GameObservation>();
        var entry=new ProcessEntry{Size=(uint)Marshal.SizeOf<ProcessEntry>()};
        if(!Process32First(snapshot,ref entry))return Array.Empty<GameObservation>();
        var observations=new List<GameObservation>(256);
        uint ownId=(uint)Environment.ProcessId;
        do{
            if(entry.ProcessId==ownId||entry.ExecutableName[0]==0)continue;
            var name=ProcessName(ref entry);
            observations.Add(new(name.ToString(),foreground.Fullscreen&&entry.ProcessId==foreground.ProcessId));
        }while(Process32Next(snapshot,ref entry));
        return observations.ToArray();
    }
    internal static GameObservation[] FindMatches(IReadOnlyList<string> custom)
    {
        var foreground=Foreground();
        using var snapshot=CreateToolhelp32Snapshot(0x00000002,0);
        if(snapshot.IsInvalid)return Array.Empty<GameObservation>();
        var entry=new ProcessEntry{Size=(uint)Marshal.SizeOf<ProcessEntry>()};
        if(!Process32First(snapshot,ref entry))return Array.Empty<GameObservation>();
        uint ownId=(uint)Environment.ProcessId;
        do{
            if(entry.ProcessId==ownId)continue;
            var name=ProcessName(ref entry);
            bool fullscreen=foreground.Fullscreen&&entry.ProcessId==foreground.ProcessId;
            if(GameModePolicy.Matches(name,fullscreen,custom))return[new(name.ToString(),fullscreen)];
        }while(Process32Next(snapshot,ref entry));
        return Array.Empty<GameObservation>();
    }
}
