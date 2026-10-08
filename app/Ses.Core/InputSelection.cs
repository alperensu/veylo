namespace Ses.Core;
public static class InputSelection
{
    public static AudioDevice? Choose(IEnumerable<AudioDevice> devices,string savedId)
    {
        var inputs=devices.Where(d=>d.Input&&!d.IsSesVirtual).ToArray();
        if(savedId.Length>0)return inputs.FirstOrDefault(d=>d.Id==savedId);
        // Known cable/mixer endpoints are not suitable first-run physical microphones.
        // They remain selectable explicitly; a saved device is never substituted.
        var suitable=inputs.Where(d=>!new[]{"CABLE","VB-Audio","VoiceMeeter","Stereo Mix","Stereo Karışım"}.Any(name=>d.Name.Contains(name,StringComparison.OrdinalIgnoreCase))).ToArray();
        return suitable.FirstOrDefault(d=>d.Default)??suitable.FirstOrDefault();
    }
}
