namespace Ses.Core;

public sealed record ShortcutSettings(string MuteKey="M",string BypassKey="B",int TalkMode=0,string HoldKey="T",bool PresetKeys=false)
{
    public static IReadOnlyList<string> FactoryIds {get;}=Array.AsReadOnly(new[]{"natural","clear","warm","broadcast","podcast"});
    public void Validate()
    {
        if(!UserStore.ValidKey(MuteKey)||!UserStore.ValidKey(BypassKey)||!UserStore.ValidKey(HoldKey)||MuteKey==BypassKey||TalkMode is <0 or >2||
           (TalkMode!=0&&(HoldKey==MuteKey||HoldKey==BypassKey)))throw new InvalidDataException("Invalid shortcuts.");
    }
    public Dictionary<int,string> Bindings()
    {
        Validate();var keys=new Dictionary<int,string>{{MuteKey[0],"mute"},{BypassKey[0],"bypass"}};
        if(TalkMode!=0)keys.Add(HoldKey[0],"hold");
        if(PresetKeys)for(int i=0;i<FactoryIds.Count;i++)keys.Add('1'+i,FactoryIds[i]);
        return keys;
    }
    public static bool Muted(int mode,bool held,bool manualMute)=>manualMute||mode==1&&!held||mode==2&&held;
}

// Reserve new chords before releasing old ones; a conflict leaves the working set intact.
public sealed class HotkeyRegistry : IDisposable
{
    private readonly Func<int,int,bool> register;
    private readonly Action<int> unregister;
    private Dictionary<int,(int Key,string Action)> active=[];
    public HotkeyRegistry(Func<int,int,bool> register,Action<int> unregister){this.register=register;this.unregister=unregister;}
    public bool Apply(ShortcutSettings settings)
    {
        var wanted=settings.Bindings();var next=new Dictionary<int,(int Key,string Action)>();var reserved=new List<int>();
        foreach(var pair in wanted)
        {
            int id=active.FirstOrDefault(x=>x.Value.Key==pair.Key).Key;
            if(id==0)
            {
                id=Enumerable.Range(1,32).First(x=>!active.ContainsKey(x)&&!next.ContainsKey(x));
                if(!register(id,pair.Key)){foreach(int added in reserved)unregister(added);return false;}
                reserved.Add(id);
            }
            next.Add(id,(pair.Key,pair.Value));
        }
        foreach(int old in active.Keys)if(!next.ContainsKey(old))unregister(old);
        active=next;return true;
    }
    public string? ActionFor(int id)=>active.TryGetValue(id,out var value)?value.Action:null;
    public void Dispose(){foreach(int id in active.Keys)unregister(id);active.Clear();}
}
