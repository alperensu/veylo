using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace Ses.Desktop;
// Developer-only performance sampler: fixed Win32 structs avoid enumerating
// process/thread metadata at 10Hz or influencing the heap being measured.
internal sealed class LiveProcessSampler:IDisposable
{
    [StructLayout(LayoutKind.Sequential)]private struct MemoryCounters
    {
        public uint Size,PageFaultCount;
        public UIntPtr PeakWorkingSet,WorkingSet,PeakPagedQuota,PagedQuota,PeakNonPagedQuota,NonPagedQuota,Pagefile,PeakPagefile,PrivateBytes;
    }
    [StructLayout(LayoutKind.Sequential)]private struct FileTime{public uint Low,High;public ulong Ticks=>((ulong)High<<32)|Low;}
    [DllImport("psapi.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessMemoryInfo(SafeProcessHandle handle,ref MemoryCounters counters,uint size);
    [DllImport("kernel32.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetProcessTimes(SafeProcessHandle handle,out FileTime creation,out FileTime exit,out FileTime kernel,out FileTime user);
    private readonly Process process=Process.GetCurrentProcess();
    internal readonly record struct Snapshot(ulong WorkingSetBytes,ulong PrivateBytes,double CpuSeconds,ulong LifetimePeakWorkingSetBytes);
    internal Snapshot Read(){
        var memory=new MemoryCounters{Size=(uint)Marshal.SizeOf<MemoryCounters>()};
        if(!GetProcessMemoryInfo(process.SafeHandle,ref memory,memory.Size)||!GetProcessTimes(process.SafeHandle,out _,out _,out var kernel,out var user))throw new Win32Exception(Marshal.GetLastWin32Error());
        return new(memory.WorkingSet.ToUInt64(),memory.PrivateBytes.ToUInt64(),(kernel.Ticks+user.Ticks)/10_000_000d,memory.PeakWorkingSet.ToUInt64());
    }
    public void Dispose()=>process.Dispose();
}
