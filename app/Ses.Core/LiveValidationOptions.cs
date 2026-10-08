using System.Globalization;

namespace Ses.Core;

// Developer-only validation options. The desktop always runs this mode muted.
public sealed record LiveValidationOptions(int DurationSeconds,bool RequireCable,bool LowOverhead=false)
{
    public int PollIntervalMilliseconds=>LowOverhead?1000:100;
    public int ProgressIntervalSeconds=>LowOverhead?30:10;

    public static LiveValidationOptions Parse(string[] args)
    {
        int seconds=30;bool found=false,lowOverhead=false;
        for(int i=0;i<args.Length;i++){
            if(args[i]=="--validate-low-overhead"){
                if(lowOverhead)throw new InvalidDataException("Low-overhead validation must be specified once.");
                lowOverhead=true;
                continue;
            }
            if(args[i]!="--validate-duration-seconds")continue;
            if(found||++i>=args.Length||!int.TryParse(args[i],NumberStyles.None,CultureInfo.InvariantCulture,out seconds)||seconds is <1 or >3600)
                throw new InvalidDataException("Validation duration must be an integer between 1 and 3600 seconds, specified once.");
            found=true;
        }
        if(lowOverhead&&!args.Contains("--validate-live",StringComparer.Ordinal))
            throw new InvalidDataException("Low-overhead validation requires --validate-live.");
        return new(seconds,args.Contains("--validate-cable",StringComparer.Ordinal),lowOverhead);
    }
}
