namespace Ses.Core;
public record MatchedSample(float[] Raw, float[] Processed);
public static class AudioSamples
{
    public const int Rate = 48000;
    public const int MaxFrames = Rate * 20;
    public static double Rms(ReadOnlySpan<float> data)
    {
        double sum=0;foreach(float x in data)if(float.IsFinite(x))sum+=(double)x*x;
        return Math.Sqrt(sum/Math.Max(1,data.Length));
    }
    public static MatchedSample Match(float[] raw,float[] processed)
    {
        int frames=Math.Min(Math.Min(raw.Length,processed.Length),MaxFrames);
        int delay=frames>960?960:0;
        var a=raw.AsSpan(0,frames-delay).ToArray();var b=processed.AsSpan(delay,frames-delay).ToArray();
        var ra=Rms(a);var rb=Rms(b);
        if(ra>1e-6 && rb>1e-6){double target=Math.Min(.1,Math.Min(ra,rb));Scale(a,target/ra);Scale(b,target/rb);}
        else {Scale(a,1);Scale(b,1);}
        return new(a,b);
    }
    private static void Scale(float[] data,double factor) { for(int i=0;i<data.Length;i++)data[i]=float.IsFinite(data[i])?(float)Math.Clamp(data[i]*factor,-.8912509,.8912509):0; }
    public static byte[] Wave(float[] data)
    {
        if(data.Length>MaxFrames)throw new InvalidDataException("Sample exceeds 20 seconds.");
        using var stream=new MemoryStream(44+data.Length*2);using var writer=new BinaryWriter(stream);
        writer.Write("RIFF"u8);writer.Write(36+data.Length*2);writer.Write("WAVEfmt "u8);writer.Write(16);writer.Write((short)1);writer.Write((short)1);
        writer.Write(Rate);writer.Write(Rate*2);writer.Write((short)2);writer.Write((short)16);writer.Write("data"u8);writer.Write(data.Length*2);
        foreach(float x in data){float value=float.IsFinite(x)?Math.Clamp(x,-1,1):0;writer.Write((short)Math.Round(value*(value>=0?32767:32768)));}
        return stream.ToArray();
    }
}
