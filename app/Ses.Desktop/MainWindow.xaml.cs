using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Media;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;
using Ses.Core;

namespace Ses.Desktop;
public sealed record ProfileChoice(VoiceProfile Profile,string Name,string Description);
public partial class MainWindow : Window
{
    private readonly NativeEngine engine;
    private readonly UserStore store;
    private readonly UserState state;
    private readonly bool smoke;
    private readonly string[] args;
    private readonly LiveValidationOptions? liveValidation;
    private bool OfflineSmoke => smoke&&liveValidation is null;
    private readonly DispatcherTimer meterTimer=new(){Interval=TimeSpan.FromMilliseconds(100)};
    private readonly DispatcherTimer applyTimer=new(){Interval=TimeSpan.FromMilliseconds(180)};
    private readonly DispatcherTimer sessionTimer=new(){Interval=TimeSpan.FromSeconds(2)};
    private readonly SemaphoreSlim lifecycle=new(1,1);
    private readonly DispatcherTimer saveTimer=new(){Interval=TimeSpan.FromSeconds(1)};
    private AudioSettings settings;
    private AudioSettings lastAppliedSettings;
    private DesktopServices? desktop;
    private bool ready,suppress,busy,quitting,calibrating,sampling,finishing;
    private string statusKey="ready";
    private float[] rawSample=[];
    private MatchedSample? matched;
    private SoundPlayer? player;
    private MemoryStream? playbackStream;
    private readonly Stopwatch recordingClock=new();
    public string[] EqTypes {get;private set;}=[];
    public static string T(string key)=>Application.Current.TryFindResource(key) as string??key;
    public MainWindow(bool smoke,string[] args)
    {
        this.smoke=smoke;this.args=args;
        liveValidation=args.Contains("--validate-live")||args.Contains("--validate-low-overhead")?LiveValidationOptions.Parse(args):null;
        store=new UserStore(smoke?Path.Combine(AppContext.BaseDirectory,"smoke-state"):null);state=smoke?new UserState():store.Load();settings=state.Settings.Clone();
        if(!smoke&&args.Contains("--strong-clean")){settings=NoiseControl.Strong(settings);state.Settings=settings.Clone();}
        lastAppliedSettings=settings.Clone();
        engine=new NativeEngine(AppContext.BaseDirectory);
        InitializeComponent();
        LanguageBox.SelectedIndex=state.Language=="en"?1:0;ChangeLanguage(state.Language);
        MuteKeyBox.ItemsSource=Enumerable.Range('A',26).Select(x=>((char)x).ToString()).ToArray();BypassKeyBox.ItemsSource=MuteKeyBox.ItemsSource;
        MuteKeyBox.SelectedItem=state.MuteKey;BypassKeyBox.SelectedItem=state.BypassKey;
        InitializeCommunication();
        StartupBox.IsChecked=!smoke&&DesktopServices.StartsWithWindows();
        RebuildProfiles();LoadControls();Navigate(WorkspacePage.Overview);ResizeNavigation();
        meterTimer.Tick+=MeterTick;
        sessionTimer.Tick+=SessionTick;
        applyTimer.Tick+=(_,_)=>{applyTimer.Stop();ApplySettings();};
        saveTimer.Tick+=(_,_)=>{saveTimer.Stop();SaveState();};
        IsVisibleChanged+=(_,_)=>{if(IsVisible)meterTimer.Start();else if(!sampling)meterTimer.Stop();};
        InitializeExperience();
    }
    private async void WindowLoaded(object sender,RoutedEventArgs e)
    {
        if(!smoke){Width=Math.Max(MinWidth,Math.Min(Width,SystemParameters.WorkArea.Width-24));Height=Math.Max(MinHeight,Math.Min(Height,SystemParameters.WorkArea.Height-24));}
        await RefreshDevices();if(quitting)return;
        // A validation process may share the user's cable, but must never add voice.
        if(liveValidation is not null)MuteBox.IsChecked=true;
        ready=true;
        if(!smoke){desktop=new DesktopServices(this,()=>MuteBox.IsChecked=!(MuteBox.IsChecked??false),()=>BypassBox.IsChecked=!(BypassBox.IsChecked??false),Quit,SelectFactoryShortcut,(mode,held)=>engine.SetTalkGate(mode,held));if(!desktop.Configure(SavedShortcuts))ShortcutConflict();}
        ApplySettings();SetBusy(false);meterTimer.Start();if(store.LoadWarning)Status("storeWarning");
        if(!smoke||args.Contains("--validate-live")){await StartSession();sessionTimer.Start();}
        if(args.Contains("--minimized")){Hide();Opacity=1;ShowInTaskbar=!smoke;}
        if(smoke)await RunSmoke();
    }
    private void ChangeLanguage(string language)
    {
        var culture=CultureInfo.GetCultureInfo(language=="tr"?"tr-TR":"en-US");CultureInfo.CurrentCulture=culture;CultureInfo.CurrentUICulture=culture;Language=System.Windows.Markup.XmlLanguage.GetLanguage(culture.Name);
        Application.Current.Resources.MergedDictionaries[1]=new ResourceDictionary{Source=new Uri("Resources/"+language+".xaml",UriKind.Relative)};
        EqTypes=[T("peak"),T("lowShelf"),T("highShelf")];state.Language=language;
        if(BandsControl is not null){BandsControl.ItemsSource=null;BandsControl.ItemsSource=settings.Bands;}
        if(OutputBox?.ItemsSource is not null){RebuildOutputs();RouteText();}
        if(CalibrationMessage is not null&&!calibrating)CalibrationMessage.Text=T("ambientPrompt");
        desktop?.Translate();
        RefreshPersonalResult();
        ApplyVisualPolicy();
        if(personalCalibrating)PersonalTick(engine.Metrics());
        else if(PersonalPhrase is not null)PersonalPhrase.SetResourceReference(TextBlock.TextProperty,"personalPosition");
        if(RecordButton is not null)RecordButton.Content=T(sampling?"recordStop":"record");
        RefreshProfileStatus();
        if(NavigationList is not null&&NavigationList.SelectedIndex>=0)ShowPage(NavigationList.SelectedIndex);
    }
    private void LanguageChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready||suppress)return;ChangeLanguage(LanguageBox.SelectedIndex==1?"en":"tr");RebuildProfiles();RouteText();Status(statusKey);UpdateLabels();ScheduleSave();
    }
    private static string ProfileKey(VoiceProfile profile)=>profile.FactoryId??"user:"+profile.Name;
    private void RebuildProfiles(string? chosen=null)
    {
        bool previous=suppress;suppress=true;
        string selected=chosen??((PresetList.SelectedItem as ProfileChoice) is { } old?ProfileKey(old.Profile):state.ActiveProfile);
        var choices=Profiles.Factory().Concat(state.Profiles).Select(p=>new ProfileChoice(p,p.FactoryId is null?p.Name:T("preset_"+p.FactoryId),p.FactoryId is null?p.Description:T("desc_"+p.FactoryId))).ToArray();
        PresetList.ItemsSource=choices;PresetList.SelectedItem=choices.FirstOrDefault(p=>ProfileKey(p.Profile)==selected)??choices[0];PresetList.MaxHeight=440;
        if(ProfileNameBox.Text.Length==0)ProfileNameBox.Text=state.Language=="en"?"My voice":"Benim sesim";suppress=previous;RefreshProfileStatus();
    }
    private void LoadControls()
    {
        bool previous=suppress;suppress=true;NoiseBox.IsChecked=settings.NoiseEnabled;AutoNoiseBox.IsChecked=settings.NoiseAutoEnabled;BalanceBox.IsChecked=settings.AgcEnabled;DeesserBox.IsChecked=settings.DeesserEnabled;
        SensitivityBox.IsChecked=settings.SensitivityEnabled;SensitivityAutoBox.IsChecked=settings.SensitivityAutoEnabled;SensitivitySlider.Value=settings.SensitivityThresholdDb;
        SensitivityModeBox.SelectedIndex=settings.SensitivityMode;SensitivityAttackSlider.Value=settings.SensitivityAttackMs;SensitivityHoldSlider.Value=settings.SensitivityHoldMs;SensitivityReleaseSlider.Value=settings.SensitivityReleaseMs;SensitivityHysteresisSlider.Value=settings.SensitivityHysteresisDb;SensitivityRatioSlider.Value=settings.SensitivityRatio;SensitivityReductionSlider.Value=settings.SensitivityMaxReductionDb;
        NoiseSlider.Value=settings.NoiseMix;WarmthSlider.Value=settings.Bands[0].GainDb;ClaritySlider.Value=settings.Bands[2].GainDb;
        HighpassSlider.Value=settings.HighpassHz;TargetSlider.Value=settings.TargetDb;MinGainSlider.Value=settings.MinGainDb;MaxGainSlider.Value=settings.MaxGainDb;ThresholdSlider.Value=settings.CompressorThresholdDb;RatioSlider.Value=settings.CompressorRatio;AttackSlider.Value=settings.AttackMs;ReleaseSlider.Value=settings.ReleaseMs;KneeSlider.Value=settings.KneeDb;DeessMaxSlider.Value=settings.DeesserMaxDb;OutputGainSlider.Value=settings.OutputDb;
        BandsControl.ItemsSource=null;BandsControl.ItemsSource=settings.Bands;UpdateLabels();suppress=previous;RefreshProfileStatus();
    }
    private void ReadControls()
    {
        settings.NoiseEnabled=NoiseBox.IsChecked==true;settings.NoiseAutoEnabled=AutoNoiseBox.IsChecked==true;settings.AgcEnabled=BalanceBox.IsChecked==true;settings.DeesserEnabled=DeesserBox.IsChecked==true;
        settings.SensitivityEnabled=SensitivityBox.IsChecked==true;settings.SensitivityAutoEnabled=SensitivityAutoBox.IsChecked==true;settings.SensitivityThresholdDb=(float)SensitivitySlider.Value;
        settings.SensitivityMode=SensitivityModeBox.SelectedIndex;settings.SensitivityAttackMs=(float)SensitivityAttackSlider.Value;settings.SensitivityHoldMs=(float)SensitivityHoldSlider.Value;settings.SensitivityReleaseMs=(float)SensitivityReleaseSlider.Value;settings.SensitivityHysteresisDb=(float)SensitivityHysteresisSlider.Value;settings.SensitivityRatio=(float)SensitivityRatioSlider.Value;settings.SensitivityMaxReductionDb=(float)SensitivityReductionSlider.Value;
        settings.NoiseMix=(float)NoiseSlider.Value;settings.Bands[0].GainDb=(float)WarmthSlider.Value;settings.Bands[2].GainDb=(float)ClaritySlider.Value;
        settings.HighpassHz=(float)HighpassSlider.Value;settings.TargetDb=(float)TargetSlider.Value;settings.MinGainDb=(float)MinGainSlider.Value;settings.MaxGainDb=(float)MaxGainSlider.Value;settings.CompressorThresholdDb=(float)ThresholdSlider.Value;settings.CompressorRatio=(float)RatioSlider.Value;settings.AttackMs=(float)AttackSlider.Value;settings.ReleaseMs=(float)ReleaseSlider.Value;settings.KneeDb=(float)KneeSlider.Value;settings.DeesserMaxDb=(float)DeessMaxSlider.Value;settings.OutputDb=(float)OutputGainSlider.Value;
    }
    private void UpdateLabels()
    {
        NoiseSlider.IsEnabled=NoiseBox.IsChecked==true&&AutoNoiseBox.IsChecked!=true;
        AutoNoiseBox.IsEnabled=NoiseBox.IsChecked==true;
        SensitivityAutoBox.IsEnabled=SensitivityBox.IsChecked==true;
        SensitivitySlider.IsEnabled=SensitivityBox.IsChecked==true&&SensitivityAutoBox.IsChecked!=true;
        SensitivityModeBox.IsEnabled=SensitivityAdvanced.IsEnabled=SensitivityBox.IsChecked==true;
        SensitivityRatioSlider.IsEnabled=SensitivityReductionSlider.IsEnabled=SensitivityModeBox.SelectedIndex==1;
        SensitivityTimingValue.Text=$"{T("sensitivityTiming")}: {SensitivityAttackSlider.Value:0.#} / {SensitivityHoldSlider.Value:0} / {SensitivityReleaseSlider.Value:0} ms · {SensitivityHysteresisSlider.Value:0.#} dB";
        SensitivityExpansionValue.Text=$"{SensitivityRatioSlider.Value:0.#}:1 · {SensitivityReductionSlider.Value:0} dB";
        UpdateCommunicationLabel();
        SensitivityValue.Text=$"{SensitivitySlider.Value:0} dBFS";
        NoiseStrengthLabel.Text=T(AutoNoiseBox.IsChecked==true?"savedManualStrength":"strength");
        if(PresetList.SelectedItem is ProfileChoice profile)ActiveProfileText.Text=T("activeProfile")+" · "+profile.Name;
        NoiseValue.Text=$"{NoiseSlider.Value*100:0}%";WarmthValue.Text=$"{WarmthSlider.Value:+0.#;-0.#;0} dB";ClarityValue.Text=$"{ClaritySlider.Value:+0.#;-0.#;0} dB";
        HighpassValue.Text=$"{HighpassSlider.Value:0.#} Hz";TargetValue.Text=$"{TargetSlider.Value:0.#} dBFS";MinGainValue.Text=$"{MinGainSlider.Value:0.#} dB";MaxGainValue.Text=$"{MaxGainSlider.Value:0.#} dB";ThresholdValue.Text=$"{ThresholdSlider.Value:0.#} dBFS";RatioValue.Text=$"{RatioSlider.Value:0.#} :1";AttackValue.Text=$"{AttackSlider.Value:0.#} ms";ReleaseValue.Text=$"{ReleaseSlider.Value:0.#} ms";KneeValue.Text=$"{KneeSlider.Value:0.#} dB";DeessMaxValue.Text=$"{DeessMaxSlider.Value:0.#} dB";OutputGainValue.Text=$"{OutputGainSlider.Value:0.#} dB";
        RefreshProfileStatus();
    }
    private float NoiseFloor => InputBox.SelectedItem is AudioDevice d && state.Calibrations.TryGetValue(d.Id,out var c)?c.NoiseFloorDb:-60;
    private void ApplySettings()
    {
        TryApplySettings();
    }
    private void UpdateEngine(AudioSettings applied,float noiseFloor)
    {
        engine.Update(applied,noiseFloor,MuteBox.IsChecked==true,BypassBox.IsChecked==true);
        lastAppliedSettings=applied.Clone();
    }
    private bool TryApplySettings()
    {
        if(!ready||quitting)return false;
        applyTimer.Stop();
        try{ReadControls();settings.Validate();UpdateEngine(settings,NoiseFloor);UpdateLabels();RefreshPersonalResult();if(rawSample.Length>0)matched=null;ScheduleSave();return true;}
        catch(InvalidDataException){
            // Invalid tone edits must never prevent mute/bypass reaching the engine.
            settings=lastAppliedSettings.Clone();UpdateEngine(settings,NoiseFloor);
            LoadControls();Status("invalidProfile");return false;
        }
    }
    private void SettingsChanged(object sender,RoutedPropertyChangedEventArgs<double> e){if(!ready||suppress)return;ReadControls();UpdateLabels();RefreshPersonalResult();applyTimer.Stop();applyTimer.Start();}
    private void SettingsToggled(object sender,RoutedEventArgs e){if(!ready||suppress)return;ApplySettings();}
    private void BandGainChanged(object sender,RoutedPropertyChangedEventArgs<double> e)
    {
        if(!ready||suppress||sender is not Slider slider||slider.DataContext is not EqBand band)return;
        band.GainDb=(float)e.NewValue;suppress=true;if(ReferenceEquals(band,settings.Bands[0]))WarmthSlider.Value=e.NewValue;if(ReferenceEquals(band,settings.Bands[2]))ClaritySlider.Value=e.NewValue;suppress=false;SettingsChanged(sender,e);
    }
    private void BandFrequencyChanged(object sender,RoutedEventArgs e){if(!ready||suppress)return;ApplySettings();}
    private void BandTypeChanged(object sender,SelectionChangedEventArgs e){if(!ready||suppress)return;Dispatcher.BeginInvoke(ApplySettings);}
    private void PresetChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!CanChangeProfile||PresetList.SelectedItem is not ProfileChoice choice)return;
        ApplySelectedProfile(choice);
    }
    private async Task RefreshDevices()
    {
        try {
            // Offline UI fixtures never enumerate, open or persist a user's microphone.
            var all=OfflineSmoke?new AudioDevice[]{new("veylo-smoke-input","Synthetic microphone (UI test)",true,true)}:await Task.Run(engine.Devices);suppress=true;
            string selected=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;
            captureDevices=all.Where(d=>d.Input).ToArray();
            var physical=all.Where(d=>d.Input&&!d.IsSesVirtual).ToArray();
            InputBox.ItemsSource=physical;InputBox.SelectedItem=InputSelection.Choose(physical,selected);
            if(InputBox.SelectedItem is AudioDevice input)state.InputId=input.Id;
            outputDevices=all.Where(d=>!d.Input).ToArray();
            RebuildOutputs();
            suppress=false;RouteText();
        }catch(IOException){suppress=false;Status("permissionError");}
    }
    private void RouteText()
    {
        if(quitting)return;
        var m=engine.Metrics();
        if(SelectedRoute.Mode=="cable"){RouteHint.Text=T(!SelectedRoute.Available?"cableMissing":m.Connected!=0&&m.OutputKind==2?"cableRouteHint":"cableDisconnected");return;}
        if(SelectedRoute.Mode=="local"){RouteHint.Text=T("localRouteHint");return;}
        RouteHint.Text=T(m.DriverStatus==2?"routeHint":m.DriverStatus==3?"driverMismatch":m.DriverStatus==4?"driverAccess":m.DriverStatus==5?"driverBusy":m.DriverStatus==6?"driverFault":"driverMissing");
    }
    private async void RefreshClick(object sender,RoutedEventArgs e){if(busy||sampling)return;SetBusy(true);try{await RefreshDevices();}finally{SetBusy(false);}await RestartRoute();}
    private async void DeviceChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready||suppress||busy||quitting)return;
        if(InputBox.SelectedItem is not AudioDevice selectedInput)return;
        if(selectedInput.Id!=calibrationDeviceId){ClearCalibrationSuggestion();calibrationUndo=null;}
        state.InputId=selectedInput.Id;var route=SelectedRoute;SetBusy(true);
        try{ApplySettings();await EngineOperation(()=>{engine.Stop();StartSelectedRoute(selectedInput.Id,route);});if(!quitting){SessionStatus();ScheduleSave();}}
        catch(AudioDeviceException ex){Status(ex.Code==-4?"permissionError":ex.Code==-6?"feedbackInput":ex.Code==-7?"disconnected":"deviceOpenError");}
        finally{SetBusy(false);RouteText();}
    }
    private async Task StartSession()
    {
        if(quitting||busy||sampling)return;
        if(engine.Metrics().Running!=0){SessionStatus();return;}
        string id=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;
        if(id.Length==0){Status("noInput");return;}
        var route=SelectedRoute;SetBusy(true);
        try{ApplySettings();await EngineOperation(()=>StartSelectedRoute(id,route));if(!quitting){SessionStatus();ScheduleSave();}}
        catch(AudioDeviceException ex){Status(ex.Code==-4?"permissionError":ex.Code==-6?"feedbackInput":ex.Code==-7?"disconnected":"deviceOpenError");}
        finally{SetBusy(false);RouteText();}
    }
    private void SessionStatus()
    {
        if(quitting)return;
        var m=engine.Metrics();Status(m.Connected==0?(m.ErrorCode==4?"permissionError":m.ErrorCode==5?"deviceOpenError":"disconnected"):m.OutputKind==2||m.OutputKind==1&&m.DriverStatus==2?"running":"localRunning");RouteText();
    }
    private async Task EngineOperation(Action operation)
    {
        await lifecycle.WaitAsync();
        try{if(!quitting)await Task.Run(operation);}finally{lifecycle.Release();}
    }
    private async Task<T?> AwaitOffline<T>(Task<T> work) where T:class
    {
        var result=await work;
        return quitting?null:result;
    }
    private async void SessionTick(object? sender,EventArgs e)
    {
        if(quitting||busy||sampling)return;
        if(InputBox.SelectedItem is null)await RefreshDevices();
        if(quitting)return;
        await ReconnectMissingCable();
        if(quitting)return;
        if(engine.Metrics().Running==0)await StartSession();
        else if(statusKey is "running" or "localRunning" or "disconnected" or "permissionError" or "deviceOpenError" or "noInput")SessionStatus();
    }
    private void SetBusy(bool value)
    {
        busy=value;if(quitting)return;StrongNoiseButton.IsEnabled=!value&&!sampling&&!calibrating&&!personalCalibrating&&!finishing;InputBox.IsEnabled=!value&&!sampling;OutputBox.IsEnabled=!value&&!sampling;
        PresetList.IsEnabled=!value&&!sampling&&!personalCalibrating;
        RecordButton.IsEnabled=!value&&!calibrating;CalibrateButton.IsEnabled=!value&&!sampling;
        PersonalCalibrateButton.IsEnabled=!value&&!sampling;CancelPersonalButton.IsEnabled=!value&&personalCalibrating&&sampling;
        DetailedCalibrationBox.IsEnabled=!value&&!sampling;
        RestoreDeviceButton.IsEnabled=!value&&!sampling&&InputBox.SelectedItem is AudioDevice device&&state.Calibrations.TryGetValue(device.Id,out var saved)&&saved.TunedSettings is not null;
        UndoPersonalButton.IsEnabled=!value&&!sampling&&calibrationUndo is not null;
        ApplyPersonalButton.IsEnabled=ListenPersonalButton.IsEnabled=ListenPersonalRawButton.IsEnabled=!value&&!sampling&&calibrationSuggestion is {Success:true};
        foreach(var page in new[]{NoisePage,BalancePage,QualityPage,ProfilesPage})page.IsEnabled=!value&&!personalCalibrating;
        RefreshProfileStatus();
    }
    private async Task<bool> EnsureCapture()
    {
        if(quitting)return false;
        if(engine.Metrics().Running==0){
            if(InputBox.SelectedItem is not AudioDevice input){Status("noInput");return false;}
            var route=SelectedRoute;
            try{ApplySettings();await EngineOperation(()=>StartSelectedRoute(input.Id,route));}
            catch(AudioDeviceException ex){Status(ex.Code==-4?"permissionError":ex.Code==-6?"feedbackInput":ex.Code==-7?"disconnected":"deviceOpenError");return false;}
        }
        if(quitting)return false;
        if(engine.Metrics().Connected!=0)return true;
        Status(InputBox.SelectedItem is null?"noInput":"deviceOpenError");return false;
    }
    private async void RecordClick(object sender,RoutedEventArgs e)
    {
        if(busy||quitting)return;if(sampling){await FinishSample();return;}await BeginSample(false);
    }
    private async void CalibrateClick(object sender,RoutedEventArgs e){if(busy||sampling||quitting)return;await BeginSample(true);}
    private async Task BeginSample(bool calibration)
    {
        if(quitting)return;
        SetBusy(true);
        try {
            if(!await EnsureCapture())return;
            player?.Stop();rawSample=[];matched=null;ClearCalibrationSuggestion();ListenRawButton.IsEnabled=ListenProcessedButton.IsEnabled=ExportWaveButton.IsEnabled=false;
            int duration=personalCalibrating?PersonalCalibration.Duration(personalDetailed):calibration?15:20;
            engine.BeginSample(duration);sampling=true;calibrating=calibration;finishing=false;recordingClock.Restart();meterTimer.Start();
            RecordButton.Content=T("recordStop");SampleProgress.Maximum=duration;SampleProgress.Value=0;Status(calibration?"ambientNow":"record");
        }catch(Exception ex)when(ex is IOException or InvalidOperationException){Status("error");}finally{SetBusy(false);}
    }
    private async Task FinishSample()
    {
        if(quitting||finishing||!sampling)return;finishing=true;sampling=false;bool wasCalibration=calibrating,wasPersonal=personalCalibrating;calibrating=false;personalCalibrating=false;SetBusy(true);
        try {
            engine.EndSample();rawSample=engine.CopySample(false);
            if(wasPersonal){await AnalyzePersonalSample();if(quitting)return;}
            else if(wasCalibration){
                var result=Calibration.Analyze(rawSample);
                if(result.Success&&InputBox.SelectedItem is AudioDevice d){
                    var tuned=state.Calibrations.TryGetValue(d.Id,out var saved)?saved.TunedSettings?.Clone():null;
                    state.Calibrations[d.Id]=new(result.NoiseFloorDb,result.SpeechDb,DateTimeOffset.UtcNow,tuned);
                    CalibrationMessage.Text=T("calibrated");ApplySettings();Status("calibrated");
                }
                else {CalibrationMessage.Text=T(result.Error);Status(result.Error);}
            }else Status(rawSample.Length>=480?"sampleReady":"calibrationIncomplete");
            ListenRawButton.IsEnabled=ListenProcessedButton.IsEnabled=ExportWaveButton.IsEnabled=rawSample.Length>=480;RecordButton.Content=T("record");SaveState();
        }catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException){if(!quitting)Status("error");}finally{finishing=false;SetBusy(false);if(!IsVisible)meterTimer.Stop();}
    }
    private async Task<MatchedSample?> RenderSample()
    {
        if(quitting)return null;
        if(rawSample.Length<480){Status("noSample");return null;}
        if(matched is not null)return matched;
        SetBusy(true);
        try{ReadControls();var snapshot=settings.Clone();float floor=NoiseFloor;var sample=rawSample;var result=await AwaitOffline(Task.Run(()=>{using var offline=new NativeEngine(AppContext.BaseDirectory);offline.Update(snapshot,floor);var processed=offline.Process(sample,snapshot,floor);return AudioSamples.Match(sample,processed);}));if(result is null)return null;matched=result;return matched;}
        catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException){if(!quitting)Status("error");return null;}
        finally{SetBusy(false);}
    }
    private void Play(float[] sample)
    {
        if(quitting)return;
        player?.Stop();player?.Dispose();playbackStream?.Dispose();playbackStream=new(AudioSamples.Wave(sample));player=new SoundPlayer(playbackStream);player.Play();Status("headphones");
    }
    private async void ListenRawClick(object sender,RoutedEventArgs e){if(busy||quitting)return;var pair=await RenderSample();if(pair is not null)Play(pair.Raw);}
    private async void ListenProcessedClick(object sender,RoutedEventArgs e){if(busy||quitting)return;var pair=await RenderSample();if(pair is not null)Play(pair.Processed);}
    private async void PreviewProfileClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling||quitting)return;
        if(rawSample.Length<480){Navigate(WorkspacePage.Calibration);RecordButton.BringIntoView();Status("noSample");return;}
        var pair=await RenderSample();if(pair is not null&&!quitting)Play(ReferenceEquals(sender,ProfileRawButton)?pair.Raw:pair.Processed);
    }
    private async void ExportWaveClick(object sender,RoutedEventArgs e)
    {
        if(busy||quitting)return;var pair=await RenderSample();if(quitting||pair is null)return;
        var dialog=new SaveFileDialog {Filter="WAV (*.wav)|*.wav",FileName="ses-processed.wav"};if(dialog.ShowDialog(this)!=true)return;
        ExportProcessedWave(dialog.FileName,pair.Processed);
    }
    private void ExportProcessedWave(string path,float[] processed)
    {
        try{File.WriteAllBytes(path,AudioSamples.Wave(processed));Status("exported");}catch(Exception ex)when(ex is IOException or UnauthorizedAccessException){Status("error");}
    }
    private VoiceProfile CurrentProfile()=>new(){Name=ProfileNameBox.Text.Trim(),Settings=settings.Clone()};
    private void SaveProfileClick(object sender,RoutedEventArgs e)
    {
        try{
            if(!TryApplySettings())return;var p=CurrentProfile();Profiles.Serialize(p);var index=state.Profiles.FindIndex(v=>string.Equals(v.Name,p.Name,StringComparison.OrdinalIgnoreCase));
            if(index>=0)state.Profiles[index]=p;else {if(state.Profiles.Count>=100)throw new InvalidDataException();state.Profiles.Add(p);}
            RebuildProfiles(ProfileKey(p));if(SaveState())Status("saved");
        }catch(InvalidDataException){Status("invalidProfile");}
    }
    private void ImportClick(object sender,RoutedEventArgs e)
    {
        var dialog=new OpenFileDialog{Filter="Veylo preset (*.json)|*.json",Multiselect=false};if(dialog.ShowDialog(this)!=true)return;
        try{ImportProfile(Profiles.Load(dialog.FileName));}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("invalidProfile");}
    }
    private void ImportProfile(VoiceProfile p)
    {
        p.FactoryId=null;int index=state.Profiles.FindIndex(v=>string.Equals(v.Name,p.Name,StringComparison.OrdinalIgnoreCase));if(index>=0)state.Profiles[index]=p;else{if(state.Profiles.Count>=100)throw new InvalidDataException();state.Profiles.Add(p);}settings=p.Settings.Clone();RebuildProfiles(ProfileKey(p));ProfileNameBox.Text=p.Name;LoadControls();ApplySettings();if(SaveState())Status("imported");
    }
    private void ExportClick(object sender,RoutedEventArgs e)
    {
        var dialog=new SaveFileDialog{Filter="Veylo preset (*.json)|*.json",FileName="veylo-preset.json"};if(dialog.ShowDialog(this)!=true)return;
        try{if(!TryApplySettings())return;File.WriteAllText(dialog.FileName,Profiles.Serialize(CurrentProfile()));Status("exported");}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("invalidProfile");}
    }
    private void ScheduleSave(){if(!ready||smoke)return;saveTimer.Stop();saveTimer.Start();}
    private bool SaveState()
    {
        if(!ready)return false;if(smoke)return true;
        if(applyTimer.IsEnabled)ApplySettings();
        try{state.Settings=settings.Clone();state.ActiveProfile=PresetList.SelectedItem is ProfileChoice p?ProfileKey(p.Profile):state.ActiveProfile;state.InputId=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;state.OutputMode=SelectedRoute.Mode;if(SelectedRoute.Mode=="cable")state.OutputId=SelectedRoute.Id;store.Save(state);return true;}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("error");return false;}
    }
    private void StartupChanged(object sender,RoutedEventArgs e)
    {
        if(!ready||suppress||smoke)return;try{DesktopServices.Startup(StartupBox.IsChecked==true);}
        catch(Exception ex)when(ex is UnauthorizedAccessException or IOException or System.Security.SecurityException){suppress=true;StartupBox.IsChecked=DesktopServices.StartsWithWindows();suppress=false;Status("error");}
    }
    private void ApplyKeysClick(object sender,RoutedEventArgs e)
    {
        ApplyCommunicationKeys();
    }
    private void DriverClick(object sender,RoutedEventArgs e){var dialog=new DriverWindow(state.Language){Owner=this};System.Windows.Data.BindingOperations.SetBinding(dialog,Motion.EnabledProperty,new System.Windows.Data.Binding{Source=this,Path=new PropertyPath("(0)",Motion.EnabledProperty)});dialog.ShowDialog();}
    private void Status(string key){statusKey=key;StatusText.Text=T(key);}
    private async void MeterTick(object? sender,EventArgs e)
    {
        if(quitting)return;
        UpdateCommunicationLabel();var m=engine.Metrics();InputMeter.Value=Math.Max(-60,m.InputDb);OutputMeter.Value=Math.Max(-60,m.OutputDb);
        Scope.Push(m.OutputDb);ScopeStatus.Text=T(!Motion.GetEnabled(this)?"scopePaused":m.Connected==1?"scopeLive":"scopeWaiting");
        SensitivityMeter.Value=Math.Clamp(m.InputDb,-90,-10);
        SensitivityReadout.Text=m.Running==0?T("sensitivityWaiting"):
            EffectiveMuted?T("mute"):
            BypassBox.IsChecked==true?T("noiseBypassed"):
            !settings.SensitivityEnabled?T("sensitivityDisabled"):
            $"{T("sensitivityApplied")}: {m.SensitivityThresholdDb:0.0} dBFS · {T(m.SensitivityGain>.05f?"sensitivityPassing":"sensitivityQuiet")} · {T("sensitivityInput")}: {m.InputDb:0.0} dBFS";
        AutoNoiseReadout.Text=m.Running==0?T("noiseWaiting"):
            BypassBox.IsChecked==true?T("noiseBypassed"):
            NoiseBox.IsChecked!=true?T("noiseDisabled"):
            $"{m.NoiseMix*100:0}%  ·  {T(settings.NoiseAutoEnabled?"automatic":"manual")}";
        InputLevel.Text=$"{m.InputDb:0.0} dBFS";OutputLevel.Text=$"{m.OutputDb:0.0} dBFS";GainLevel.Text=$"{m.GainDb:+0.0;-0.0;0.0} dB";CompressionLevel.Text=$"{m.CompressionDb:0.0} dB";
        DiagnosticsText.Text=$"{T("dspTime")}: {m.ProcessingMs:0.00} ms  ·  {T("latency")}: {(m.Running!=0?m.EstimatedBufferMs.ToString("0.0")+" ms":"—")}  ·  {T("measuredLatency")}";
        DiagnosticsText.Text+=$"\n{T("bufferErrors")}: {m.Underruns} / {m.Overruns}  ·  {T("clockDrift")}: {m.DriftPpm:0} ppm  ·  {T("inputClips")}: {m.ClippedSamples}";
        if(m.Running!=0&&m.Connected==0&&!sampling)SessionStatus();
        else if(statusKey is "disconnected" or "running" or "localRunning")SessionStatus();
        if(sampling&&!finishing){
            if(personalCalibrating&&(m.Connected==0||m.Underruns!=calibrationUnderruns||m.Overruns!=calibrationOverruns)){
                await CancelPersonalCalibration(true);return;
            }
            SampleProgress.Value=m.SampleFrames/48000d;
            if(personalCalibrating)PersonalTick(m);else if(calibrating)CalibrationMessage.Text=T(m.SampleFrames<240000?"ambientNow":"speechNow");
            uint expected=personalCalibrating?(uint)(PersonalCalibration.Duration(personalDetailed)*AudioSamples.Rate):calibrating?720000u:960000u;
            if(m.SampleFrames>=expected||recordingClock.Elapsed.TotalSeconds>expected/(double)AudioSamples.Rate+5)await FinishSample();
        }
    }
    private void WindowStateChanged(object sender,EventArgs e){if(WindowState==WindowState.Minimized&&!smoke){Hide();desktop?.Notice();}}
    private void NavigationChanged(object sender,SelectionChangedEventArgs e)
    {
        if(OverviewPage is not null&&NavigationList.SelectedIndex>=0)ShowPage(NavigationList.SelectedIndex);
    }
    private void ShowPage(int index)
    {
        FrameworkElement[] pages=[OverviewPage,ProcessingPage,ProfilesPage,TestPage,PreferencesPage];
        string[] keys=["overviewNav","processingNav","profilesNav","testNav","preferencesNav"];
        if(index<0||index>=pages.Length)return;
        for(int i=0;i<pages.Length;i++)pages[i].Visibility=i==index?Visibility.Visible:Visibility.Collapsed;
        PageTitle.Text=T(keys[index]);PageDescription.Text=T(keys[index]+"Description");MainScroll.ScrollToTop();
        Motion.Reveal(pages[index]);
    }
    private void ResizeNavigation()
    {
        if(NavigationColumn is null)return;
        bool compact=ActualWidth>0&&ActualWidth<940;
        NavigationColumn.Width=new GridLength(compact?88:216);
        NavigationShell.Padding=compact?new Thickness(8,24,8,16):new Thickness(16,24,16,18);
        foreach(var label in new[]{NavLabel0,NavLabel1,NavLabel2,NavLabel3,NavLabel4})label.Visibility=compact?Visibility.Collapsed:Visibility.Visible;
        foreach(var element in new FrameworkElement[]{NavCaption,SidebarBrand,SidebarFooter,GameBadgeText})element.Visibility=compact?Visibility.Collapsed:Visibility.Visible;
        ContentShell.Margin=new Thickness(compact?20:28,compact?18:24,compact?20:28,16);
        PageTitle.FontSize=compact?26:30;
        double available=ActualWidth-(compact?88:216)-(compact?40:56)-10;
        bool narrow=available<740;
        OverviewGap.Width=new GridLength(narrow?0:18);
        OverviewRight.Width=narrow?new GridLength(0):new GridLength(1,GridUnitType.Star);
        Grid.SetColumn(LevelPanel,0);Grid.SetRow(LevelPanel,2);
        Grid.SetColumn(VoiceHeroPanel,narrow?0:2);Grid.SetRow(VoiceHeroPanel,narrow?3:2);
        Grid.SetColumnSpan(VoiceHeroPanel,narrow?3:1);Grid.SetColumnSpan(LevelPanel,narrow?3:1);
        bool stackDevices=available<580;
        DeviceGap.Width=new GridLength(stackDevices?0:18);
        DeviceFields.ColumnDefinitions[2].Width=stackDevices?new GridLength(0):new GridLength(1,GridUnitType.Star);
        Grid.SetColumnSpan(InputBox.Parent as FrameworkElement??InputBox,stackDevices?3:1);
        Grid.SetColumn(OutputField,stackDevices?0:2);Grid.SetRow(OutputField,stackDevices?1:0);Grid.SetColumnSpan(OutputField,stackDevices?3:1);
        OutputField.Margin=new Thickness(0,stackDevices?14:0,0,0);
        bool stackSession=available<650;
        Grid.SetRow(SessionControls,stackSession?1:0);Grid.SetColumn(SessionControls,stackSession?0:1);Grid.SetColumnSpan(SessionControls,stackSession?2:1);
        Grid.SetColumnSpan(SessionStatusPanel,stackSession?2:1);SessionControls.Margin=new Thickness(0,stackSession?10:0,0,0);
        ResizeProfileNotice();
    }
    private void WindowSizeChanged(object sender,SizeChangedEventArgs e)=>ResizeNavigation();
    private void WindowClosing(object? sender,CancelEventArgs e){if(!quitting){e.Cancel=true;Hide();desktop?.Notice();}}
    private async void Quit(){
        if(quitting)return;ApplySettings();StopExperience();quitting=true;sessionTimer.Stop();meterTimer.Stop();applyTimer.Stop();saveTimer.Stop();SaveState();ready=false;IsEnabled=false;player?.Stop();player?.Dispose();playbackStream?.Dispose();desktop?.Dispose();
        await lifecycle.WaitAsync();try{await Task.Run(engine.Dispose);}finally{lifecycle.Release();}
        Close();Application.Current.Shutdown();
    }
    private void Capture(string path)=>CaptureWindow(this,path);
    private static void CaptureWindow(Window window,string path,int dpi=96)
    {
        window.UpdateLayout();var content=(FrameworkElement)window.Content;int width=(int)(content.ActualWidth+content.Margin.Left+content.Margin.Right),height=(int)(content.ActualHeight+content.Margin.Top+content.Margin.Bottom);
        var visual=new DrawingVisual();using(var drawing=visual.RenderOpen()){drawing.DrawRectangle(window.Background,null,new Rect(0,0,width,height));drawing.DrawRectangle(new VisualBrush(content){ViewboxUnits=BrushMappingMode.Absolute,Viewbox=new Rect(0,0,content.ActualWidth,content.ActualHeight)},null,new Rect(content.Margin.Left,content.Margin.Top,content.ActualWidth,content.ActualHeight));}
        var image=new RenderTargetBitmap((int)Math.Ceiling(width*dpi/96d),(int)Math.Ceiling(height*dpi/96d),dpi,dpi,PixelFormats.Pbgra32);image.Render(visual);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(image));using var stream=File.Create(path);encoder.Save(stream);
    }
    private async Task RunSmoke()
    {
        try{
            string directory=args.SkipWhile(x=>x!="--out").Skip(1).FirstOrDefault()??Path.Combine(AppContext.BaseDirectory,"smoke");Directory.CreateDirectory(directory);
            if(args.Contains("--validate-live")){await ValidateLive(directory);Quit();return;}
            await Task.Delay(300);Capture(Path.Combine(directory,"desktop-tr.png"));
            // Page changes retain settings and cannot start or stop the audio engine.
            AutoNoiseBox.IsChecked=true;ApplySettings();float manualStrength=settings.NoiseMix;
            for(int page=0;page<NavigationList.Items.Count;page++){
                NavigationList.SelectedIndex=page;await Task.Delay(40);
                if(!settings.NoiseAutoEnabled||settings.NoiseMix!=manualStrength||engine.Metrics().Running!=0)throw new InvalidOperationException("Navigation changed audio state");
                Capture(Path.Combine(directory,$"page-{page}-tr.png"));
            }
            Navigate(WorkspacePage.Processing,ProcessingSection.Background);
            if(NoiseSlider.IsEnabled)throw new InvalidOperationException("Manual slider enabled during auto mode");
            AutoNoiseBox.IsChecked=false;ApplySettings();if(!NoiseSlider.IsEnabled)throw new InvalidOperationException("Manual mode not restored");
            SensitivityBox.IsChecked=true;SensitivityAutoBox.IsChecked=false;SensitivitySlider.Value=-57;ApplySettings();
            if(!SensitivitySlider.IsEnabled||settings.SensitivityThresholdDb!=-57)throw new InvalidOperationException("Manual sensitivity unavailable");
            SensitivityAutoBox.IsChecked=true;ApplySettings();
            if(SensitivitySlider.IsEnabled||settings.SensitivityThresholdDb!=-57||settings.NoiseAutoEnabled)throw new InvalidOperationException("Automatic sensitivity lost manual threshold or changed denoising");
            SensitivityPanel.BringIntoView();await Task.Delay(80);Capture(Path.Combine(directory,"sensitivity-auto-tr.png"));
            SensitivityAutoBox.IsChecked=false;ApplySettings();
            if(!SensitivitySlider.IsEnabled||SensitivitySlider.Value!=-57)throw new InvalidOperationException("Sensitivity manual threshold not restored");
            Capture(Path.Combine(directory,"sensitivity-manual-tr.png"));SensitivityBox.IsChecked=false;ApplySettings();
            if(SensitivitySlider.IsEnabled||SensitivityAutoBox.IsEnabled)throw new InvalidOperationException("Disabled sensitivity controls active");
            Navigate(WorkspacePage.Profiles);
            if(PresetList.Items.Count!=Profiles.Factory().Count)throw new InvalidOperationException("Missing factory profiles");
            PreviewProfileClick(ProfileRawButton,new RoutedEventArgs(Button.ClickEvent));
            if(NavigationList.SelectedIndex!=(int)WorkspacePage.Calibration||player is not null)throw new InvalidOperationException("Empty profile preview did not open calibration safely");
            Navigate(WorkspacePage.Profiles);
            var factory=Profiles.Factory();
            for(int i=0;i<factory.Count;i++){
                PresetList.SelectedIndex=i;await Task.Delay(40);var expected=factory[i].Settings;
                if(settings.CompressorRatio!=expected.CompressorRatio||settings.HighpassHz!=expected.HighpassHz||
                    settings.Bands.Zip(expected.Bands,(a,b)=>a.Type==b.Type&&a.Frequency==b.Frequency&&a.GainDb==b.GainDb&&a.Q==b.Q).Any(equal=>!equal)||player is not null)
                    throw new InvalidOperationException("Profile tone not applied or playback started without a click");
            }
            Navigate(WorkspacePage.Processing,ProcessingSection.Tone);MainScroll.ScrollToTop();await Task.Delay(80);Capture(Path.Combine(directory,"podcast-tone-tr.png"));
            var podcast=Profiles.Factory().Single(p=>p.FactoryId=="podcast");
            File.WriteAllText(Path.Combine(directory,"podcast-preset.json"),Profiles.Serialize(new VoiceProfile{Name=podcast.Name,Description=podcast.Description,Settings=podcast.Settings.Clone()}));
            await RunPersonalSmoke(directory);
            await RunCommunicationSmoke(directory);
            await RunStrongNoiseSmoke(directory);
            RunValidationSmoke(directory);
            MuteBox.IsChecked=true;BypassBox.IsChecked=true;ApplySettings();
            LanguageBox.SelectedIndex=1;Width=780;Height=650;await Task.Delay(150);Capture(Path.Combine(directory,"compact-en.png"));
            Navigate(WorkspacePage.Processing,ProcessingSection.Tone);AdvancedExpander.IsExpanded=true;AdvancedExpander.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"advanced-en.png"));
            Width=640;Height=480;AdvancedExpander.IsExpanded=false;Navigate(WorkspacePage.Overview);MainScroll.ScrollToTop();await Task.Delay(100);Capture(Path.Combine(directory,"small-en.png"));
            Navigate(WorkspacePage.Processing,ProcessingSection.Background);SensitivityBox.IsChecked=true;SensitivityAutoBox.IsChecked=false;SensitivityPanel.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"sensitivity-small-en.png"));
            Navigate(WorkspacePage.Processing,ProcessingSection.Tone);MainScroll.ScrollToTop();await Task.Delay(80);Capture(Path.Combine(directory,"podcast-tone-small-en.png"));
            foreach(string language in new[]{"tr","en"}){
                var driver=new DriverWindow(language){ShowInTaskbar=false,WindowStartupLocation=WindowStartupLocation.Manual,Left=-4000,Top=-4000,Width=420,Height=480};driver.Show();await Task.Delay(250);
                if(!File.Exists(Path.Combine(AppContext.BaseDirectory,"driver","SesMicrophone.cat"))&&driver.InstallationAvailable)throw new IOException("Unsigned development package must not offer installation");
                CaptureWindow(driver,Path.Combine(directory,"driver-"+language+".png"));driver.Close();
            }
            await RunExperienceSmoke(directory);
            await RunRoutingSmoke(directory);
            RunNavigationSmoke();
            await RunDesignSmoke(directory);
            File.WriteAllText(Path.Combine(directory,"ui-result.json"),System.Text.Json.JsonSerializer.Serialize(new {success=true,presets=Profiles.Factory().Count,personalCalibration=true,personalPreview=true,applyAndUndo=true,deviceSource="synthetic",liveDeviceValidation=false,inputs=((IEnumerable<AudioDevice>)InputBox.ItemsSource).Count(),width=ActualWidth,height=ActualHeight}));
            Quit();
        }catch(Exception ex){File.WriteAllText(Path.Combine(AppContext.BaseDirectory,"smoke-error.txt"),ex.ToString());quitting=true;engine.Dispose();Application.Current.Shutdown(1);}
    }
}
