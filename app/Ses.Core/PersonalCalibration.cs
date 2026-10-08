namespace Ses.Core;

public sealed record PersonalCalibrationResult(
    bool Success, string Error, AudioSettings? Settings,
    float NoiseFloorDb=0, float SpeechDb=0, float QuietDb=0, float LoudDb=0,
    float SignalToNoiseDb=0, string[]? Warnings=null);

// A bounded, offline starting-point estimator. It does not identify microphone
// models, recover clipping, or claim a universally ideal voice spectrum.
public static class PersonalCalibration
{
    public const int Seconds=20;
    public static string StageKey(uint frames)=>frames<5*AudioSamples.Rate?"autoAmbient":
        frames<12*AudioSamples.Rate?"autoNormal":frames<16*AudioSamples.Rate?"autoQuiet":"autoLoud";

    public static PersonalCalibrationResult Analyze(float[]? raw)
    {
        if(raw is null||raw.Length!=Seconds*AudioSamples.Rate)return Failure("calibrationIncomplete");
        int clipped=0;
        foreach(float value in raw){if(!float.IsFinite(value))return Failure("autoInvalidAudio");if(Math.Abs(value)>=.995f)clipped++;}
        if(clipped>10)return Failure("calibrationClipped");
        var ambient=Levels(raw,0,5,-121);
        float noise=Percentile(ambient,.7f);
        if(Percentile(ambient,.95f)-Percentile(ambient,.2f)>12)return Failure("autoAmbientUnstable");
        var normal=Levels(raw,5,12,Math.Max(-65,noise+8));
        if(normal.Count<75)return Failure("calibrationNoSpeech");
        float speech=Percentile(normal,.5f);
        if(noise>-25||speech-noise<10)return Failure("autoTooNoisy");
        var quiet=Levels(raw,12,16,Math.Max(-70,noise+3));
        if(quiet.Count<40)return Failure("autoQuietMissing");
        var loud=Levels(raw,16,20,Math.Max(-60,noise+8));
        if(loud.Count<40)return Failure("autoLoudMissing");
        float quietDb=Percentile(quiet,.5f),loudDb=Percentile(loud,.8f);
        if(quietDb>speech+3||loudDb<speech-3)return Failure("autoStageMismatch");
        float snr=speech-noise,span=Math.Max(0,loudDb-quietDb);
        var settings=new AudioSettings {
            NoiseEnabled=true,NoiseAutoEnabled=true,AgcEnabled=true,
            SensitivityEnabled=true,SensitivityAutoEnabled=true,SensitivityThresholdDb=Math.Clamp(noise+10,-75,-20),
            NoiseMix=Math.Clamp(.4f+(noise+65)*(.55f/35),.35f,.95f),
            TargetDb=-20,MinGainDb=Math.Clamp(-20-loudDb-2,-12,0),
            MaxGainDb=Math.Clamp(-20-quietDb+3,0,12),
            CompressorThresholdDb=Math.Clamp(-23+Math.Clamp(loudDb-speech,2,8),-26,-12),
            CompressorRatio=Math.Clamp(1.8f+span/16,2,3.5f),
            AttackMs=span>12?8:12,ReleaseMs=span>12?160:120,KneeDb=6,
            OutputDb=0,SpeechThreshold=snr<20?.4f:.5f
        };
        // First-order analysis bands are deliberately used only for small tone
        // corrections. Ambient energy is removed before comparing speech bands.
        double[] ambientBands=BandPowers(raw,0,5,noise-3),voiceBands=BandPowers(raw,5,12,Math.Max(-65,noise+8));
        var powers=voiceBands.Select((p,i)=>Math.Max(1e-12,p-ambientBands[i])).ToArray();
        double total=powers.Sum(),noiseTotal=ambientBands.Sum();
        settings.HighpassHz=noiseTotal>1e-12&&ambientBands[0]/noiseTotal>.3?100:70;
        settings.Bands[0].Frequency=180;settings.Bands[1].Frequency=600;
        settings.Bands[2].Frequency=3000;settings.Bands[3].Frequency=8000;
        float boost=snr>=20?1:0;
        settings.Bands[0].GainDb=powers[1]/total>.65?-2:powers[1]/total<.1?boost:0;
        settings.Bands[1].GainDb=powers[2]/total>.6?-1.5f:0;
        settings.Bands[2].GainDb=powers[3]/total<.07?boost:powers[3]/total>.45?-1:0;
        settings.Bands[3].GainDb=powers[4]/total>.3?-1:0;
        settings.DeesserEnabled=powers[4]/total>.2;
        settings.DeesserMaxDb=settings.DeesserEnabled?2:0;
        settings.Validate();
        List<string> warnings=[];
        if(-20-quietDb>12)warnings.Add("autoGainLimited");
        if(snr<20)warnings.Add("autoNoisyWarning");
        if(span<4)warnings.Add("autoDynamicsSmall");
        return new(true,"",settings,Math.Clamp(noise,-100,-25),speech,quietDb,loudDb,snr,warnings.ToArray());
    }
    private static PersonalCalibrationResult Failure(string key)=>new(false,key,null);
    public static PersonalCalibrationResult VerifySpeech(PersonalCalibrationResult result,float[]? probabilities)
    {
        if(!result.Success)return result;
        if(probabilities is null||probabilities.Length!=Seconds*100||probabilities.Any(p=>!float.IsFinite(p)||p<0||p>1))return Failure("autoInvalidAudio");
        static int Count(float[] values,int start,int end,float threshold)=>values.AsSpan(start*100+40,(end-start)*100-60).ToArray().Count(p=>p>=threshold);
        if(Count(probabilities,5,12,.2f)<50)return Failure("calibrationNoSpeech");
        if(Count(probabilities,12,16,.08f)<15)return Failure("autoQuietMissing");
        if(Count(probabilities,16,20,.2f)<25)return Failure("autoLoudMissing");
        if(Count(probabilities,0,5,.5f)>80)return Failure("autoAmbientUnstable");
        return result;
    }
    private static List<float> Levels(float[] data,int startSeconds,int endSeconds,float threshold)
    {
        List<float> values=[];
        // Exclude prompt reaction time and phase-boundary transitions.
        int end=endSeconds*AudioSamples.Rate-9600;
        for(int offset=startSeconds*AudioSamples.Rate+19200;offset+960<=end;offset+=960){
            float level=Level(data.AsSpan(offset,960));if(level>threshold)values.Add(level);
        }
        values.Sort();return values;
    }
    private static float Level(ReadOnlySpan<float> data)
    {
        double mean=0,sum=0;foreach(float value in data)mean+=value;mean/=data.Length;
        foreach(float value in data){double ac=value-mean;sum+=ac*ac;}
        return (float)(20*Math.Log10(Math.Max(1e-6,Math.Sqrt(sum/data.Length))));
    }
    private static float Percentile(List<float> sorted,float percentile)=>sorted.Count==0?-120:sorted[(int)((sorted.Count-1)*percentile)];
    private static double[] BandPowers(float[] data,int start,int end,float threshold)
    {
        double[] cutoffs=[80,250,1000,4000,10000];
        var coefficients=cutoffs.Select(hz=>1-Math.Exp(-2*Math.PI*hz/AudioSamples.Rate)).ToArray();
        double[] filtered=new double[5],powers=new double[5];int count=0;
        for(int offset=start*AudioSamples.Rate+19200;offset+960<=end*AudioSamples.Rate-9600;offset+=960){
            bool include=Level(data.AsSpan(offset,960))>threshold;
            for(int j=offset;j<offset+960;j++){
                for(int b=0;b<5;b++)filtered[b]+=coefficients[b]*(data[j]-filtered[b]);
                if(!include)continue;
                powers[0]+=filtered[0]*filtered[0];
                for(int b=1;b<5;b++){double value=filtered[b]-filtered[b-1];powers[b]+=value*value;}
                count++;
            }
        }
        return powers.Select(p=>p/Math.Max(1,count)).ToArray();
    }
}
