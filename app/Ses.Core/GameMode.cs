namespace Ses.Core;

public sealed record GameObservation(string? ProcessName,bool Fullscreen=false);

// Pure policy: process names are metadata only, never paths, commands or audio inputs.
public sealed class GameModePolicy
{
    private static readonly HashSet<string> Known=new(StringComparer.OrdinalIgnoreCase){
        "VALORANT-Win64-Shipping","cs2","League of Legends","FortniteClient-Win64-Shipping",
        "r5apex","Overwatch","RocketLeague","GTA5","GTA5_Enhanced","Cyberpunk2077",
        "eldenring","Minecraft.Windows","RainbowSix","RainbowSix_Vulkan","RainbowSix_DX11",
        "TslGame","DeadByDaylight-Win64-Shipping","dota2","Warframe.x64","RustClient",
        "EscapeFromTarkov","helldivers2","Discovery","bf2042","cod","HogwartsLegacy",
        "Palworld-Win64-Shipping","Hades","Hades2","RDR2","BlackMythWukong","witcher3"
    };
    private static readonly HashSet<string> Excluded=new(StringComparer.OrdinalIgnoreCase){
        "Veylo","Veylo.DriverSetup","SES","SES.DriverSetup","explorer","dwm","ApplicationFrameHost","SearchHost",
        "StartMenuExperienceHost","LockApp","SystemSettings","chrome","msedge","firefox",
        "brave","opera","Discord","steam","EpicGamesLauncher","RiotClientServices",
        "RiotClientUx","WindowsTerminal","powershell","pwsh","cmd","Code","devenv",
        "vlc","mpv","Spotify","obs64","WINWORD","EXCEL","POWERPNT","Teams","ms-teams"
    };
    private double lastSeen=double.NegativeInfinity;
    public bool Active{get;private set;}
    public string DetectedName{get;private set;}="";
    public static string Normalize(string name)=>name.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)?name[..^4]:name;
    public static ReadOnlySpan<char> Normalize(ReadOnlySpan<char> name)=>name.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)?name[..^4]:name;
    public static bool ValidProcessName(string? name)=>ValidProcessName(name.AsSpan());
    public static bool ValidProcessName(ReadOnlySpan<char> name)
    {
        if(name.Length is not (>0 and <=96)||name[0]=='.'||name[^1]==' ')return false;
        foreach(char c in name)if(!char.IsLetterOrDigit(c)&&c is not ('-' or '_' or '.' or ' '))return false;
        return true;
    }
    private static bool CustomMatch(ReadOnlySpan<char> name,IReadOnlyList<string> custom)
    {
        // Match .exe suffixes without allocating a normalized string for every
        // candidate or a captured predicate for every background process.
        for(int i=0;i<custom.Count;++i){
            if(Normalize(custom[i].AsSpan()).Equals(name,StringComparison.OrdinalIgnoreCase))return true;
        }
        return false;
    }
    // Both native polling and observation updates use the same validation and precedence.
    public static bool Matches(ReadOnlySpan<char> processName,bool fullscreen,IReadOnlyList<string> custom)
    {
        if(!ValidProcessName(processName))return false;
        var name=Normalize(processName);
        return Known.GetAlternateLookup<ReadOnlySpan<char>>().Contains(name)||CustomMatch(name,custom)||
            (fullscreen&&!Excluded.GetAlternateLookup<ReadOnlySpan<char>>().Contains(name));
    }
    public static void ValidateNames(List<string>? names){if(names is null||names.Count>20||names.Any(n=>!ValidProcessName(n))||names.Select(Normalize).Distinct(StringComparer.OrdinalIgnoreCase).Count()!=names.Count)throw new InvalidDataException("Invalid game process names.");}
    public bool Update(bool enabled,IReadOnlyList<GameObservation> observations,IReadOnlyList<string> custom,double now)
    {
        string? match=null;
        if(enabled){
            foreach(var observation in observations){
                if(Matches(observation.ProcessName.AsSpan(),observation.Fullscreen,custom)){match=Normalize(observation.ProcessName!);break;}
            }
        }
        if(match is not null){lastSeen=now;DetectedName=match;Active=true;}
        else if(!enabled||now-lastSeen>=15){Active=false;DetectedName="";lastSeen=double.NegativeInfinity;}
        return Active;
    }
}
