namespace Ses.Core;

// A one-use undo receipt. Application is all-or-nothing with validation before
// state mutation; only the selected device calibration and generated profile
// are touched. Persistence remains the desktop owner's responsibility.
public sealed class PersonalCalibrationChange
{
    private readonly string deviceId,oldProfile;
    private readonly AudioSettings oldSettings;
    private readonly DeviceCalibration? oldCalibration;
    private readonly VoiceProfile addedProfile;
    private bool undone;
    private PersonalCalibrationChange(UserState state,string device,VoiceProfile profile)
    {
        deviceId=device;oldSettings=state.Settings.Clone();oldProfile=state.ActiveProfile;
        oldCalibration=state.Calibrations.TryGetValue(device,out var previous)?previous:null;
        addedProfile=profile;
    }
    public static PersonalCalibrationChange Apply(UserState state,string device,PersonalCalibrationResult result,string baseName)
    {
        if(device.Length==0||device!=state.InputId||device.Length>=512||!result.Success||result.Settings is null||
            !float.IsFinite(result.NoiseFloorDb)||result.NoiseFloorDb < -100||result.NoiseFloorDb > -25||!float.IsFinite(result.SpeechDb))throw new InvalidDataException("Calibration does not match the current microphone.");
        if(state.Profiles.Count>=100||(!state.Calibrations.ContainsKey(device)&&state.Calibrations.Count>=100))throw new InvalidDataException("Profile limit reached.");
        string name=baseName;int suffix=2;
        while(state.Profiles.Any(p=>string.Equals(p.Name,name,StringComparison.OrdinalIgnoreCase)))name=baseName+" "+suffix++;
        var profile=new VoiceProfile{Name=name,Settings=result.Settings.Clone()};Profiles.Serialize(profile);
        var receipt=new PersonalCalibrationChange(state,device,profile);
        state.Settings=profile.Settings.Clone();state.Profiles.Add(profile);state.ActiveProfile="user:"+name;
        state.Calibrations[device]=new(result.NoiseFloorDb,result.SpeechDb,DateTimeOffset.UtcNow,profile.Settings.Clone());
        return receipt;
    }
    public void Undo(UserState state)
    {
        if(undone)throw new InvalidOperationException("Calibration already undone.");
        if(state.InputId!=deviceId)throw new InvalidDataException("Microphone changed.");
        state.Settings=oldSettings.Clone();state.ActiveProfile=oldProfile;state.Profiles.Remove(addedProfile);
        if(oldCalibration is null)state.Calibrations.Remove(deviceId);else state.Calibrations[deviceId]=oldCalibration;
        undone=true;
    }
}
