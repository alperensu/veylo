using System;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Ses.Core;

namespace Ses.Desktop;
public partial class MainWindow
{
    private void StrongNoiseClick(object sender,RoutedEventArgs e)
    {
        if(!ready||busy||sampling||calibrating||personalCalibrating||finishing||quitting)return;
        if(!TryApplySettings())return;
        settings=NoiseControl.Strong(settings);LoadControls();
        BypassBox.IsChecked=false;ModifiedLabel.Text=T("custom");ApplySettings();Status("strongNoiseApplied");
    }
    private async Task RunStrongNoiseSmoke(string directory)
    {
        Width=1120;Height=820;LanguageBox.SelectedIndex=0;
        NavigationList.SelectedIndex=1;settings=Profiles.Factory()[0].Settings.Clone();LoadControls();
        MuteBox.IsChecked=true;BypassBox.IsChecked=true;
        StrongNoiseButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(settings.NoiseMix!=1||settings.NoiseAutoEnabled||!settings.SensitivityEnabled||settings.SensitivityMode!=1||BypassBox.IsChecked==true||MuteBox.IsChecked!=true)
            throw new InvalidOperationException("Strong cleaning must preserve mute and remove dry mix/bypass");
        MainScroll.ScrollToTop();await Task.Delay(80);Capture(Path.Combine(directory,"strong-noise-tr.png"));
        bool previous=sampling;sampling=true;settings.NoiseMix=.4f;LoadControls();
        StrongNoiseButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(settings.NoiseMix!=.4f)throw new InvalidOperationException("Strong cleaning changed active recording");
        sampling=previous;StrongNoiseClick(this,new RoutedEventArgs());
        MuteBox.IsChecked=false;ApplySettings();
        // Exercise recording controls and completion without starting native capture.
        sampling=true;SetBusy(false);if(StrongNoiseButton.IsEnabled)throw new InvalidOperationException("Recording controls must disable strong cleaning");
        await FinishSample();
        if(sampling||finishing||!StrongNoiseButton.IsEnabled)throw new InvalidOperationException("Finished recording did not restore strong cleaning");
        await EngineOperation(engine.Stop);
        File.WriteAllText(Path.Combine(directory,"strong-noise-result.json"),"{\"success\":true,\"fullWet\":true,\"softExpander\":true,\"mutePreserved\":true,\"recordingControlsValidated\":true,\"liveRecordingValidated\":false}");
    }
    private void RunValidationSmoke(string directory)
    {
        // Exercise real UI handlers and the currently configured native engine.
        engine.Stop();state.TalkMode=0;engine.SetTalkGate(0,false);
        MuteBox.IsChecked=false;BypassBox.IsChecked=true;ApplySettings();
        float[] signal=new float[48000];for(int i=0;i<signal.Length;i++)signal[i]=.1f*(float)Math.Sin(2*Math.PI*997*i/48000);
        if(!Array.Exists(engine.ProcessConfigured(signal),x=>Math.Abs(x)>.01f))throw new InvalidOperationException("Mute fixture must begin with audible native output");
        foreach(bool bypass in new[]{false,true}){
            BypassBox.IsChecked=bypass;MuteBox.IsChecked=false;ApplySettings();
            settings.Bands[1].Frequency=10;MuteBox.IsChecked=true;
            if(Array.Exists(engine.ProcessConfigured(signal),x=>x!=0)||settings.Bands[1].Frequency<20||statusKey!="invalidProfile")throw new InvalidOperationException("Invalid EQ prevented actual native mute or recovery");
            MuteBox.IsChecked=false;ApplySettings();
        }
        settings.Bands[1].Q=0;StrongNoiseButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if(statusKey!="invalidProfile"||settings.Bands[1].Q<=0)throw new InvalidOperationException("Strong cleaning did not safely reject invalid EQ");
        float changed=NoiseSlider.Value<.9f?.93f:.83f;NoiseSlider.Value=changed;
        if(!applyTimer.IsEnabled)throw new InvalidOperationException("Pending edit fixture did not start debounce");
        ApplySettings();var saved=settings.Clone();
        if(applyTimer.IsEnabled||saved.NoiseMix!=changed)throw new InvalidOperationException("Final pending edit was not flushed");
        NoiseSlider.Value=.71f;ProfileNameBox.Text="Validation profile";SaveProfileClick(this,new RoutedEventArgs());
        if(applyTimer.IsEnabled||state.Profiles.Find(p=>p.Name=="Validation profile")?.Settings.NoiseMix!=.71f)throw new InvalidOperationException("Profile save did not flush pending edits");
        ExportProcessedWave(directory,signal);if(statusKey!="error")throw new InvalidOperationException("Invalid WAV destination did not report an error");
        BypassBox.IsChecked=true;ApplySettings();if(!Array.Exists(engine.ProcessConfigured(signal),x=>Math.Abs(x)>.01f))throw new InvalidOperationException("WAV write error disrupted the engine");
        File.WriteAllText(Path.Combine(directory,"validation-result.json"),"{\"success\":true,\"invalidEqNativeMute\":true,\"bypassMute\":true,\"invalidStrongCleaning\":true,\"pendingEditFlush\":true,\"profileSaveFlush\":true,\"wavWriteFailure\":true}");
    }
    private void CheckInvalidMuteRecovery()
    {
        string before=System.Text.Json.JsonSerializer.Serialize(settings);
        settings.Bands[1].Frequency=10;MuteBox.IsChecked=true;ApplySettings();
        if(before!=System.Text.Json.JsonSerializer.Serialize(settings))throw new InvalidOperationException("Invalid EQ discarded the last applied personal calibration");
        float[] signal=new float[4800];for(int i=0;i<signal.Length;i++)signal[i]=.1f*(float)Math.Sin(2*Math.PI*997*i/48000);
        if(Array.Exists(engine.ProcessConfigured(signal),x=>x!=0))throw new InvalidOperationException("Calibration recovery did not mute the engine");
        MuteBox.IsChecked=false;ApplySettings();
    }
}
