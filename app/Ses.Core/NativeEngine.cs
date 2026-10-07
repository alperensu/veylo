using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Ses.Core;
public sealed record AudioDevice(string Id,string Name,bool Input,bool Default)
{
    public override string ToString()=>Name;
}
[StructLayout(LayoutKind.Sequential)]
public struct EngineMetrics
{
    public float InputDb,OutputDb,GainDb,CompressionDb,SpeechProbability,ProcessingMs,EstimatedBufferMs,DriftPpm;
    public ulong ProcessedFrames,ClippedSamples;
    public uint Running,Connected,Underruns,Overruns,SampleFrames,ErrorCode;
}
[StructLayout(LayoutKind.Sequential)]
internal struct NativeBand { public int Type;public float Frequency,GainDb,Q; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativeConfig
{
    public uint Version,Size,NoiseEnabled,AgcEnabled,DeesserEnabled,Muted,Bypass;
    public float HighpassHz,NoiseMix,TargetDb,MinGainDb,MaxGainDb,CompressorThresholdDb,CompressorRatio,AttackMs,ReleaseMs,KneeDb,DeesserMaxDb,OutputDb,NoiseFloorDb,SpeechThreshold;
    public NativeBand Band0,Band1,Band2,Band3;
}
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
internal struct DeviceConfig
{
    public uint Version,Size;
    [MarshalAs(UnmanagedType.ByValTStr,SizeConst=512)]public string InputId;
    [MarshalAs(UnmanagedType.ByValTStr,SizeConst=512)]public string OutputId;
    public uint PeriodMs,BufferMs;
}
[StructLayout(LayoutKind.Sequential)]
internal struct DeviceInfo
{
    [MarshalAs(UnmanagedType.ByValArray,SizeConst=512)]public byte[] Id;
    [MarshalAs(UnmanagedType.ByValArray,SizeConst=512)]public byte[] Name;
    public uint Kind,IsDefault;
}
internal sealed class EngineHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    internal EngineHandle(IntPtr pointer):base(true){SetHandle(pointer);}
    protected override bool ReleaseHandle(){Native.Destroy(handle);return true;}
}
internal static class Native
{
    internal const string Library="ses_native";
    [DllImport(Library,EntryPoint="ses_abi_version",CallingConvention=CallingConvention.Cdecl)]internal static extern uint Abi();
    [DllImport(Library,EntryPoint="ses_config_size",CallingConvention=CallingConvention.Cdecl)]internal static extern uint ConfigSize();
    [DllImport(Library,EntryPoint="ses_metrics_size",CallingConvention=CallingConvention.Cdecl)]internal static extern uint MetricsSize();
    [DllImport(Library,EntryPoint="ses_create",CallingConvention=CallingConvention.Cdecl)]internal static extern IntPtr Create();
    [DllImport(Library,EntryPoint="ses_destroy",CallingConvention=CallingConvention.Cdecl)]internal static extern void Destroy(IntPtr engine);
    [DllImport(Library,EntryPoint="ses_list_devices",CallingConvention=CallingConvention.Cdecl)]internal static extern int Devices([Out]DeviceInfo[] devices,uint capacity,out uint count);
    [DllImport(Library,EntryPoint="ses_update",CallingConvention=CallingConvention.Cdecl)]internal static extern int Update(EngineHandle engine,in NativeConfig config);
    [DllImport(Library,EntryPoint="ses_start",CallingConvention=CallingConvention.Cdecl)]internal static extern int Start(EngineHandle engine,in DeviceConfig config);
    [DllImport(Library,EntryPoint="ses_stop",CallingConvention=CallingConvention.Cdecl)]internal static extern void Stop(EngineHandle engine);
    [DllImport(Library,EntryPoint="ses_read_metrics",CallingConvention=CallingConvention.Cdecl)]internal static extern int Read(EngineHandle engine,out EngineMetrics metrics);
    [DllImport(Library,EntryPoint="ses_process",CallingConvention=CallingConvention.Cdecl)]internal static extern int Process(EngineHandle engine,float[] input,[Out]float[] output,uint frames);
    [DllImport(Library,EntryPoint="ses_begin_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern int Begin(EngineHandle engine,uint seconds);
    [DllImport(Library,EntryPoint="ses_end_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern void End(EngineHandle engine);
    [DllImport(Library,EntryPoint="ses_copy_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern uint Copy(EngineHandle engine,uint which,[Out]float[] output,uint capacity);
}
public sealed class NativeEngine : IDisposable
{
    private readonly EngineHandle handle;
    private static readonly object LibraryLock=new();
    private static string? loadedDirectory;
    public NativeEngine(string directory)
    {
        directory=Path.GetFullPath(directory);
        lock(LibraryLock)
        {
            if(loadedDirectory is null)
            {
                var dll=Path.Combine(directory,"ses_native.dll");
                if(!File.Exists(dll))throw new FileNotFoundException("The SES audio engine is missing.",dll);
                NativeLibrary.SetDllImportResolver(typeof(Native).Assembly,(name,assembly,_)=>name==Native.Library?NativeLibrary.Load(dll,assembly,DllImportSearchPath.UseDllDirectoryForDependencies|DllImportSearchPath.System32):IntPtr.Zero);
                loadedDirectory=directory;
            }
            else if(!string.Equals(loadedDirectory,directory,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("The engine location cannot change.");
        }
        if(Native.Abi()!=1||Native.ConfigSize()!=Marshal.SizeOf<NativeConfig>()||Native.MetricsSize()!=Marshal.SizeOf<EngineMetrics>())throw new InvalidOperationException("Audio engine ABI mismatch.");
        handle=new(Native.Create());if(handle.IsInvalid){handle.Dispose();throw new InvalidOperationException("Cannot initialize the audio engine.");}
    }
    public IReadOnlyList<AudioDevice> Devices()
    {
        var info=new DeviceInfo[128];if(Native.Devices(info,128,out uint count)!=0)throw new IOException("Cannot enumerate Windows audio devices.");
        static string Text(byte[]? x){if(x is null)return "";int end=Array.IndexOf(x,(byte)0);return Encoding.UTF8.GetString(x,0,end<0?x.Length:end);}
        return info.Take((int)Math.Min(count,128)).Select(d=>new AudioDevice(Text(d.Id),Text(d.Name),d.Kind==0,d.IsDefault!=0)).Where(d=>d.Id.Length>0).ToArray();
    }
    public void Update(AudioSettings s,float noiseFloor=-60,bool muted=false,bool bypass=false)
    {
        s.Validate();if(!float.IsFinite(noiseFloor)||noiseFloor < -120||noiseFloor > -15)throw new InvalidDataException("Invalid calibration.");
        NativeBand B(int i)=>new(){Type=s.Bands[i].Type,Frequency=s.Bands[i].Frequency,GainDb=s.Bands[i].GainDb,Q=s.Bands[i].Q};
        var c=new NativeConfig {Version=1,Size=(uint)Marshal.SizeOf<NativeConfig>(),NoiseEnabled=s.NoiseEnabled?1u:0u,AgcEnabled=s.AgcEnabled?1u:0u,DeesserEnabled=s.DeesserEnabled?1u:0u,Muted=muted?1u:0u,Bypass=bypass?1u:0u,
            HighpassHz=s.HighpassHz,NoiseMix=s.NoiseMix,TargetDb=s.TargetDb,MinGainDb=s.MinGainDb,MaxGainDb=s.MaxGainDb,CompressorThresholdDb=s.CompressorThresholdDb,CompressorRatio=s.CompressorRatio,AttackMs=s.AttackMs,ReleaseMs=s.ReleaseMs,KneeDb=s.KneeDb,DeesserMaxDb=s.DeesserMaxDb,OutputDb=s.OutputDb,NoiseFloorDb=noiseFloor,SpeechThreshold=s.SpeechThreshold,
            Band0=B(0),Band1=B(1),Band2=B(2),Band3=B(3)};
        if(Native.Update(handle,c)!=0)throw new InvalidDataException("Audio settings were rejected.");
    }
    public void Start(string inputId,string? outputId)
    {
        if(string.IsNullOrEmpty(inputId)||inputId.Length>=512||(outputId?.Length??0)>=512)throw new InvalidDataException("Invalid device.");
        var c=new DeviceConfig {Version=1,Size=(uint)Marshal.SizeOf<DeviceConfig>(),InputId=inputId,OutputId=outputId??"",PeriodMs=10,BufferMs=20};
        if(Native.Start(handle,c)!=0)throw new IOException("Cannot open the selected audio device. Check its connection, Windows microphone permission and whether another application uses exclusive mode.");
    }
    public void Stop()=>Native.Stop(handle);
    public EngineMetrics Metrics(){if(Native.Read(handle,out var m)!=0)throw new IOException("Cannot read audio status.");return m;}
    public void BeginSample(int seconds=20){if(seconds<1||seconds>20||Native.Begin(handle,(uint)seconds)!=0)throw new InvalidOperationException("Cannot begin a microphone sample.");}
    public void EndSample()=>Native.End(handle);
    public float[] CopySample(bool processed)
    {
        var n=Metrics().SampleFrames;if(n>AudioSamples.MaxFrames)throw new InvalidDataException("Invalid sample length.");
        float[] data=new float[n];uint copied=Native.Copy(handle,processed?1u:0u,data,n);
        return copied==n?data:data.Take((int)copied).ToArray();
    }
    public float[] Process(float[] input,AudioSettings settings,float noiseFloor=-60)
    {
        if(input.Length>AudioSamples.MaxFrames)throw new InvalidDataException("Sample exceeds 20 seconds.");
        Update(settings,noiseFloor);int padded=((input.Length+479)/480)*480;float[] x=new float[padded],y=new float[padded];input.CopyTo(x,0);
        if(Native.Process(handle,x,y,(uint)padded)!=0)throw new InvalidOperationException("Offline processing requires a stopped engine.");
        return y.Take(input.Length).ToArray();
    }
    public void Dispose()=>handle.Dispose();
}
