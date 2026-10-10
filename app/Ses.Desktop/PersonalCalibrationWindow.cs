using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Ses.Core;

namespace Ses.Desktop;

public sealed record CalibrationSettingRow(string Name,string Before,string After);
public partial class MainWindow
{
    private bool personalCalibrating;
    private bool personalDetailed;
    private AudioSettings? calibrationBaseline;
    private PersonalCalibrationResult? calibrationSuggestion;
    private PersonalCalibrationChange? calibrationUndo;
    private string calibrationDeviceId="",calibrationDeviceName="";
    private MatchedSample? suggestionSample;
    private uint calibrationUnderruns,calibrationOverruns;

    private async void PersonalCalibrateClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling||quitting)return;
        if(InputBox.SelectedItem is not AudioDevice device){Status("noInput");return;}
        if(!TryApplySettings())return;
        personalDetailed=DetailedCalibrationBox.IsChecked==true;
        calibrationBaseline=settings.Clone();
        ClearCalibrationSuggestion();personalCalibrating=true;
        calibrationDeviceId=device.Id;calibrationDeviceName=device.Name;
        PersonalProgress.Maximum=PersonalCalibration.Duration(personalDetailed);PersonalProgress.Value=0;
        PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoAmbient");PersonalResultPanel.Visibility=Visibility.Collapsed;
        await BeginSample(true);
        if(quitting)return;
        if(!sampling){personalCalibrating=false;SetBusy(false);}
        else {var metrics=engine.Metrics();calibrationUnderruns=metrics.Underruns;calibrationOverruns=metrics.Overruns;PersonalPhasePanel.Visibility=Visibility.Visible;PersonalTick(metrics);}
    }
    private void CalibrationModeChanged(object sender,RoutedEventArgs e)
    {
        if(PersonalStepsText is null||PersonalCalibrateButton is null)return;
        bool detailed=DetailedCalibrationBox.IsChecked==true;
        PersonalStepsText.SetResourceReference(TextBlock.TextProperty,detailed?"personalDetailedSteps":"personalSteps");
        PersonalCalibrateButton.SetResourceReference(Button.ContentProperty,detailed?"personalDetailedStart":"personalStart");
        if(ready&&!busy&&!sampling)ClearCalibrationSuggestion();
    }
    private async void CancelPersonalCalibrationClick(object sender,RoutedEventArgs e)
        =>await CancelPersonalCalibration(false);
    private async Task CancelPersonalCalibration(bool interrupted)
    {
        if(quitting||busy||!personalCalibrating||!sampling)return;
        SetBusy(true);
        try{
            engine.EndSample();sampling=false;calibrating=false;personalCalibrating=false;
            string message=interrupted?"autoCaptureInterrupted":"autoCancelled";
            rawSample=[];matched=null;PersonalInstruction.SetResourceReference(TextBlock.TextProperty,message);
            PersonalPhrase.SetResourceReference(TextBlock.TextProperty,"personalPosition");PersonalProgress.Value=0;
            CalibrationMessage.Text=T("ambientPrompt");RecordButton.Content=T("record");Status(message);
        }catch(IOException){Status("error");}finally{SetBusy(false);if(!IsVisible)meterTimer.Stop();}
    }
    private void ClearCalibrationSuggestion()
    {
        calibrationSuggestion=null;suggestionSample=null;PersonalResultPanel.Visibility=Visibility.Collapsed;
        PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"personalReady");
        PersonalPhrase.SetResourceReference(TextBlock.TextProperty,"personalPosition");PersonalProgress.Value=0;
        ApplyPersonalButton.IsEnabled=ListenPersonalButton.IsEnabled=ListenPersonalRawButton.IsEnabled=false;
    }
    private async Task AnalyzePersonalSample()
    {
        if(quitting)return;
        PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoAnalyzing");Status("autoAnalyzing");
        float[] sample=rawSample;
        var baseline=calibrationBaseline?.Clone();
        var result=await AwaitOffline(Task.Run(()=>{
            var analysis=PersonalCalibration.Analyze(sample,baseline);
            if(!analysis.Success)return analysis;
            using var offline=new NativeEngine(AppContext.BaseDirectory);
            return PersonalCalibration.VerifySpeech(analysis,offline.SpeechActivity(sample));
        }));
        if(result is not null)ShowPersonalResult(result);
    }
    private void ShowPersonalResult(PersonalCalibrationResult result)
    {
        if(!result.Success){ClearCalibrationSuggestion();PersonalInstruction.SetResourceReference(TextBlock.TextProperty,result.Error);Status(result.Error);return;}
        calibrationSuggestion=result;RefreshPersonalResult();PersonalResultPanel.Visibility=Visibility.Visible;
        PersonalProgress.Maximum=PersonalProgress.Value=PersonalCalibration.Duration(result.Detailed);
        PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoReady");PersonalPhrase.SetResourceReference(TextBlock.TextProperty,"personalPosition");ApplyPersonalButton.IsEnabled=true;
        ListenPersonalButton.IsEnabled=ListenPersonalRawButton.IsEnabled=true;Status("autoReady");
    }
    private void RefreshPersonalResult()
    {
        if(calibrationSuggestion is not {Success:true,Settings:{ } proposed} result)return;
        PersonalMeasurementText.Text=$"{calibrationDeviceName}\n{T("autoNoiseMeasured")}: {result.NoiseFloorDb:0.0} dBFS  ·  {T("autoNormalMeasured")}: {result.SpeechDb:0.0} dBFS\n"+
            $"{T(result.Detailed?"autoQuietMeasured":"autoLowObserved")}: {result.QuietDb:0.0} dBFS  ·  {T(result.Detailed?"autoLoudMeasured":"autoHighObserved")}: {result.LoudDb:0.0} dBFS  ·  {T("autoSnr")}: {result.SignalToNoiseDb:0.0} dB";
        PersonalWarnings.Text=string.Join("\n",(result.Warnings??[]).Select(T));
        PersonalWarnings.Visibility=PersonalWarnings.Text.Length>0?Visibility.Visible:Visibility.Collapsed;
        string On(bool value)=>T(value?"settingOn":"settingOff");
        var rows=new List<CalibrationSettingRow>{
            new(T("noise"),$"{On(settings.NoiseEnabled)} · {settings.NoiseMix*100:0}%",$"{(proposed.NoiseAutoEnabled?T("automatic"):On(proposed.NoiseEnabled))} · {proposed.NoiseMix*100:0}%"),
            new(T("balance"),On(settings.AgcEnabled),On(proposed.AgcEnabled)),
            new(T("sensitivityTitle"),settings.SensitivityEnabled?settings.SensitivityAutoEnabled?T("automatic"):$"{settings.SensitivityThresholdDb:0} dBFS":On(false),proposed.SensitivityAutoEnabled?T("automatic"):$"{proposed.SensitivityThresholdDb:0} dBFS"),
            new(T("target"),$"{settings.TargetDb:0} dBFS",$"{proposed.TargetDb:0} dBFS"),
            new(T("autoGainRange"),$"{settings.MinGainDb:0.#} / +{settings.MaxGainDb:0.#} dB",$"{proposed.MinGainDb:0.#} / +{proposed.MaxGainDb:0.#} dB"),
            new(T("highpass"),$"{settings.HighpassHz:0} Hz",$"{proposed.HighpassHz:0} Hz"),
            new(T("threshold"),$"{settings.CompressorThresholdDb:0.#} dBFS",$"{proposed.CompressorThresholdDb:0.#} dBFS"),
            new(T("ratio"),$"{settings.CompressorRatio:0.#}:1",$"{proposed.CompressorRatio:0.#}:1"),
            new(T("autoTimes"),$"{settings.AttackMs:0} / {settings.ReleaseMs:0} ms",$"{proposed.AttackMs:0} / {proposed.ReleaseMs:0} ms"),
            new(T("knee"),$"{settings.KneeDb:0} dB",$"{proposed.KneeDb:0} dB"),
            new(T("deesser"),$"{On(settings.DeesserEnabled)} · {settings.DeesserMaxDb:0} dB",$"{On(proposed.DeesserEnabled)} · {proposed.DeesserMaxDb:0} dB"),
            new(T("outputGain"),$"{settings.OutputDb:0.#} dB",$"{proposed.OutputDb:0.#} dB")
        };
        for(int i=0;i<4;i++)rows.Add(new($"EQ {i+1}",$"{settings.Bands[i].Frequency:0} Hz · {settings.Bands[i].GainDb:+0.#;-0.#;0} dB",$"{proposed.Bands[i].Frequency:0} Hz · {proposed.Bands[i].GainDb:+0.#;-0.#;0} dB"));
        PersonalChanges.ItemsSource=rows;
    }
    private async void ListenPersonalClick(object sender,RoutedEventArgs e)
    {
        if(quitting||busy||sampling||calibrationSuggestion is not {Settings:{ } proposed} result||rawSample.Length!=PersonalCalibration.Duration(result.Detailed)*AudioSamples.Rate)return;
        SetBusy(true);
        try{
            var sample=suggestionSample;
            if(sample is null){sample=await AwaitOffline(BuildSuggestionSample(rawSample,proposed,result.NoiseFloorDb));if(sample is null)return;suggestionSample=sample;}
            Play(ReferenceEquals(sender,ListenPersonalRawButton)?sample.Raw:sample.Processed);
        }catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException){if(!quitting)Status("error");}finally{SetBusy(false);}
    }
    private static Task<MatchedSample> BuildSuggestionSample(float[] sample,AudioSettings proposed,float floor)
    {
        var config=proposed.Clone();
        return Task.Run(()=>{using var offline=new NativeEngine(AppContext.BaseDirectory);return AudioSamples.Match(sample,offline.Process(sample,config,floor));});
    }
    private void ApplyPersonalClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling||calibrationSuggestion is null)return;
        if(InputBox.SelectedItem is not AudioDevice device||device.Id!=calibrationDeviceId){Status("autoDeviceChanged");return;}
        SetBusy(true);
        try{
            ReadControls();state.Settings=settings.Clone();state.InputId=device.Id;
            state.ActiveProfile=PresetList.SelectedItem is ProfileChoice profile?ProfileKey(profile.Profile):state.ActiveProfile;
            var change=PersonalCalibrationChange.Apply(state,device.Id,calibrationSuggestion,T("personalProfileName"));
            try{UpdateEngine(state.Settings,calibrationSuggestion.NoiseFloorDb);if(!smoke)store.Save(state);}
            catch{change.Undo(state);UpdateEngine(state.Settings,NoiseFloor);throw;}
            calibrationUndo=change;settings=state.Settings.Clone();RebuildProfiles(state.ActiveProfile);
            ProfileNameBox.Text=state.ActiveProfile[5..];LoadControls();matched=null;
            ClearCalibrationSuggestion();PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoApplied");CalibrationMessage.Text=T("calibrated");Status("autoApplied");
        }catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException or UnauthorizedAccessException){Status("autoApplyError");}finally{SetBusy(false);}
    }
    private void UndoPersonalClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling||calibrationUndo is null)return;
        try{
            calibrationUndo.Undo(state);calibrationUndo=null;settings=state.Settings.Clone();
            RebuildProfiles(state.ActiveProfile);LoadControls();RefreshProfileStatus();
            UpdateEngine(settings,NoiseFloor);matched=null;
            if(!smoke)store.Save(state);
            PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoRestored");Status("autoRestored");
        }catch(Exception ex)when(ex is InvalidDataException or InvalidOperationException){Status("autoDeviceChanged");}
        catch(Exception ex)when(ex is IOException or UnauthorizedAccessException){Status("autoSaveError");}
        SetBusy(false);
    }
    private void RestoreDeviceSettingsClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling||InputBox.SelectedItem is not AudioDevice device||
            !state.Calibrations.TryGetValue(device.Id,out var saved)||saved.TunedSettings is null)return;
        settings=saved.TunedSettings.Clone();calibrationUndo=null;LoadControls();RefreshProfileStatus();
        ApplySettings();PersonalInstruction.SetResourceReference(TextBlock.TextProperty,"autoDeviceRestored");Status("autoDeviceRestored");SetBusy(false);
    }
    private void PersonalTick(EngineMetrics metrics)
    {
        PersonalProgress.Value=metrics.SampleFrames/(double)AudioSamples.Rate;
        string stage=PersonalCalibration.StageKey(metrics.SampleFrames,personalDetailed);
        int end=PersonalCalibration.StageEndSeconds(metrics.SampleFrames,personalDetailed);
        PersonalInstruction.Text=T(stage)+$"  ·  {Math.Max(0,end-metrics.SampleFrames/48000d):0} {T("secondsRemaining")}";
        PersonalPhrase.Text=metrics.SampleFrames<(personalDetailed?5:2)*AudioSamples.Rate?T("autoAmbientPhrase"):T("autoReadPhrase");
    }
    private void OpenPersonalCalibrationClick(object sender,RoutedEventArgs e)=>Navigate(WorkspacePage.Calibration);
    private async Task RunPersonalSmoke(string directory)
    {
        // Synthetic controller/render regression: does not record a person or
        // play sound. Actual RNNoise speech validation is covered separately.
        Navigate(WorkspacePage.Calibration);PersonalCalibrateButton.BringIntoView();await Task.Delay(60);
        Capture(Path.Combine(directory,"personal-start-tr.png"));
        personalDetailed=false;
        rawSample=new float[PersonalCalibration.QuickSeconds*AudioSamples.Rate];var random=new Random(38);
        for(int i=0;i<rawSample.Length;i++){
            float level=i<2*AudioSamples.Rate?0:.06f*(.8f+.2f*(float)Math.Sin(i/(double)AudioSamples.Rate*4));
            rawSample[i]=level*(float)(Math.Sin(i*2*Math.PI*170/48000)+.35*Math.Sin(i*2*Math.PI*900/48000)+.15*Math.Sin(i*2*Math.PI*2800/48000))+.0005f*(float)(random.NextDouble()-.5);
        }
        foreach(uint frames in new uint[]{0,96000,480000}){
            PersonalTick(new EngineMetrics{SampleFrames=frames});
            if(!PersonalInstruction.Text.StartsWith(T(PersonalCalibration.StageKey(frames,personalDetailed)),StringComparison.Ordinal))throw new InvalidOperationException("Calibration prompt out of sync");
        }
        DetailedCalibrationBox.IsChecked=true;
        if(!PersonalCalibrateButton.Content.ToString()!.Contains("20",StringComparison.Ordinal))throw new InvalidOperationException("Detailed duration not visible");
        personalDetailed=true;
        foreach(uint frames in new uint[]{0,240000,576000,768000}){
            PersonalTick(new EngineMetrics{SampleFrames=frames});
            if(!PersonalInstruction.Text.StartsWith(T(PersonalCalibration.StageKey(frames,true)),StringComparison.Ordinal))throw new InvalidOperationException("Detailed calibration prompt out of sync");
        }
        DetailedCalibrationBox.IsChecked=false;personalDetailed=false;
        var input=InputBox.SelectedItem as AudioDevice??throw new IOException("No test device");
        calibrationDeviceId=input.Id;calibrationDeviceName=input.Name;state.InputId=input.Id;
        var snapshot=settings.Clone();int profiles=state.Profiles.Count;string output=state.OutputId;
        var recommendation=PersonalCalibration.Analyze(rawSample,settings);ShowPersonalResult(recommendation);
        if(!recommendation.Success||settings.NoiseMix!=snapshot.NoiseMix)throw new InvalidOperationException("Recommendation changed settings before apply");
        suggestionSample=await BuildSuggestionSample(rawSample,recommendation.Settings!,recommendation.NoiseFloorDb);
        if(suggestionSample.Processed.Length!=rawSample.Length-960||suggestionSample.Processed.Any(x=>!float.IsFinite(x)||Math.Abs(x)>.891252f))throw new InvalidOperationException("Invalid personal preview");
        ApplyPersonalButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        CheckInvalidMuteRecovery();
        if(calibrationUndo is null||settings.NoiseAutoEnabled!=recommendation.Settings!.NoiseAutoEnabled||state.Profiles.Count!=profiles+1||state.OutputId!=output||state.Calibrations[input.Id].TunedSettings is null)throw new InvalidOperationException("Personal apply failed");
        if(!RestoreDeviceButton.IsEnabled)throw new InvalidOperationException("Saved device settings unavailable");
        UndoPersonalButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        CheckInvalidMuteRecovery();
        if(calibrationUndo is not null||state.Profiles.Count!=profiles||settings.NoiseAutoEnabled!=snapshot.NoiseAutoEnabled||state.Calibrations.ContainsKey(input.Id))throw new InvalidOperationException("Personal undo failed");
        // A persisted device calibration can be restored without adding profiles.
        state.Calibrations[input.Id]=new(recommendation.NoiseFloorDb,recommendation.SpeechDb,DateTimeOffset.UtcNow,recommendation.Settings!.Clone());SetBusy(false);
        RestoreDeviceButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(settings.NoiseAutoEnabled!=recommendation.Settings.NoiseAutoEnabled||settings.MaxGainDb!=recommendation.Settings.MaxGainDb||state.OutputId!=output||state.Profiles.Count!=profiles)throw new InvalidOperationException("Device settings restore failed");
        state.Calibrations.Remove(input.Id);settings=snapshot.Clone();state.Settings=snapshot.Clone();LoadControls();ApplySettings();SetBusy(false);
        ShowPersonalResult(recommendation);PersonalResultPanel.BringIntoView();await Task.Delay(60);Capture(Path.Combine(directory,"personal-result-tr.png"));
        ShowPersonalResult(PersonalCalibration.Analyze(new float[480]));
        if(ApplyPersonalButton.IsEnabled||PersonalResultPanel.Visibility!=Visibility.Collapsed)throw new InvalidOperationException("Failed measurement could be applied");
        LanguageBox.SelectedIndex=1;ShowPersonalResult(recommendation);Width=640;Height=480;PersonalResultPanel.BringIntoView();await Task.Delay(60);Capture(Path.Combine(directory,"personal-result-small-en.png"));
        string expectedRoute=SelectedRoute.Mode=="cable"?(SelectedRoute.Available?"cableDisconnected":"cableMissing"):SelectedRoute.Mode=="local"?"localRouteHint":"driverMissing";
        if(RouteHint.Text!=T(expectedRoute))throw new InvalidOperationException("Transport language not updated");
        ApplyPersonalButton.BringIntoView();await Task.Delay(60);Capture(Path.Combine(directory,"personal-actions-small-en.png"));
        ClearCalibrationSuggestion();MainScroll.ScrollToTop();await Task.Delay(60);Capture(Path.Combine(directory,"personal-start-small-en.png"));
        ClearCalibrationSuggestion();Navigate(WorkspacePage.Overview);
    }
}
