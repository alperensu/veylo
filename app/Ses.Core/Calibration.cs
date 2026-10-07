namespace Ses.Core;
public record CalibrationResult(bool Success,float NoiseFloorDb,float SpeechDb,string Error);
public static class Calibration
{
    public static CalibrationResult Analyze(float[] raw)
    {
        const int ambient=5*AudioSamples.Rate,total=15*AudioSamples.Rate;
        if(raw.Length<total)return new(false,0,0,"calibrationIncomplete");
        if(raw.Any(x=>!float.IsFinite(x))||raw.Count(x=>Math.Abs(x)>=.995f)>10)return new(false,0,0,"calibrationClipped");
        float noise=(float)(20*Math.Log10(Math.Max(1e-6,AudioSamples.Rms(raw.AsSpan(0,ambient)))));
        List<float> speech=[];
        for(int offset=ambient;offset+960<=total;offset+=960){float value=(float)(20*Math.Log10(Math.Max(1e-6,AudioSamples.Rms(raw.AsSpan(offset,960)))));if(value>Math.Max(-55,noise+10))speech.Add(value);}
        if(speech.Count<100)return new(false,noise,0,"calibrationNoSpeech");
        speech.Sort();return new(true,Math.Clamp(noise,-100,-25),speech[speech.Count/2],"");
    }
}
