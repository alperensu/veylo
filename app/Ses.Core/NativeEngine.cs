using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Ses.Core;
public sealed record AudioDevice(string Id,string Name,bool Input,bool Default,bool IsSesVirtual=false)
{
    public override string ToString()=>Name;
}
[StructLayout(LayoutKind.Sequential)]
public struct EngineMetrics
{
    public float InputDb,OutputDb,GainDb,CompressionDb,SpeechProbability,ProcessingMs,EstimatedBufferMs,DriftPpm,NoiseMix,NoiseFloorDb,SensitivityThresholdDb,SensitivityGain;
    public ulong ProcessedFrames,ClippedSamples;
    public uint Running,Connected,Underruns,Overruns,SampleFrames,ErrorCode;
    public uint OutputKind,DriverStatus,DriverProtocol,DriverError,DriverQueuedFrames,DriverUnderruns,DriverOverruns;
    public int DriverDriftPpm;
    public ulong DriverSentFrames,DriverSilenceFrames;
}
[StructLayout(LayoutKind.Sequential)]
public struct StreamDiagnostics
{
    public uint Version,Size;
    public ulong CaptureCallbacks,PlaybackCallbacks,CaptureMaxGapUs,PlaybackMaxGapUs,CaptureMaxDurationUs;
    public uint CaptureMaxFrames,PlaybackMaxFrames,FifoMinStartingFrames,FifoMaxStartingFrames;
    public uint WaitingCallbacks,LastUnderflowAvailableFrames,LastUnderflowRemainingFrames,RefreshedWrites;
    public uint CapturePeriodFrames,PlaybackPeriodFrames,CaptureDeviceRate,PlaybackDeviceRate;
}
[StructLayout(LayoutKind.Sequential)]
internal struct NativeBand { public int Type;public float Frequency,GainDb,Q; }
[StructLayout(LayoutKind.Sequential)]
internal struct NativeConfig
{
    public uint Version,Size,NoiseEnabled,AgcEnabled,DeesserEnabled,Muted,Bypass,NoiseAutoEnabled,SensitivityEnabled,SensitivityAutoEnabled;
    public float HighpassHz,NoiseMix,TargetDb,MinGainDb,MaxGainDb,CompressorThresholdDb,CompressorRatio,AttackMs,ReleaseMs,KneeDb,DeesserMaxDb,OutputDb,NoiseFloorDb,SpeechThreshold,SensitivityThresholdDb;
    public NativeBand Band0,Band1,Band2,Band3;
    public uint SensitivityMode;
    public float SensitivityAttackMs,SensitivityHoldMs,SensitivityReleaseMs,SensitivityHysteresisDb,SensitivityRatio,SensitivityMaxReductionDb;
}
[StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
internal struct DeviceConfig
{
    public uint Version,Size;
    [MarshalAs(UnmanagedType.ByValTStr,SizeConst=512)]public string InputId;
    [MarshalAs(UnmanagedType.ByValTStr,SizeConst=512)]public string OutputId;
    public uint PeriodMs,BufferMs,OutputKind;
}
[StructLayout(LayoutKind.Sequential)]
internal struct DeviceInfo
{
    [MarshalAs(UnmanagedType.ByValArray,SizeConst=512)]public byte[] Id;
    [MarshalAs(UnmanagedType.ByValArray,SizeConst=512)]public byte[] Name;
    public uint Kind,IsDefault,IsSesVirtual;
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
    [DllImport(Library,EntryPoint="ses_set_talk_gate",CallingConvention=CallingConvention.Cdecl)]internal static extern int SetTalkGate(EngineHandle engine,uint mode,uint held);
    [DllImport(Library,EntryPoint="ses_start",CallingConvention=CallingConvention.Cdecl)]internal static extern int Start(EngineHandle engine,in DeviceConfig config);
    [DllImport(Library,EntryPoint="ses_stop",CallingConvention=CallingConvention.Cdecl)]internal static extern void Stop(EngineHandle engine);
    [DllImport(Library,EntryPoint="ses_read_metrics",CallingConvention=CallingConvention.Cdecl)]internal static extern int Read(EngineHandle engine,out EngineMetrics metrics);
    [DllImport(Library,EntryPoint="ses_read_stream_diagnostics",CallingConvention=CallingConvention.Cdecl)]internal static extern int Diagnostics(EngineHandle engine,uint version,uint size,out StreamDiagnostics diagnostics);
    [DllImport(Library,EntryPoint="ses_process",CallingConvention=CallingConvention.Cdecl)]internal static extern int Process(EngineHandle engine,float[] input,[Out]float[] output,uint frames);
    [DllImport(Library,EntryPoint="ses_begin_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern int Begin(EngineHandle engine,uint seconds);
    [DllImport(Library,EntryPoint="ses_end_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern void End(EngineHandle engine);
    [DllImport(Library,EntryPoint="ses_copy_sample",CallingConvention=CallingConvention.Cdecl)]internal static extern uint Copy(EngineHandle engine,uint which,[Out]float[] output,uint capacity);
}
public sealed class AudioDeviceException(int code,string message) : IOException(message) {public int Code {get;}=code;}
public sealed class NativeEngine : IDisposable
{
    private readonly EngineHandle handle;
    private bool diagnosticsUnavailable;
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
                if(!File.Exists(dll))throw new FileNotFoundException("The Veylo audio engine is missing.",dll);
                NativeLibrary.SetDllImportResolver(typeof(Native).Assembly,(name,assembly,_)=>name==Native.Library?NativeLibrary.Load(dll,assembly,DllImportSearchPath.UseDllDirectoryForDependencies|DllImportSearchPath.System32):IntPtr.Zero);
                loadedDirectory=directory;
            }
            else if(!string.Equals(loadedDirectory,directory,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("The engine location cannot change.");
        }
        if(Native.Abi()!=5||Native.ConfigSize()!=Marshal.SizeOf<NativeConfig>()||Native.MetricsSize()!=Marshal.SizeOf<EngineMetrics>())throw new InvalidOperationException("Audio engine ABI mismatch.");
        handle=new(Native.Create());if(handle.IsInvalid){handle.Dispose();throw new InvalidOperationException("Cannot initialize the audio engine.");}
    }
    public IReadOnlyList<AudioDevice> Devices()
    {
        var info=new DeviceInfo[128];if(Native.Devices(info,128,out uint count)!=0)throw new IOException("Cannot enumerate Windows audio devices.");
        static string Text(byte[]? x){if(x is null)return "";int end=Array.IndexOf(x,(byte)0);return Encoding.UTF8.GetString(x,0,end<0?x.Length:end);}
        return info.Take((int)Math.Min(count,128)).Select(d=>new AudioDevice(Text(d.Id),Text(d.Name),d.Kind==0,d.IsDefault!=0,d.IsSesVirtual!=0)).Where(d=>d.Id.Length>0).ToArray();
    }
    public void Update(AudioSettings s,float noiseFloor=-60,bool muted=false,bool bypass=false)
    {
        s.Validate();if(!float.IsFinite(noiseFloor)||noiseFloor < -120||noiseFloor > -15)throw new InvalidDataException("Invalid calibration.");
        NativeBand B(int i)=>new(){Type=s.Bands[i].Type,Frequency=s.Bands[i].Frequency,GainDb=s.Bands[i].GainDb,Q=s.Bands[i].Q};
        var c=new NativeConfig {Version=5,Size=(uint)Marshal.SizeOf<NativeConfig>(),NoiseEnabled=s.NoiseEnabled?1u:0u,AgcEnabled=s.AgcEnabled?1u:0u,DeesserEnabled=s.DeesserEnabled?1u:0u,Muted=muted?1u:0u,Bypass=bypass?1u:0u,NoiseAutoEnabled=s.NoiseAutoEnabled?1u:0u,SensitivityEnabled=s.SensitivityEnabled?1u:0u,SensitivityAutoEnabled=s.SensitivityAutoEnabled?1u:0u,
            HighpassHz=s.HighpassHz,NoiseMix=s.NoiseMix,TargetDb=s.TargetDb,MinGainDb=s.MinGainDb,MaxGainDb=s.MaxGainDb,CompressorThresholdDb=s.CompressorThresholdDb,CompressorRatio=s.CompressorRatio,AttackMs=s.AttackMs,ReleaseMs=s.ReleaseMs,KneeDb=s.KneeDb,DeesserMaxDb=s.DeesserMaxDb,OutputDb=s.OutputDb,NoiseFloorDb=noiseFloor,SpeechThreshold=s.SpeechThreshold,SensitivityThresholdDb=s.SensitivityThresholdDb,
            Band0=B(0),Band1=B(1),Band2=B(2),Band3=B(3),SensitivityMode=(uint)s.SensitivityMode,
            SensitivityAttackMs=s.SensitivityAttackMs,SensitivityHoldMs=s.SensitivityHoldMs,SensitivityReleaseMs=s.SensitivityReleaseMs,
            SensitivityHysteresisDb=s.SensitivityHysteresisDb,SensitivityRatio=s.SensitivityRatio,SensitivityMaxReductionDb=s.SensitivityMaxReductionDb};
        if(Native.Update(handle,c)!=0)throw new InvalidDataException("Audio settings were rejected.");
    }
    public void Start(string inputId,string? outputId, bool virtualMicrophone=false)
    {
        if(string.IsNullOrEmpty(inputId)||inputId.Length>=512||(outputId?.Length??0)>=512)throw new InvalidDataException("Invalid device.");
        var c=new DeviceConfig {Version=5,Size=(uint)Marshal.SizeOf<DeviceConfig>(),InputId=inputId,OutputId=outputId??"",PeriodMs=5,BufferMs=20,OutputKind=virtualMicrophone?1u:string.IsNullOrEmpty(outputId)?0u:2u};
        int result=Native.Start(handle,c);if(result!=0)throw new AudioDeviceException(result,"Cannot open the selected audio device. Check its connection, Windows microphone permission and whether another application uses exclusive mode.");
    }
    public void Stop()=>Native.Stop(handle);
    public void SetTalkGate(int mode,bool held){if(mode is <0 or >2||Native.SetTalkGate(handle,(uint)mode,held?1u:0u)!=0)throw new InvalidDataException("Invalid talk gate.");}
    public EngineMetrics Metrics(){if(Native.Read(handle,out var m)!=0)throw new IOException("Cannot read audio status.");return m;}
    // Older ABI5 libraries remain usable; this optional extension never changes
    // the settings/metrics contract. Validation reports null when it is absent.
    public StreamDiagnostics? Diagnostics(){
        if(diagnosticsUnavailable)return null;
        try{if(Native.Diagnostics(handle,1,(uint)Marshal.SizeOf<StreamDiagnostics>(),out var d)!=0)throw new IOException("Cannot read stream diagnostics.");return d;}
        catch(EntryPointNotFoundException){diagnosticsUnavailable=true;return null;}
    }
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
        Update(settings,noiseFloor);
        return ProcessConfigured(input);
    }
    // Offline-only processing without replacing the current mute/bypass configuration.
    public float[] ProcessConfigured(float[] input)
    {
        if(input.Length>AudioSamples.MaxFrames)throw new InvalidDataException("Sample exceeds 20 seconds.");
        int padded=((input.Length+479)/480)*480;float[] x=new float[padded],y=new float[padded];input.CopyTo(x,0);
        if(Native.Process(handle,x,y,(uint)padded)!=0)throw new InvalidOperationException("Offline processing requires a stopped engine.");
        return y.Take(input.Length).ToArray();
    }
    // Offline speech validation for calibration only. Reuse block buffers, never
    // run this on the live engine or UI thread. Voice data remains in RAM.
    public float[] SpeechActivity(float[] input)
    {
        if(input.Length>AudioSamples.MaxFrames||input.Length%480!=0||Metrics().Running!=0)throw new InvalidDataException("Invalid offline speech sample.");
        Update(new AudioSettings{AgcEnabled=false,CompressorRatio=1,NoiseMix=1});
        float[] block=new float[480],output=new float[480],probabilities=new float[input.Length/480];
        for(int i=0;i<probabilities.Length;i++){
            Array.Copy(input,i*480,block,0,480);
            if(Native.Process(handle,block,output,480)!=0)throw new IOException("Speech analysis failed.");
            probabilities[i]=Metrics().SpeechProbability;
        }
        return probabilities;
    }
    public void Dispose()=>handle.Dispose();
}
