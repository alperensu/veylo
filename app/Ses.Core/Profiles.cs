using System.Text.Json;
using System.Text.Json.Serialization;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Ses.Core;

public sealed class EqBand : INotifyPropertyChanged
{
    private int type;private float frequency,gainDb,q=1;
    public int Type {get=>type;set=>Set(ref type,value);}
    public float Frequency {get=>frequency;set=>Set(ref frequency,value);}
    public float GainDb {get=>gainDb;set=>Set(ref gainDb,value);}
    public float Q {get=>q;set=>Set(ref q,value);}
    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field,T value,[CallerMemberName]string? property=null){if(EqualityComparer<T>.Default.Equals(field,value))return;field=value;PropertyChanged?.Invoke(this,new(property));}
}
public sealed class AudioSettings
{
    public bool NoiseEnabled { get; set; } = true;
    public bool NoiseAutoEnabled { get; set; }
    public bool SensitivityEnabled { get; set; }
    public bool SensitivityAutoEnabled { get; set; } = true;
    public float SensitivityThresholdDb { get; set; } = -50;
    public int SensitivityMode { get; set; }
    public float SensitivityAttackMs { get; set; } = 2;
    public float SensitivityHoldMs { get; set; } = 300;
    public float SensitivityReleaseMs { get; set; } = 120;
    public float SensitivityHysteresisDb { get; set; } = 6;
    public float SensitivityRatio { get; set; } = 2;
    public float SensitivityMaxReductionDb { get; set; } = 24;
    public bool AgcEnabled { get; set; } = true;
    public bool DeesserEnabled { get; set; }
    public float HighpassHz { get; set; } = 80;
    public float NoiseMix { get; set; } = .65f;
    public float TargetDb { get; set; } = -20;
    public float MinGainDb { get; set; } = -12;
    public float MaxGainDb { get; set; } = 12;
    public float CompressorThresholdDb { get; set; } = -18;
    public float CompressorRatio { get; set; } = 2;
    public float AttackMs { get; set; } = 10;
    public float ReleaseMs { get; set; } = 120;
    public float KneeDb { get; set; } = 6;
    public float DeesserMaxDb { get; set; } = 3;
    public float OutputDb { get; set; }
    public float SpeechThreshold { get; set; } = .55f;
    public EqBand[] Bands { get; set; } =
    [
        new() { Type=1, Frequency=180, Q=.707f },
        new() { Type=0, Frequency=600 },
        new() { Type=0, Frequency=3000 },
        new() { Type=2, Frequency=8000, Q=.707f }
    ];
    public AudioSettings Clone() { Validate();return JsonSerializer.Deserialize<AudioSettings>(JsonSerializer.Serialize(this))!; }
    public void Validate()
    {
        static void Range(float v,float lo,float hi) { if(!float.IsFinite(v)||v<lo||v>hi) throw new InvalidDataException("Preset contains an out-of-range setting."); }
        Range(HighpassHz,20,300);Range(NoiseMix,0,1);Range(TargetDb,-36,-10);Range(MinGainDb,-12,0);Range(MaxGainDb,0,12);
        Range(CompressorThresholdDb,-48,-3);Range(CompressorRatio,1,8);Range(AttackMs,1,100);Range(ReleaseMs,20,1000);
        Range(KneeDb,0,12);Range(DeesserMaxDb,0,3);Range(OutputDb,-24,12);Range(SpeechThreshold,0,1);
        Range(SensitivityThresholdDb,-90,-10);
        if(SensitivityMode is <0 or >1)throw new InvalidDataException("Invalid sensitivity mode.");
        Range(SensitivityAttackMs,.1f,100);Range(SensitivityHoldMs,0,2000);Range(SensitivityReleaseMs,5,2000);
        Range(SensitivityHysteresisDb,0,24);Range(SensitivityRatio,1,8);Range(SensitivityMaxReductionDb,0,60);
        if(Bands is null || Bands.Length!=4) throw new InvalidDataException("A profile must contain four EQ bands.");
        foreach(var b in Bands) { if(b is null||b.Type<0||b.Type>2)throw new InvalidDataException("Invalid EQ band."); Range(b.Frequency,20,20000);Range(b.GainDb,-12,12);Range(b.Q,.2f,10); }
    }
}
public sealed class VoiceProfile
{
    public int SchemaVersion { get; set; } = 1;
    public string Name { get; set; } = "My voice";
    public string Description { get; set; } = "";
    public string? FactoryId { get; set; }
    public AudioSettings Settings { get; set; } = new();
}
public static class Profiles
{
    public const int MaxBytes = 65536;
    private static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy=JsonNamingPolicy.CamelCase,WriteIndented=true,MaxDepth=12,UnmappedMemberHandling=JsonUnmappedMemberHandling.Disallow };
    public static List<VoiceProfile> Factory()
    {
        var natural=new VoiceProfile { Name="Doğal",FactoryId="natural",Description="Hafif işleme. Sesinin doğal karakterini korur." };
        var clear=new VoiceProfile { Name="Net Konuşma",FactoryId="clear",Description="Alt tonları azaltır, konuşma ayrıntısını ve parlaklığı öne çıkarır." };
        clear.Settings.HighpassHz=110;clear.Settings.CompressorRatio=2.5f;clear.Settings.CompressorThresholdDb=-20;
        clear.Settings.Bands=[new(){Type=1,Frequency=180,GainDb=-3,Q=.707f},
            new(){Type=0,Frequency=450,GainDb=-3,Q=.9f},
            new(){Type=0,Frequency=3000,GainDb=4,Q=.9f},
            new(){Type=2,Frequency=8000,GainDb=2,Q=.707f}];
        var warm=new VoiceProfile { Name="Sıcak Ses",FactoryId="warm",Description="Dolgun alt tonlar ve daha yumuşak üst frekanslar." };
        warm.Settings.HighpassHz=65;
        warm.Settings.Bands=[new(){Type=1,Frequency=180,GainDb=4,Q=.707f},
            new(){Type=0,Frequency=450,GainDb=-2,Q=.9f},
            new(){Type=0,Frequency=3000,GainDb=-2,Q=.8f},
            new(){Type=2,Frequency=8000,GainDb=-3,Q=.707f}];
        var broadcast=new VoiceProfile { Name="Yayın",FactoryId="broadcast",Description="Dolgun alt tonlar, belirgin konuşma ve parlak üst tonlarla daha sıkı dinamikler." };
        broadcast.Settings.Bands=[new(){Type=1,Frequency=150,GainDb=3,Q=.707f},
            new(){Type=0,Frequency=350,GainDb=-4,Q=.9f},
            new(){Type=0,Frequency=3000,GainDb=4,Q=1},
            new(){Type=2,Frequency=8000,GainDb=3,Q=.707f}];
        broadcast.Settings.CompressorRatio=3;broadcast.Settings.CompressorThresholdDb=-22;broadcast.Settings.DeesserEnabled=true;
        var podcast=new VoiceProfile { Name="Podcast — Tok ve Net",FactoryId="podcast",Description="Tok alt tonlar, azaltılmış boğukluk, yumuşak üst tonlar ve güçlü gürültü azaltma. Ortam seslerini tamamen silme garantisi yoktur." };
        podcast.Settings=new AudioSettings {
            HighpassHz=70,NoiseEnabled=true,NoiseAutoEnabled=false,NoiseMix=1,
            SensitivityEnabled=true,SensitivityAutoEnabled=true,SensitivityThresholdDb=-50,
            AgcEnabled=true,TargetDb=-18,MinGainDb=-12,MaxGainDb=9,SpeechThreshold=.45f,
            CompressorThresholdDb=-22,CompressorRatio=3.5f,AttackMs=12,ReleaseMs=160,KneeDb=8,
            DeesserEnabled=true,DeesserMaxDb=3,OutputDb=0,
            Bands=[new(){Type=1,Frequency=145,GainDb=4,Q=.707f},
                new(){Type=0,Frequency=350,GainDb=-4,Q=.9f},
                new(){Type=0,Frequency=3000,GainDb=3,Q=1},
                new(){Type=2,Frequency=8000,GainDb=-2,Q=.707f}]
        };
        return [natural,clear,warm,broadcast,podcast];
    }
    private static void Validate(VoiceProfile p)
    {
        if(p is null||p.SchemaVersion!=1||string.IsNullOrWhiteSpace(p.Name)||p.Name.Length>64||p.Name.Any(char.IsControl)||p.Description is null||p.Description.Length>256||p.Settings is null)
            throw new InvalidDataException("Invalid or incompatible preset.");
        if(p.FactoryId is not null && (p.FactoryId.Length>32 || p.FactoryId.Any(c=>!char.IsAsciiLetterOrDigit(c)&&c!='-'))) throw new InvalidDataException("Invalid factory identifier.");
        p.Settings.Validate();
    }
    public static string Serialize(VoiceProfile p) { Validate(p); return JsonSerializer.Serialize(p,Options); }
    public static VoiceProfile Deserialize(string text)
    {
        if(System.Text.Encoding.UTF8.GetByteCount(text)>MaxBytes)throw new InvalidDataException("Preset exceeds 64 KB.");
        try {
            using var document=JsonDocument.Parse(text,new JsonDocumentOptions { MaxDepth=12 });
            var root=document.RootElement;
            UniqueProperties(root);
            if(root.ValueKind!=JsonValueKind.Object||!root.TryGetProperty("settings",out var s)||s.ValueKind!=JsonValueKind.Object||!root.TryGetProperty("schemaVersion",out _))
                throw new InvalidDataException("Incomplete preset.");
            var p=JsonSerializer.Deserialize<VoiceProfile>(text,Options) ?? throw new InvalidDataException("Empty preset.");
            Validate(p);return p;
        } catch(JsonException ex){throw new InvalidDataException("Preset is not valid JSON.",ex);}
    }
    private static void UniqueProperties(JsonElement node)
    {
        if(node.ValueKind==JsonValueKind.Object){var names=new HashSet<string>(StringComparer.Ordinal);foreach(var property in node.EnumerateObject()){if(!names.Add(property.Name))throw new InvalidDataException("Duplicate preset property.");UniqueProperties(property.Value);}}
        else if(node.ValueKind==JsonValueKind.Array)foreach(var item in node.EnumerateArray())UniqueProperties(item);
    }
    public static VoiceProfile Load(string path) { if(new FileInfo(path).Length>MaxBytes)throw new InvalidDataException("Preset exceeds 64 KB.");return Deserialize(File.ReadAllText(path)); }
}
