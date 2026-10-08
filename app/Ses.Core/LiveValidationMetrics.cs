namespace Ses.Core;

public static class LiveStreamChecks
{
    public static bool MeetsResourceTargets(double cpuPercent,ulong workingSetBytes)=>
        double.IsFinite(cpuPercent)&&cpuPercent>=0&&cpuPercent<=3&&workingSetBytes>0&&workingSetBytes<=150_000_000;
    public static bool IsContinuous(EngineMetrics current,ulong previousFrames,uint outputKind,bool muted)=>
        current.Running==1&&current.Connected==1&&current.OutputKind==outputKind&&current.ProcessedFrames>=previousFrames&&
        muted&&float.IsFinite(current.OutputDb)&&current.OutputDb<=-119.9f;
}

// Fixed storage; percentiles are bucket upper bounds, never capped measurements.
public sealed class SampledTimingHistogram
{
    private readonly long[] buckets=new long[1001];
    public long Count {get;private set;}
    public long OverflowCount=>buckets[1000];
    public void Record(double milliseconds)
    {
        if(!double.IsFinite(milliseconds)||milliseconds<0)throw new InvalidDataException("Invalid processing-time sample.");
        int bucket=milliseconds>=10?1000:(int)(milliseconds*100);
        buckets[bucket]++;Count++;
    }
    public double? PercentileUpperBound(double fraction)
    {
        if(!double.IsFinite(fraction)||fraction<=0||fraction>1)throw new ArgumentOutOfRangeException(nameof(fraction));
        if(Count==0)return null;
        long target=(long)Math.Ceiling(Count*fraction),total=0;
        for(int i=0;i<buckets.Length;i++){total+=buckets[i];if(total>=target)return i==1000?null:(i+1)*.01;}
        return null;
    }
}
