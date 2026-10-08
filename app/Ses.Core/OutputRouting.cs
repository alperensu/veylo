namespace Ses.Core;

public sealed record OutputRoute(string Mode,string Id,string Name,bool Available=true);

public static class OutputRouting
{
    public static bool IsCable(AudioDevice device)=>!device.Input&&!device.IsSesVirtual&&device.Name.StartsWith("CABLE Input",StringComparison.OrdinalIgnoreCase);

    public static bool CanUseInput(AudioDevice? input,OutputRoute route)=>input is null?route.Mode!="cable":!input.IsSesVirtual&&!(route.Mode=="cable"&&input.Name.StartsWith("CABLE Output",StringComparison.OrdinalIgnoreCase));

    public static OutputRoute[] Choices(IEnumerable<AudioDevice> devices,string savedId,string missingLabel,string driverLabel,string localLabel)
    {
        var cables=devices.Where(IsCable).Select(d=>new OutputRoute("cable",d.Id,d.Name)).ToList();
        // Keep a missing saved endpoint instead of silently choosing another cable.
        if(cables.Count==0||savedId.Length>0&&!cables.Any(d=>d.Id==savedId))cables.Add(new("cable",savedId,missingLabel,false));
        cables.Add(new("driver","",driverLabel));
        cables.Add(new("local","",localLabel));
        return cables.ToArray();
    }

    public static OutputRoute Choose(IEnumerable<OutputRoute> routes,string mode,string savedId)
    {
        ValidateMode(mode);
        return routes.First(d=>d.Mode==mode&&(mode!="cable"||savedId.Length==0||d.Id==savedId));
    }

    public static uint EffectiveKind(OutputRoute route)=>route.Mode=="driver"?1u:route.Mode=="cable"&&route.Available?2u:0u;

    public static bool NeedsRefresh(OutputRoute route,uint outputKind,uint connected)=>route.Mode=="cable"&&(!route.Available||outputKind!=EffectiveKind(route)||connected==0);

    public static void ValidateMode(string mode)
    {
        if(mode is not("cable" or "driver" or "local"))throw new InvalidDataException("Invalid output mode.");
    }
}
