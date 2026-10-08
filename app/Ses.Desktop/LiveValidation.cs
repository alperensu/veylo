using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using Ses.Core;

namespace Ses.Desktop;
public partial class MainWindow
{
    private async Task ValidateLive(string directory)
    {
        string runId=Guid.NewGuid().ToString("N");
        string starting=JsonSerializer.Serialize(new{runId,status="running",success=false,processId=Environment.ProcessId,requestedSeconds=liveValidation?.DurationSeconds});
        File.WriteAllText(Path.Combine(directory,"live-result.json"),starting);
        File.WriteAllText(Path.Combine(directory,"live-final-metrics.json"),starting);
        File.WriteAllText(Path.Combine(directory,"live-progress.json"),starting);
        File.WriteAllText(Path.Combine(directory,"live-timeline.jsonl"),"");
        try{await ValidateLiveCore(directory,runId);}
        catch(Exception ex){
            string failed=JsonSerializer.Serialize(new{runId,status="failed",success=false,processId=Environment.ProcessId,requestedSeconds=liveValidation?.DurationSeconds,error=ex.Message});
            File.WriteAllText(Path.Combine(directory,"live-progress.json"),failed);
            File.WriteAllText(Path.Combine(directory,"live-result.json"),failed);
            throw;
        }
    }
    private async Task ValidateLiveCore(string directory,string runId)
    {
        var options=liveValidation??throw new InvalidOperationException("Explicit live-validation mode required");
        if(!smoke||MuteBox.IsChecked!=true)throw new InvalidOperationException("Live validation must be isolated and muted before capture starts");
        if(options.RequireCable&&(SelectedRoute.Mode!="cable"||!SelectedRoute.Available))throw new IOException("VB-CABLE is required for this routing test");
        var device=InputBox.SelectedItem as AudioDevice??throw new IOException("No input device");
        settings.NoiseAutoEnabled=true;UpdateEngine(settings,NoiseFloor);
        var opened=engine.Metrics();
        if(opened.Running!=1||opened.Connected!=1||opened.OutputKind!=OutputRouting.EffectiveKind(SelectedRoute))throw new IOException("Automatic processing did not start on WindowLoaded");
        bool hiddenStartup=!IsVisible;
        if(args.Contains("--minimized")&&!hiddenStartup)throw new IOException("Hidden startup must remain hidden while processing starts");
        engine.BeginSample(2);Close();meterTimer.Stop();
        if(IsVisible||engine.Metrics().Running!=1)throw new IOException("Close must hide while processing continues");
        await Task.Delay(2100);engine.EndSample();
        if(engine.Metrics().Running!=1)throw new IOException("Finishing a sample stopped processing");
        var initial=engine.Metrics();ulong lastFrames=initial.ProcessedFrames;
        using var process=new LiveProcessSampler();var initialProcess=process.Read();double cpu=initialProcess.CpuSeconds;long initialManagedAllocated=GC.GetTotalAllocatedBytes(false);var clock=Stopwatch.StartNew();
        ulong maxWorkingSet=Math.Max(initialProcess.WorkingSetBytes,initialProcess.LifetimePeakWorkingSetBytes),maxPrivate=initialProcess.PrivateBytes;double minInput=0,maxInput=-120,maxAbsDrift=0,maxSampledBlock=0,nextProgress=0;
        var histogram=new SampledTimingHistogram();double lastAdvance=0;
        string version=typeof(MainWindow).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion??"unknown";
        var json=new JsonSerializerOptions{WriteIndented=true,IncludeFields=true};
        var progressJson=new JsonSerializerOptions{IncludeFields=true};
        while(clock.Elapsed.TotalSeconds<options.DurationSeconds){
            await Task.Delay(options.PollIntervalMilliseconds);var memory=process.Read();var m=engine.Metrics();double elapsed=clock.Elapsed.TotalSeconds;
            if(!LiveStreamChecks.IsContinuous(m,lastFrames,opened.OutputKind,MuteBox.IsChecked==true))throw new IOException("Live stream disconnected, reset or lost mute; uninterrupted acceptance failed");
            if(m.ProcessedFrames>lastFrames)lastAdvance=elapsed;
            if(elapsed-lastAdvance>2)throw new IOException("Live capture stopped advancing");
            lastFrames=m.ProcessedFrames;
            maxWorkingSet=Math.Max(maxWorkingSet,Math.Max(memory.WorkingSetBytes,memory.LifetimePeakWorkingSetBytes));maxPrivate=Math.Max(maxPrivate,memory.PrivateBytes);
            minInput=Math.Min(minInput,m.InputDb);maxInput=Math.Max(maxInput,m.InputDb);maxAbsDrift=Math.Max(maxAbsDrift,Math.Abs(m.DriftPpm));
            maxSampledBlock=Math.Max(maxSampledBlock,m.ProcessingMs);
            histogram.Record(m.ProcessingMs);
            if(elapsed>=nextProgress){
                var gc=GC.GetGCMemoryInfo();
                string progress=JsonSerializer.Serialize(new{runId,status="running",processId=Environment.ProcessId,version,requestedSeconds=options.DurationSeconds,elapsedSeconds=elapsed,muted=true,outputKind=m.OutputKind,framesSinceStart=m.ProcessedFrames-initial.ProcessedFrames,underruns=m.Underruns,overruns=m.Overruns,maxWorkingSetBytes=maxWorkingSet,maxPrivateBytes=maxPrivate,maxAbsSampledDriftPpm=maxAbsDrift,diagnostics=engine.Diagnostics(),managedHeapBytes=GC.GetTotalMemory(false),managedCommittedBytes=gc.TotalCommittedBytes,managedAllocatedBytesApprox=GC.GetTotalAllocatedBytes(false)-initialManagedAllocated,lowOverhead=options.LowOverhead,sampleIntervalMs=options.PollIntervalMilliseconds,progressIntervalSeconds=options.ProgressIntervalSeconds,currentWorkingSetBytes=memory.WorkingSetBytes,currentPrivateBytes=memory.PrivateBytes,lifetimePeakWorkingSetBytes=memory.LifetimePeakWorkingSetBytes,gcGen0=GC.CollectionCount(0),gcGen1=GC.CollectionCount(1),gcGen2=GC.CollectionCount(2),gcCommittedReflectsLastCollection=true,normalProductBaseline=false},progressJson);
                File.WriteAllText(Path.Combine(directory,"live-progress.json"),progress);
                // Bounded metadata history preserves natural GC/working-set timing.
                // No audio, heap objects, forced collections or working-set trimming.
                File.AppendAllText(Path.Combine(directory,"live-timeline.jsonl"),progress+Environment.NewLine);
                nextProgress=elapsed+options.ProgressIntervalSeconds;
            }
        }
        var metrics=engine.Metrics();var diagnostic=engine.Diagnostics();var finalProcess=process.Read();double duration=clock.Elapsed.TotalSeconds;
        if(!LiveStreamChecks.IsContinuous(metrics,lastFrames,opened.OutputKind,MuteBox.IsChecked==true))throw new IOException("Final live snapshot failed continuity or mute checks");
        maxWorkingSet=Math.Max(maxWorkingSet,Math.Max(finalProcess.WorkingSetBytes,finalProcess.LifetimePeakWorkingSetBytes));maxPrivate=Math.Max(maxPrivate,finalProcess.PrivateBytes);
        double cpuPercent=(finalProcess.CpuSeconds-cpu)/duration/Environment.ProcessorCount*100;
        ulong advanced=metrics.ProcessedFrames-initial.ProcessedFrames;
        sessionTimer.Stop();await EngineOperation(engine.Stop);var sample=engine.CopySample(false);
        if(metrics.Connected!=1||advanced<48000*(duration-1)||sample.Length!=96000||sample.Any(x=>!float.IsFinite(x)))throw new IOException("Live capture did not produce continuous bounded samples");
        bool cleanBuffers=metrics.Underruns==0&&metrics.Overruns==0;
        bool resourceTargetsMet=LiveStreamChecks.MeetsResourceTargets(cpuPercent,maxWorkingSet),accepted=cleanBuffers&&resourceTargetsMet;
        string final=JsonSerializer.Serialize(new{
            runId,status=accepted?"completed":"failed",success=accepted,streamContinuityTargetMet=cleanBuffers,resourceTargetsMet,version,measuredAt=DateTimeOffset.UtcNow,device=device.Name,requestedSeconds=options.DurationSeconds,durationSeconds=duration,
            cpuPercent,maxWorkingSetBytes=maxWorkingSet,maxWorkingSetMiB=maxWorkingSet/1048576d,maxPrivateBytes=maxPrivate,
            framesSinceMeasurementStart=advanced,sampleFrames=sample.Length,rawSampleSaved=false,minSampledInputDb=minInput,maxSampledInputDb=maxInput,
            sampledDspP95UpperBoundMs=histogram.PercentileUpperBound(.95),sampledDspP99UpperBoundMs=histogram.PercentileUpperBound(.99),sampledDspOverflowCount=histogram.OverflowCount,overflowLowerBoundMs=10,maxSampledDspMs=maxSampledBlock,dspTimingIsSampled=true,observations=histogram.Count,
            underruns=metrics.Underruns,overruns=metrics.Overruns,warmupUnderruns=initial.Underruns,warmupOverruns=initial.Overruns,maxAbsSampledDriftPpm=maxAbsDrift,
            thisProcessMutedForEntireRun=true,totalCableSilenceVerified=false,automaticStart=true,hiddenStartup,closeHidesWhileProcessing=true,sampleDoesNotStopProcessing=true,
            outputKind=metrics.OutputKind,driverStatus=metrics.DriverStatus,automaticNoise=true,gameMonitoringEnabled=state.GameModeEnabled,diagnostics=diagnostic,memorySampler="Win32 fixed structures",managedHeapBytes=GC.GetTotalMemory(false),managedCommittedBytes=GC.GetGCMemoryInfo().TotalCommittedBytes,managedAllocatedBytesApprox=GC.GetTotalAllocatedBytes(false)-initialManagedAllocated,
            lowOverhead=options.LowOverhead,sampleIntervalMs=options.PollIntervalMilliseconds,progressIntervalSeconds=options.ProgressIntervalSeconds,lifetimePeakWorkingSetBytes=finalProcess.LifetimePeakWorkingSetBytes,workingSetIncludesStartupPeak=true,gcGen0=GC.CollectionCount(0),gcGen1=GC.CollectionCount(1),gcGen2=GC.CollectionCount(2),gcCommittedReflectsLastCollection=true,normalProductBaseline=false,
            measuredEndToEndLatencyMs=(double?)null,voiceQualityVerified=false,gameLoadVerified=false,
            cpuTargetMet=cpuPercent<=3,workingSetTargetMet=maxWorkingSet<=150_000_000,privateBytesTargetMet=maxPrivate<=150_000_000
        },json);
        File.WriteAllText(Path.Combine(directory,"live-final-metrics.json"),final);
        File.WriteAllText(Path.Combine(directory,"live-result.json"),final);
        File.WriteAllText(Path.Combine(directory,"live-progress.json"),JsonSerializer.Serialize(new{runId,status=accepted?"completed":"failed",success=accepted,processId=Environment.ProcessId,requestedSeconds=options.DurationSeconds,elapsedSeconds=duration},json));
        if(!accepted)throw new IOException("Live stream had buffer errors or exceeded CPU/memory targets; detailed final metrics retained");
    }
}
