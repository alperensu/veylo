using Ses.Core;

internal static class CalibrationQuickChecks
{
    public static void Run(Action<string,Action> check)
    {
        check("quick calibration uses two deterministic stages over ten seconds",()=>{
            Require(PersonalCalibration.Duration(false)==10&&PersonalCalibration.Duration(true)==20);
            Require(PersonalCalibration.StageKey(95999,false)=="autoQuickAmbient"&&PersonalCalibration.StageEndSeconds(95999,false)==2);
            Require(PersonalCalibration.StageKey(96000,false)=="autoQuickSpeech"&&PersonalCalibration.StageEndSeconds(96000,false)==10);
        });
        check("quick calibration observes ordinary speech without requiring acted levels",()=>{
            var result=PersonalCalibration.Analyze(Sample(.15f));Require(result.Success&&!result.Detailed);
            Require(result.QuietDb<=result.SpeechDb&&result.SpeechDb<=result.LoudDb);
            Require(result.Warnings!.Contains("autoQuickRange")&&!result.Warnings.Contains("autoDynamicsSmall"));
            result.Settings!.Validate();Require(result.Settings.SensitivityMode==1&&result.Settings.OutputDb==0);
            var quieter=PersonalCalibration.Analyze(Sample(.012f));Require(quieter.Success&&quieter.Settings!.MaxGainDb>result.Settings.MaxGainDb);
        });
        check("quick calibration preserves chosen tone and full wet cleaning without aliasing",()=>{
            var baseline=NoiseControl.Strong(Profiles.Factory().Single(p=>p.FactoryId=="warm").Settings);
            var before=baseline.Clone();var result=PersonalCalibration.Analyze(Sample(),baseline);Require(result.Success);
            var settings=result.Settings!;Require(settings.NoiseMix==1&&!settings.NoiseAutoEnabled&&settings.NoiseEnabled);
            Require(settings.HighpassHz==baseline.HighpassHz&&settings.Bands.Zip(baseline.Bands,(a,b)=>a.GainDb==b.GainDb&&a.Frequency==b.Frequency&&a.Q==b.Q&&a.Type==b.Type).All(x=>x));
            Require(settings.DeesserEnabled==baseline.DeesserEnabled&&settings.SensitivityMode==baseline.SensitivityMode&&settings.SensitivityMaxReductionDb==baseline.SensitivityMaxReductionDb);
            settings.Bands[0].GainDb=0;Require(baseline.Bands[0].GainDb==before.Bands[0].GainDb);
        });
        check("quick calibration retains independent sensitivity when denoising is disabled",()=>{
            var baseline=new AudioSettings{NoiseEnabled=false,SensitivityEnabled=true,SensitivityMode=1,SensitivityHoldMs=450,SensitivityMaxReductionDb=32};
            var result=PersonalCalibration.Analyze(Sample(),baseline);Require(result.Success);
            Require(result.Settings!.SensitivityHoldMs==450&&result.Settings.SensitivityMaxReductionDb==32);
        });
        check("quick calibration rejects incomplete clipped nonfinite silence and DC input",()=>{
            Require(!PersonalCalibration.Analyze(Sample()[..^480]).Success);
            Require(!PersonalCalibration.Analyze(new float[480000]).Success);
            Require(!PersonalCalibration.Analyze(Enumerable.Repeat(.08f,480000).ToArray()).Success);
            var sample=Sample();sample[100000]=float.PositiveInfinity;Require(PersonalCalibration.Analyze(sample).Error=="autoInvalidAudio");
            sample=Sample();Array.Fill(sample,1,100000,40);Require(PersonalCalibration.Analyze(sample).Error=="calibrationClipped");
        });
        check("quick speech verification rejects non speech and contaminated room without extending capture",()=>{
            var result=PersonalCalibration.Analyze(Sample());Require(result.Success);
            var probabilities=new float[1000];Require(PersonalCalibration.VerifySpeech(result,probabilities).Error=="calibrationNoSpeech");
            Array.Fill(probabilities,.8f,240,740);Require(PersonalCalibration.VerifySpeech(result,probabilities).Success);
            Array.Fill(probabilities,.8f,40,70);Require(PersonalCalibration.VerifySpeech(result,probabilities).Error=="autoAmbientUnstable");
            Require(PersonalCalibration.VerifySpeech(result,new float[2000]).Error=="autoInvalidAudio");
            probabilities[500]=float.NaN;Require(PersonalCalibration.VerifySpeech(result,probabilities).Error=="autoInvalidAudio");
        });
        check("quick recommendation can apply undo and retain other microphone calibrations",()=>{
            var state=new UserState{InputId="current",OutputId="cable"};state.Calibrations["other"]=new(-64,-23,DateTimeOffset.UnixEpoch);
            var before=state.Settings.Clone();var receipt=PersonalCalibrationChange.Apply(state,"current",PersonalCalibration.Analyze(Sample(),state.Settings),"Quick");
            Require(state.Profiles.Count==1&&state.Calibrations["current"].TunedSettings is not null&&state.OutputId=="cable");
            receipt.Undo(state);Require(state.Profiles.Count==0&&!state.Calibrations.ContainsKey("current")&&state.Calibrations.ContainsKey("other")&&state.Settings.HighpassHz==before.HighpassHz);
        });
    }
    private static void Require(bool condition){if(!condition)throw new InvalidOperationException("Quick calibration contract failed");}
    private static float[] Sample(float amplitude=.075f)
    {
        var result=new float[PersonalCalibration.QuickSeconds*AudioSamples.Rate];var random=new Random(93);
        for(int i=0;i<result.Length;i++){
            double t=i/(double)AudioSamples.Rate;
            double level=t<2?0:amplitude*(.75+.25*Math.Sin(t*4));
            result[i]=(float)(level*(Math.Sin(t*2*Math.PI*170)+.35*Math.Sin(t*2*Math.PI*900)+.15*Math.Sin(t*2*Math.PI*2800))+.0005*(random.NextDouble()-.5));
        }
        return result;
    }
}
