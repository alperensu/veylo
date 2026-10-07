using Ses.Core;
using System.Text;

int checks = 0, failures = 0;
void Check(string name, Action test) { checks++; try { test(); Console.WriteLine("PASS " + name); } catch (Exception ex) { failures++; Console.WriteLine("FAIL " + name + ": " + ex.Message); } }
void Assert(bool value) { if (!value) throw new Exception("assertion failed"); }
void Reject(Action test) { try { test(); } catch (InvalidDataException) { return; } throw new Exception("invalid input accepted"); }
Check("four factory profiles are independently editable", () => { var a=Profiles.Factory(); var b=Profiles.Factory(); Assert(a.Count==4); a[0].Settings.Bands[0].GainDb=7; Assert(b[0].Settings.Bands[0].GainDb==0); });
Check("shared preset contains no local device state", () => { var text=Profiles.Serialize(Profiles.Factory()[0]); Assert(!text.Contains("device",StringComparison.OrdinalIgnoreCase)); Assert(Profiles.Deserialize(text).Settings.HighpassHz==80); });
Check("reject unsupported profile version", () => Reject(()=>Profiles.Deserialize("{\"schemaVersion\":999,\"name\":\"x\",\"settings\":{}}")));
Check("reject incomplete profile", () => Reject(()=>Profiles.Deserialize("{\"schemaVersion\":1,\"name\":\"x\"}")));
Check("reject oversized profile", () => Reject(()=>Profiles.Deserialize(new string(' ',65537))));
Check("reject malformed JSON", () => Reject(()=>Profiles.Deserialize("{broken")));
Check("reject null and duplicate preset settings", () => { Reject(()=>Profiles.Deserialize("{\"schemaVersion\":1,\"name\":\"x\",\"settings\":null}"));Reject(()=>Profiles.Deserialize("{\"schemaVersion\":1,\"name\":\"x\",\"settings\":{},\"settings\":{}}")); });
Check("local null profile recovers safely",()=>{var root=Path.Combine(Path.GetTempPath(),"SES-tests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);try{File.WriteAllText(Path.Combine(root,"state.json"),"{\"Profiles\":[null]}");var store=new UserStore(root);Assert(store.Load().Profiles.Count==0&&store.LoadWarning);}finally{Directory.Delete(root,true);}});
Check("reject unsafe gain", () => { var p=Profiles.Factory()[0]; p.Settings.MaxGainDb=100; Reject(()=>Profiles.Serialize(p)); });
Check("reject non-finite frequency", () => { var p=Profiles.Factory()[0]; p.Settings.Bands[0].Frequency=float.NaN; Reject(()=>Profiles.Serialize(p)); });
Check("invalid edited settings clone fails as validation error",()=>{var s=new AudioSettings();s.Bands[0].Frequency=float.NaN;Reject(()=>s.Clone());});
Check("comparison removes actual RNNoise delay",()=>{var raw=new float[5000];raw[1000]=.1f;var processed=new float[5000];processed[1960]=.1f;var matched=AudioSamples.Match(raw,processed);Assert(matched.Raw.Length==4040&&matched.Raw[1000]==matched.Processed[1000]);});
Check("reject invalid EQ band count", () => { var p=Profiles.Factory()[0]; p.Settings.Bands=[]; Reject(()=>Profiles.Serialize(p)); });
Check("level matching cannot clip or inflate silence", () => { var a=Enumerable.Repeat(.5f,48000).ToArray();var b=Enumerable.Repeat(.1f,48000).ToArray();var pair=AudioSamples.Match(a,b);Assert(Math.Abs(pair.Raw[100]-pair.Processed[100])<.001f);Assert(pair.Raw.Max()<.891252f);var zero=AudioSamples.Match(new float[1000],new float[1000]);Assert(zero.Raw.All(x=>x==0)); });
Check("WAV encoding is bounded PCM", () => { var bytes=AudioSamples.Wave([float.NaN,4,-4,0]); Assert(Encoding.ASCII.GetString(bytes,0,4)=="RIFF");Assert(bytes.Length==52); Assert(BitConverter.ToInt16(bytes,46)==32767); });
Check("calibration rejects clipped input", () => { var x=new float[720000];for(int i=240000;i<x.Length;i++)x[i]=1;Assert(!Calibration.Analyze(x).Success); });
Check("calibration rejects silence", () => Assert(!Calibration.Analyze(new float[720000]).Success));
Check("calibration accepts adequate speech", () => { var x=new float[720000];for(int i=240000;i<x.Length;i++)x[i]=.1f*(float)Math.Sin(i*.025);var r=Calibration.Analyze(x);Assert(r.Success);Assert(r.NoiseFloorDb<=-60);Assert(Math.Abs(r.SpeechDb+23)<2); });
Check("local state roundtrip retains device calibration",()=>{var root=Path.Combine(Path.GetTempPath(),"SES-tests-"+Guid.NewGuid().ToString("N"));try{var store=new UserStore(root);var state=new UserState();state.Calibrations["test-device"]=new(-65,-23,DateTimeOffset.UnixEpoch);store.Save(state);Assert(store.Load().Calibrations["test-device"].NoiseFloorDb==-65);}finally{Directory.Delete(root,true);}});
Check("corrupt local state recovers without overwriting original",()=>{var root=Path.Combine(Path.GetTempPath(),"SES-tests-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);try{File.WriteAllText(Path.Combine(root,"state.json"),"broken");var store=new UserStore(root);Assert(store.Load().Settings.TargetDb==-20&&store.LoadWarning);Assert(File.ReadAllText(Path.Combine(root,"state.json"))=="broken");}finally{Directory.Delete(root,true);}});
if(args.Length>0) {
using var engine=new NativeEngine(args[0]);
Check("native wrapper enumerates actual audio endpoints",()=>Assert(engine.Devices().Any(x=>x.Input)));
Check("native wrapper preserves limiter",()=>{var x=Enumerable.Repeat(4f,48000).ToArray();var settings=new AudioSettings { NoiseEnabled=false,AgcEnabled=false,CompressorRatio=1 };var y=engine.Process(x,settings);Assert(y.All(n=>float.IsFinite(n)&&Math.Abs(n)<=.891252f));});
Check("native wrapper rejects unsafe settings",()=>Reject(()=>engine.Process(new float[480],new AudioSettings { MaxGainDb=999 })));
Check("missing device cannot fall back to another microphone",()=>{try{engine.Start("nonexistent-endpoint",null);throw new Exception("unexpected fallback");}catch(IOException){}Assert(engine.Metrics().Running==0&&engine.Metrics().Connected==0);});
}
Console.WriteLine($"{checks} tests, {failures} failures");return failures==0?0:1;


