using Ses.Core;

public static class ProfileSoundChecks
{
    private static readonly int[] ProbeFrequencies=[100,170,350,600,1400,3000,6000,10000];

    public static void Run(Action<string,Action> check,string nativeDirectory)
    {
        check("factory tones preserve identifiers independent settings and preset compatibility",Contracts);
        check("native factory EQ has distinct level-matched spectral shapes",()=>ToneShapes(nativeDirectory));
        check("full native factory chains remain distinct finite and limited",()=>FullChains(nativeDirectory));
        check("same native engine applies consecutive profile updates and keeps bypass distinct",()=>ProfileUpdates(nativeDirectory));
    }

    private static void Require(bool value,string message)
    {
        if(!value)throw new InvalidOperationException(message);
    }

    private static void Contracts()
    {
        var profiles=Profiles.Factory();
        Require(profiles.Select(p=>p.FactoryId).SequenceEqual(new[]{"natural","clear","warm","broadcast","podcast"}),"Factory identifiers or ordering changed.");
        Require(profiles.All(p=>p.SchemaVersion==1&&p.Settings.OutputDb==0),"Profiles must retain schema 1 without an output loudness boost.");
        var natural=profiles[0].Settings;
        Require(natural.HighpassHz==80&&natural.NoiseMix==.65f&&natural.TargetDb==-20&&natural.Bands.All(b=>b.GainDb==0),"Natural reference changed.");
        foreach(var profile in profiles){profile.Settings.Validate();Require(Profiles.Serialize(Profiles.Deserialize(Profiles.Serialize(profile)))==Profiles.Serialize(profile),"Preset roundtrip changed settings.");}
        profiles[1].Settings.Bands[0].GainDb=8;
        Require(Profiles.Factory()[1].Settings.Bands[0].GainDb==-3&&profiles[0].Settings.Bands[0].GainDb==0,"Factory settings share mutable instances.");
        const string legacy="""
            {"schemaVersion":1,"name":"Saved warm","factoryId":"warm","settings":{"highpassHz":70,"bands":[{"type":1,"frequency":180,"gainDb":2,"q":0.707},{"type":0,"frequency":600,"gainDb":0,"q":1},{"type":0,"frequency":3000,"gainDb":0,"q":1},{"type":2,"frequency":8000,"gainDb":0,"q":0.707}]}}
            """;
        var saved=Profiles.Deserialize(legacy);
        Require(saved.Settings.HighpassHz==70&&saved.Settings.Bands[0].GainDb==2&&saved.Settings.Bands[2].GainDb==0,"Import rewrote a saved older tone to the new factory sound.");
        Require(Profiles.Deserialize(Profiles.Serialize(saved)).Settings.Bands[0].GainDb==2,"Export lost the saved older tone.");
    }

    private static void ToneShapes(string directory)
    {
        // Isolate the actual native EQ/highpass response from VAD, noise removal
        // and dynamics. This measures timbre; full production chains are below.
        var input=new float[AudioSamples.Rate*3];
        for(int i=0;i<input.Length;i++)foreach(int hz in ProbeFrequencies)
            input[i]+=.0125f*(float)Math.Sin(2*Math.PI*hz*i/AudioSamples.Rate);
        var spectra=new Dictionary<string,double[]>();
        foreach(var profile in Profiles.Factory())
        {
            var tone=profile.Settings.Clone();
            tone.NoiseEnabled=false;tone.AgcEnabled=false;tone.CompressorRatio=1;tone.SensitivityEnabled=false;tone.DeesserEnabled=false;
            using var engine=new NativeEngine(directory);
            var output=engine.Process(input,tone);
            Safe(output,input.Length,profile.FactoryId!);
            // Match RMS over the same settled window before comparing spectra.
            var settled=output.AsSpan(AudioSamples.Rate*2,AudioSamples.Rate).ToArray();
            double rms=AudioSamples.Rms(settled);
            Require(rms>1e-5,"Native EQ produced no measurable signal.");
            spectra[profile.FactoryId!]=ProbeFrequencies.Select(hz=>20*Math.Log10(Magnitude(settled,hz)/rms)).ToArray();
        }
        var ids=spectra.Keys.ToArray();
        for(int a=0;a<ids.Length;a++)for(int b=a+1;b<ids.Length;b++)
        {
            double distance=Math.Sqrt(spectra[ids[a]].Zip(spectra[ids[b]],(x,y)=>(x-y)*(x-y)).Average());
            Console.WriteLine($"TONE {ids[a]}/{ids[b]} RMS-matched spectral distance: {distance:0.00} dB");
            Require(distance>=1,$"{ids[a]} and {ids[b]} have insufficient spectral distinction after level matching ({distance:0.00} dB).");
        }
        double Contrast(string id,int first,int second)=>spectra[id][first]-spectra[id][second]-(spectra["natural"][first]-spectra["natural"][second]);
        Require(Contrast("clear",5,0)>=5,"Clear must emphasize presence over bass.");
        Require(Contrast("warm",0,5)>=5,"Warm must emphasize bass over presence.");
        Require(Contrast("broadcast",5,2)>=5,"Broadcast must separate presence from muddy low mids.");
        Require(Contrast("podcast",0,7)>=3,"Podcast must keep a fuller, softer balance than Natural.");
        Require(Contrast("podcast",5,2)>=5,"Podcast must reduce muddy low mids relative to speech presence.");
    }

    private static double Magnitude(float[] data,int hz)
    {
        double real=0,imaginary=0,step=2*Math.PI*hz/AudioSamples.Rate;
        for(int i=0;i<data.Length;i++){real+=data[i]*Math.Cos(step*i);imaginary-=data[i]*Math.Sin(step*i);}
        return Math.Max(1e-12,2*Math.Sqrt(real*real+imaginary*imaginary)/data.Length);
    }

    private static void ProfileUpdates(string directory)
    {
        // ses_process and WASAPI capture call the same block/settings publication
        // path. Reuse one engine instead of testing only freshly created engines.
        // This does not open an endpoint or inject sound into the user's cable.
        var input=new float[AudioSamples.Rate*3];
        for(int i=0;i<input.Length;i++)foreach(int hz in ProbeFrequencies)
            input[i]+=.0125f*(float)Math.Sin(2*Math.PI*hz*i/AudioSamples.Rate);
        double[] Spectrum(float[] output)
        {
            Safe(output,input.Length,"profile update");
            var settled=output.AsSpan(AudioSamples.Rate*2,AudioSamples.Rate).ToArray();
            double rms=AudioSamples.Rms(settled);
            Require(rms>1e-5,"Profile update unexpectedly silenced the signal.");
            return ProbeFrequencies.Select(hz=>20*Math.Log10(Magnitude(settled,hz)/rms)).ToArray();
        }
        static double Distance(double[] a,double[] b)=>Math.Sqrt(a.Zip(b,(x,y)=>(x-y)*(x-y)).Average());
        var tones=Profiles.Factory().ToDictionary(p=>p.FactoryId!,p=>{
            var s=p.Settings.Clone();s.NoiseEnabled=false;s.AgcEnabled=false;
            s.CompressorRatio=1;s.SensitivityEnabled=false;s.DeesserEnabled=false;return s;
        });
        using var engine=new NativeEngine(directory);
        foreach(string id in new[]{"warm","clear","podcast","broadcast","natural","clear","warm"})
        {
            // Two pending updates verify the latest publication wins before a block.
            engine.Update(tones["natural"]);engine.Update(tones[id]);
            var actual=Spectrum(engine.ProcessConfigured(input));
            using var reference=new NativeEngine(directory);
            var expected=Spectrum(reference.Process(input,tones[id]));
            double distance=Distance(actual,expected);
            Console.WriteLine($"UPDATE {id}: settled spectral distance from fresh engine {distance:0.000} dB");
            Require(distance<.1,$"Runtime update to {id} failed to converge to its factory tone.");
        }
        engine.Update(tones["clear"],bypass:true);
        var bypassClear=Spectrum(engine.ProcessConfigured(input));
        engine.Update(tones["warm"],bypass:true);
        var bypassWarm=Spectrum(engine.ProcessConfigured(input));
        Require(Distance(bypassClear,bypassWarm)<.01,"Bypass unexpectedly applied profile tone.");
        engine.Update(tones["warm"],bypass:false);
        Require(Distance(bypassWarm,Spectrum(engine.ProcessConfigured(input)))>1,"Returning from bypass did not restore profile tone.");
        engine.Update(tones["clear"],muted:true,bypass:true);
        Require(engine.ProcessConfigured(input).All(x=>x==0),"Mute was lost when changing a bypassed profile.");
        Require(engine.Metrics().Running==0,"Profile update test opened an audio stream.");
    }

    private static void FullChains(string directory)
    {
        // Deterministic speech-like harmonics, formants and a quiet chirp keep
        // this offline fixture broad without treating it as human listening QA.
        var input=new float[AudioSamples.Rate*6];var random=new Random(1607);
        for(int i=0;i<input.Length;i++)
        {
            double t=i/(double)AudioSamples.Rate;
            double envelope=.055*(.55+.45*Math.Pow(Math.Sin(Math.PI*2.7*t),2));
            double voice=0;
            for(int harmonic=1;harmonic<=48;harmonic++)
            {
                double hz=125*harmonic;
                double formant=1+2*Math.Exp(-Math.Pow((hz-700)/220,2))+1.5*Math.Exp(-Math.Pow((hz-2600)/600,2));
                voice+=Math.Sin(2*Math.PI*hz*t+.035*harmonic*Math.Sin(2*Math.PI*4*t))*formant/Math.Pow(harmonic,.85);
            }
            input[i]=(float)(envelope*voice+.003*Math.Sin(2*Math.PI*(160*t+700*t*t))+.0005*(random.NextDouble()-.5));
            if(i>=AudioSamples.Rate*5&&i<AudioSamples.Rate*5+480)input[i]*=24;
        }
        var outputs=new Dictionary<string,float[]>();
        foreach(var profile in Profiles.Factory())
        {
            using var engine=new NativeEngine(directory);
            var output=engine.Process(input,profile.Settings);
            Safe(output,input.Length,profile.FactoryId!);
            Require(engine.Metrics().Running==0,"Offline factory test opened an audio stream.");
            var settled=output.AsSpan(AudioSamples.Rate,AudioSamples.Rate*3).ToArray();
            double rms=AudioSamples.Rms(settled);
            Require(rms>1e-5,$"Full {profile.FactoryId} chain unexpectedly silenced the fixture.");
            for(int i=0;i<settled.Length;i++)settled[i]/=(float)rms;
            outputs[profile.FactoryId!]=settled;
        }
        var ids=outputs.Keys.ToArray();
        for(int a=0;a<ids.Length;a++)for(int b=a+1;b<ids.Length;b++)
        {
            double difference=Math.Sqrt(outputs[ids[a]].Zip(outputs[ids[b]],(x,y)=>(double)(x-y)*(x-y)).Average());
            Console.WriteLine($"CHAIN {ids[a]}/{ids[b]} RMS-matched waveform distance: {difference:0.000}");
            Require(difference>.03,$"Full {ids[a]}/{ids[b]} output remained effectively identical after level matching.");
        }
    }

    private static void Safe(float[] output,int length,string id)
    {
        Require(output.Length==length&&output.All(x=>float.IsFinite(x)&&Math.Abs(x)<=.891252f),$"{id} violated the finite output / -1 dBFS limiter contract.");
    }
}
