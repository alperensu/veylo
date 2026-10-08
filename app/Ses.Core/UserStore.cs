using System.Text.Json;
namespace Ses.Core;
public sealed record DeviceCalibration(float NoiseFloorDb,float SpeechDb,DateTimeOffset CreatedAt,AudioSettings? TunedSettings=null);
public sealed class UserState
{
    public int Version {get;set;}=1;
    public string Language {get;set;}="tr";
    public string InputId {get;set;}="";
    public string OutputId {get;set;}="";
    public string OutputMode {get;set;}="cable";
    public string MuteKey {get;set;}="M";
    public string BypassKey {get;set;}="B";
    public int TalkMode {get;set;}=0;
    public string HoldKey {get;set;}="T";
    public bool PresetKeysEnabled {get;set;}
    public string ActiveProfile {get;set;}="natural";
    public bool GameModeEnabled {get;set;}=true;
    public bool EffectsEnabled {get;set;}=true;
    public List<string> GameProcessNames {get;set;}=[];
    public AudioSettings Settings {get;set;}=new();
    public List<VoiceProfile> Profiles {get;set;}=[];
    public Dictionary<string,DeviceCalibration> Calibrations {get;set;}=[];
}
public sealed class UserStore
{
    private readonly string directory;
    private readonly string file;
    public bool LoadWarning {get;private set;}
    // Keep the legacy data location so Veylo retains existing profiles/calibrations.
    public UserStore(string? root=null){directory=root??Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"SES");file=Path.Combine(directory,"state.json");}
    public UserState Load()
    {
        try {
            if(!File.Exists(file))return new();if(new FileInfo(file).Length>1024*1024)throw new InvalidDataException("Saved settings are too large.");
            var s=JsonSerializer.Deserialize<UserState>(File.ReadAllText(file),new JsonSerializerOptions{MaxDepth=16})??throw new InvalidDataException();Validate(s);return s;
        }catch(Exception e)when(e is IOException or UnauthorizedAccessException or JsonException or InvalidDataException or ArgumentException){LoadWarning=true;return new(){OutputMode="local"};}
    }
    private static void Validate(UserState s)
    {
        if(s.Version!=1||s.Language is not("tr" or "en")||s.InputId is null||s.OutputId is null||s.InputId.Length>=512||s.OutputId.Length>=512||s.ActiveProfile is null||s.ActiveProfile.Length>96||s.ActiveProfile.Any(char.IsControl)||s.Settings is null||s.Profiles is null||s.Calibrations is null||s.Profiles.Count>100||s.Calibrations.Count>100)throw new InvalidDataException("Invalid saved state.");
        OutputRouting.ValidateMode(s.OutputMode);
        GameModePolicy.ValidateNames(s.GameProcessNames);
        s.Settings.Validate();foreach(var p in s.Profiles)Profiles.Serialize(p);
        new ShortcutSettings(s.MuteKey,s.BypassKey,s.TalkMode,s.HoldKey,s.PresetKeysEnabled).Validate();
        foreach(var pair in s.Calibrations)if(pair.Key.Length>=512||pair.Value is null||!float.IsFinite(pair.Value.NoiseFloorDb)||pair.Value.NoiseFloorDb < -120||pair.Value.NoiseFloorDb > -15||!float.IsFinite(pair.Value.SpeechDb))throw new InvalidDataException("Invalid calibration.");
        foreach(var calibration in s.Calibrations.Values)calibration.TunedSettings?.Validate();
    }
    public static bool ValidKey(string key)=>key is {Length:1} && key[0] is >= 'A' and <= 'Z';
    public void Save(UserState state)
    {
        Validate(state);string text=JsonSerializer.Serialize(state,new JsonSerializerOptions{WriteIndented=true});if(System.Text.Encoding.UTF8.GetByteCount(text)>1024*1024)throw new InvalidDataException("Saved state exceeds limit.");
        Directory.CreateDirectory(directory);string temp=Path.Combine(directory,"state."+Guid.NewGuid().ToString("N")+".tmp");
        try{File.WriteAllText(temp,text);File.Move(temp,file,true);}finally{if(File.Exists(temp))File.Delete(temp);}
    }
}
