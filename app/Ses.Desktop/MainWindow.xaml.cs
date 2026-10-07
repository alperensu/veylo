using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Media;
using System.Threading.Tasks;
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
    private readonly DispatcherTimer meterTimer=new(){Interval=TimeSpan.FromMilliseconds(100)};
    private readonly DispatcherTimer applyTimer=new(){Interval=TimeSpan.FromMilliseconds(180)};
    private readonly DispatcherTimer saveTimer=new(){Interval=TimeSpan.FromSeconds(1)};
    private AudioSettings settings;
    private DesktopServices? desktop;
    private bool ready,suppress,busy,quitting,ownsCapture,calibrating,sampling,finishing;
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
        store=new UserStore(smoke?Path.Combine(AppContext.BaseDirectory,"smoke-state"):null);state=smoke?new UserState():store.Load();settings=state.Settings.Clone();
        engine=new NativeEngine(AppContext.BaseDirectory);
        InitializeComponent();
        LanguageBox.SelectedIndex=state.Language=="en"?1:0;ChangeLanguage(state.Language);
        MuteKeyBox.ItemsSource=Enumerable.Range('A',26).Select(x=>((char)x).ToString()).ToArray();BypassKeyBox.ItemsSource=MuteKeyBox.ItemsSource;
        MuteKeyBox.SelectedItem=state.MuteKey;BypassKeyBox.SelectedItem=state.BypassKey;
        StartupBox.IsChecked=!smoke&&DesktopServices.StartsWithWindows();
        RebuildProfiles();LoadControls();
        meterTimer.Tick+=MeterTick;
        applyTimer.Tick+=(_,_)=>{applyTimer.Stop();ApplySettings();};
        saveTimer.Tick+=(_,_)=>{saveTimer.Stop();SaveState();};
        IsVisibleChanged+=(_,_)=>{if(IsVisible)meterTimer.Start();else if(!sampling)meterTimer.Stop();};
    }
    private async void WindowLoaded(object sender,RoutedEventArgs e)
    {
        await RefreshDevices();ready=true;
        if(!smoke){desktop=new DesktopServices(this,()=>MuteBox.IsChecked=!(MuteBox.IsChecked??false),()=>BypassBox.IsChecked=!(BypassBox.IsChecked??false),Quit);if(!desktop.Keys(state.MuteKey,state.BypassKey))Status("hotkeyConflict");}
        ApplySettings();meterTimer.Start();if(store.LoadWarning)Status("storeWarning");
        if(args.Contains("--minimized")&&!smoke)Hide();
        if(smoke)await RunSmoke();
    }
    private void ChangeLanguage(string language)
    {
        var culture=CultureInfo.GetCultureInfo(language=="tr"?"tr-TR":"en-US");CultureInfo.CurrentCulture=culture;CultureInfo.CurrentUICulture=culture;Language=System.Windows.Markup.XmlLanguage.GetLanguage(culture.Name);
        Application.Current.Resources.MergedDictionaries[1]=new ResourceDictionary{Source=new Uri("Resources/"+language+".xaml",UriKind.Relative)};
        EqTypes=[T("peak"),T("lowShelf"),T("highShelf")];state.Language=language;
        if(BandsControl is not null){BandsControl.ItemsSource=null;BandsControl.ItemsSource=settings.Bands;}
        if(OutputBox?.ItemsSource is AudioDevice[] outputs){string id=(OutputBox.SelectedItem as AudioDevice)?.Id??"";suppress=true;var translated=outputs.Select(d=>d.Id.Length==0?d with{Name=T("captureOnly")}:d).ToArray();OutputBox.ItemsSource=translated;OutputBox.SelectedItem=translated.FirstOrDefault(d=>d.Id==id);suppress=false;RouteText();}
        if(CalibrationMessage is not null&&!calibrating)CalibrationMessage.Text=T("ambientPrompt");
        desktop?.Translate();
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
        if(ProfileNameBox.Text.Length==0)ProfileNameBox.Text=state.Language=="en"?"My voice":"Benim sesim";suppress=previous;
    }
    private void LoadControls()
    {
        suppress=true;NoiseBox.IsChecked=settings.NoiseEnabled;BalanceBox.IsChecked=settings.AgcEnabled;DeesserBox.IsChecked=settings.DeesserEnabled;
        NoiseSlider.Value=settings.NoiseMix;WarmthSlider.Value=settings.Bands[0].GainDb;ClaritySlider.Value=settings.Bands[2].GainDb;
        HighpassSlider.Value=settings.HighpassHz;TargetSlider.Value=settings.TargetDb;MinGainSlider.Value=settings.MinGainDb;MaxGainSlider.Value=settings.MaxGainDb;ThresholdSlider.Value=settings.CompressorThresholdDb;RatioSlider.Value=settings.CompressorRatio;AttackSlider.Value=settings.AttackMs;ReleaseSlider.Value=settings.ReleaseMs;KneeSlider.Value=settings.KneeDb;DeessMaxSlider.Value=settings.DeesserMaxDb;OutputGainSlider.Value=settings.OutputDb;
        BandsControl.ItemsSource=null;BandsControl.ItemsSource=settings.Bands;UpdateLabels();suppress=false;
    }
    private void ReadControls()
    {
        settings.NoiseEnabled=NoiseBox.IsChecked==true;settings.AgcEnabled=BalanceBox.IsChecked==true;settings.DeesserEnabled=DeesserBox.IsChecked==true;
        settings.NoiseMix=(float)NoiseSlider.Value;settings.Bands[0].GainDb=(float)WarmthSlider.Value;settings.Bands[2].GainDb=(float)ClaritySlider.Value;
        settings.HighpassHz=(float)HighpassSlider.Value;settings.TargetDb=(float)TargetSlider.Value;settings.MinGainDb=(float)MinGainSlider.Value;settings.MaxGainDb=(float)MaxGainSlider.Value;settings.CompressorThresholdDb=(float)ThresholdSlider.Value;settings.CompressorRatio=(float)RatioSlider.Value;settings.AttackMs=(float)AttackSlider.Value;settings.ReleaseMs=(float)ReleaseSlider.Value;settings.KneeDb=(float)KneeSlider.Value;settings.DeesserMaxDb=(float)DeessMaxSlider.Value;settings.OutputDb=(float)OutputGainSlider.Value;
    }
    private void UpdateLabels()
    {
        NoiseValue.Text=$"{NoiseSlider.Value*100:0}%";WarmthValue.Text=$"{WarmthSlider.Value:+0.#;-0.#;0} dB";ClarityValue.Text=$"{ClaritySlider.Value:+0.#;-0.#;0} dB";
        HighpassValue.Text=$"{HighpassSlider.Value:0.#} Hz";TargetValue.Text=$"{TargetSlider.Value:0.#} dBFS";MinGainValue.Text=$"{MinGainSlider.Value:0.#} dB";MaxGainValue.Text=$"{MaxGainSlider.Value:0.#} dB";ThresholdValue.Text=$"{ThresholdSlider.Value:0.#} dBFS";RatioValue.Text=$"{RatioSlider.Value:0.#} :1";AttackValue.Text=$"{AttackSlider.Value:0.#} ms";ReleaseValue.Text=$"{ReleaseSlider.Value:0.#} ms";KneeValue.Text=$"{KneeSlider.Value:0.#} dB";DeessMaxValue.Text=$"{DeessMaxSlider.Value:0.#} dB";OutputGainValue.Text=$"{OutputGainSlider.Value:0.#} dB";
    }
    private float NoiseFloor => InputBox.SelectedItem is AudioDevice d && state.Calibrations.TryGetValue(d.Id,out var c)?c.NoiseFloorDb:-60;
    private void ApplySettings()
    {
        if(!ready)return;
        try{ReadControls();settings.Validate();engine.Update(settings,NoiseFloor,MuteBox.IsChecked==true,BypassBox.IsChecked==true);UpdateLabels();if(rawSample.Length>0)matched=null;ScheduleSave();}
        catch(InvalidDataException){Status("invalidProfile");}
    }
    private void SettingsChanged(object sender,RoutedPropertyChangedEventArgs<double> e){if(!ready||suppress)return;ModifiedLabel.Text=T("custom");UpdateLabels();applyTimer.Stop();applyTimer.Start();}
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
        if(!ready||suppress||PresetList.SelectedItem is not ProfileChoice choice)return;
        settings=choice.Profile.Settings.Clone();LoadControls();ModifiedLabel.Text="";ProfileNameBox.Text=choice.Profile.FactoryId is null?choice.Name:(state.Language=="en"?"My voice":"Benim sesim");ApplySettings();
        state.ActiveProfile=ProfileKey(choice.Profile);
    }
    private async Task RefreshDevices()
    {
        try {
            var all=await Task.Run(engine.Devices);suppress=true;
            string selected=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;
            InputBox.ItemsSource=all.Where(d=>d.Input).ToArray();InputBox.SelectedItem=selected.Length>0?all.FirstOrDefault(d=>d.Input&&d.Id==selected):all.FirstOrDefault(d=>d.Input&&d.Default)??all.FirstOrDefault(d=>d.Input);
            var local=new AudioDevice("",T("captureOnly"),false,false);var outputs=new[]{local}.Concat(all.Where(d=>!d.Input)).ToArray();OutputBox.ItemsSource=outputs;
            OutputBox.SelectedItem=outputs.FirstOrDefault(d=>d.Id==state.OutputId)??local;
            suppress=false;RouteText();
        }catch(IOException){suppress=false;Status("permissionError");}
    }
    private void RouteText()
    {
        var all=OutputBox.ItemsSource as AudioDevice[];bool cable=all?.Any(d=>d.Name.Contains("CABLE",StringComparison.OrdinalIgnoreCase))==true;
        RouteHint.Text=cable?T("routeHint"):T("driverMissing");
    }
    private async void RefreshClick(object sender,RoutedEventArgs e){if(busy||sampling)return;await RefreshDevices();}
    private async void DeviceChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready||suppress||busy)return;
        if(engine.Metrics().Running!=0){SetBusy(true);await Task.Run(engine.Stop);SetBusy(false);}
        ApplySettings();RouteText();ScheduleSave();Status("ready");
    }
    private void SetBusy(bool value)
    {
        busy=value;StartButton.IsEnabled=!value&&!sampling;InputBox.IsEnabled=!value&&!sampling;OutputBox.IsEnabled=!value&&!sampling;
        RecordButton.IsEnabled=!value&&!calibrating;CalibrateButton.IsEnabled=!value&&!sampling;
        StartButton.Content=value?T("working"):(engine.Metrics().Running!=0?T("stop"):T("start"));
    }
    private async void StartClick(object sender,RoutedEventArgs e)
    {
        if(busy||sampling)return;SetBusy(true);
        try {
            if(engine.Metrics().Running!=0){await Task.Run(engine.Stop);Status("ready");}
            else if(InputBox.SelectedItem is AudioDevice input){ApplySettings();string output=(OutputBox.SelectedItem as AudioDevice)?.Id??"";await Task.Run(()=>engine.Start(input.Id,output));Status(output.Length==0?"localRunning":"running");}
            else Status("noInput");
        }catch(IOException){Status("permissionError");}finally{SetBusy(false);}
    }
    private async Task<bool> EnsureCapture()
    {
        if(engine.Metrics().Running!=0)return true;
        if(InputBox.SelectedItem is not AudioDevice input){Status("noInput");return false;}
        ApplySettings();try{await Task.Run(()=>engine.Start(input.Id,null));ownsCapture=true;return true;}catch(IOException){Status("permissionError");return false;}
    }
    private async void RecordClick(object sender,RoutedEventArgs e)
    {
        if(busy)return;if(sampling){await FinishSample();return;}await BeginSample(false);
    }
    private async void CalibrateClick(object sender,RoutedEventArgs e){if(busy||sampling)return;await BeginSample(true);}
    private async Task BeginSample(bool calibration)
    {
        SetBusy(true);
        try {
            if(!await EnsureCapture())return;
            player?.Stop();rawSample=[];matched=null;ListenRawButton.IsEnabled=ListenProcessedButton.IsEnabled=ExportWaveButton.IsEnabled=false;
            engine.BeginSample(calibration?15:20);sampling=true;calibrating=calibration;finishing=false;recordingClock.Restart();meterTimer.Start();
            RecordButton.Content=T("recordStop");SampleProgress.Maximum=calibration?15:20;SampleProgress.Value=0;Status(calibration?"ambientNow":"record");
        }catch(Exception ex)when(ex is IOException or InvalidOperationException){Status("error");}finally{SetBusy(false);}
    }
    private async Task FinishSample()
    {
        if(finishing||!sampling)return;finishing=true;sampling=false;bool wasCalibration=calibrating;calibrating=false;SetBusy(true);
        try {
            engine.EndSample();if(ownsCapture){await Task.Run(engine.Stop);ownsCapture=false;}rawSample=engine.CopySample(false);
            if(wasCalibration){
                var result=Calibration.Analyze(rawSample);
                if(result.Success&&InputBox.SelectedItem is AudioDevice d){state.Calibrations[d.Id]=new(result.NoiseFloorDb,result.SpeechDb,DateTimeOffset.UtcNow);CalibrationMessage.Text=T("calibrated");ApplySettings();Status("calibrated");}
                else {CalibrationMessage.Text=T(result.Error);Status(result.Error);}
            }else Status(rawSample.Length>=480?"sampleReady":"calibrationIncomplete");
            ListenRawButton.IsEnabled=ListenProcessedButton.IsEnabled=ExportWaveButton.IsEnabled=rawSample.Length>=480;RecordButton.Content=T("record");SaveState();
        }catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException){Status("error");}finally{SetBusy(false);finishing=false;if(!IsVisible)meterTimer.Stop();}
    }
    private async Task<MatchedSample?> RenderSample()
    {
        if(rawSample.Length<480){Status("noSample");return null;}
        if(matched is not null)return matched;
        SetBusy(true);
        try{ReadControls();var snapshot=settings.Clone();float floor=NoiseFloor;matched=await Task.Run(()=>{using var offline=new NativeEngine(AppContext.BaseDirectory);offline.Update(snapshot,floor);var processed=offline.Process(rawSample,snapshot,floor);return AudioSamples.Match(rawSample,processed);});return matched;}
        catch(Exception ex)when(ex is IOException or InvalidDataException or InvalidOperationException){Status("error");return null;}
        finally{SetBusy(false);}
    }
    private void Play(float[] sample)
    {
        player?.Stop();player?.Dispose();playbackStream?.Dispose();playbackStream=new(AudioSamples.Wave(sample));player=new SoundPlayer(playbackStream);player.Play();Status("headphones");
    }
    private async void ListenRawClick(object sender,RoutedEventArgs e){if(busy)return;var pair=await RenderSample();if(pair is not null)Play(pair.Raw);}
    private async void ListenProcessedClick(object sender,RoutedEventArgs e){if(busy)return;var pair=await RenderSample();if(pair is not null)Play(pair.Processed);}
    private async void ExportWaveClick(object sender,RoutedEventArgs e)
    {
        if(busy)return;var pair=await RenderSample();if(pair is null)return;
        var dialog=new SaveFileDialog {Filter="WAV (*.wav)|*.wav",FileName="ses-processed.wav"};if(dialog.ShowDialog(this)!=true)return;
        try{File.WriteAllBytes(dialog.FileName,AudioSamples.Wave(pair.Processed));Status("exported");}catch(IOException){Status("error");}
    }
    private VoiceProfile CurrentProfile()=>new(){Name=ProfileNameBox.Text.Trim(),Settings=settings.Clone()};
    private void SaveProfileClick(object sender,RoutedEventArgs e)
    {
        try{
            ReadControls();var p=CurrentProfile();Profiles.Serialize(p);var index=state.Profiles.FindIndex(v=>string.Equals(v.Name,p.Name,StringComparison.OrdinalIgnoreCase));
            if(index>=0)state.Profiles[index]=p;else {if(state.Profiles.Count>=100)throw new InvalidDataException();state.Profiles.Add(p);}
            RebuildProfiles(ProfileKey(p));SaveState();Status("saved");
        }catch(InvalidDataException){Status("invalidProfile");}
    }
    private void ImportClick(object sender,RoutedEventArgs e)
    {
        var dialog=new OpenFileDialog{Filter="SES preset (*.json)|*.json",Multiselect=false};if(dialog.ShowDialog(this)!=true)return;
        try{var p=Profiles.Load(dialog.FileName);p.FactoryId=null;int index=state.Profiles.FindIndex(v=>string.Equals(v.Name,p.Name,StringComparison.OrdinalIgnoreCase));if(index>=0)state.Profiles[index]=p;else{if(state.Profiles.Count>=100)throw new InvalidDataException();state.Profiles.Add(p);}settings=p.Settings.Clone();RebuildProfiles(ProfileKey(p));ProfileNameBox.Text=p.Name;LoadControls();ApplySettings();SaveState();Status("imported");}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("invalidProfile");}
    }
    private void ExportClick(object sender,RoutedEventArgs e)
    {
        var dialog=new SaveFileDialog{Filter="SES preset (*.json)|*.json",FileName="ses-preset.json"};if(dialog.ShowDialog(this)!=true)return;
        try{ReadControls();File.WriteAllText(dialog.FileName,Profiles.Serialize(CurrentProfile()));Status("exported");}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("invalidProfile");}
    }
    private void ScheduleSave(){if(!ready||smoke)return;saveTimer.Stop();saveTimer.Start();}
    private void SaveState()
    {
        if(!ready||smoke)return;
        try{state.Settings=settings.Clone();state.ActiveProfile=PresetList.SelectedItem is ProfileChoice p?ProfileKey(p.Profile):state.ActiveProfile;state.InputId=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;state.OutputId=(OutputBox.SelectedItem as AudioDevice)?.Id??state.OutputId;store.Save(state);}
        catch(Exception ex)when(ex is IOException or InvalidDataException or UnauthorizedAccessException){Status("error");}
    }
    private void StartupChanged(object sender,RoutedEventArgs e)
    {
        if(!ready||suppress||smoke)return;try{DesktopServices.Startup(StartupBox.IsChecked==true);}
        catch(Exception ex)when(ex is UnauthorizedAccessException or IOException or System.Security.SecurityException){suppress=true;StartupBox.IsChecked=DesktopServices.StartsWithWindows();suppress=false;Status("error");}
    }
    private void ApplyKeysClick(object sender,RoutedEventArgs e)
    {
        string m=MuteKeyBox.SelectedItem as string??"M",b=BypassKeyBox.SelectedItem as string??"B";
        if(desktop?.Keys(m,b)!=true){desktop?.Keys(state.MuteKey,state.BypassKey);Status("hotkeyConflict");return;}
        state.MuteKey=m;state.BypassKey=b;SaveState();Status("shortcutSaved");
    }
    private void DriverClick(object sender,RoutedEventArgs e)=>Process.Start(new ProcessStartInfo("https://vb-audio.com/Cable/"){UseShellExecute=true});
    private void Status(string key){statusKey=key;StatusText.Text=T(key);}
    private async void MeterTick(object? sender,EventArgs e)
    {
        var m=engine.Metrics();InputMeter.Value=Math.Max(-60,m.InputDb);OutputMeter.Value=Math.Max(-60,m.OutputDb);
        InputLevel.Text=$"{m.InputDb:0.0} dBFS";OutputLevel.Text=$"{m.OutputDb:0.0} dBFS";GainLevel.Text=$"{m.GainDb:+0.0;-0.0;0.0} dB";CompressionLevel.Text=$"{m.CompressionDb:0.0} dB";
        DiagnosticsText.Text=$"{T("dspTime")}: {m.ProcessingMs:0.00} ms  ·  {T("latency")}: {(m.Running!=0?m.EstimatedBufferMs.ToString("0.0")+" ms":"—")}  ·  {T("measuredLatency")}";
        DiagnosticsText.Text+=$"\n{T("bufferErrors")}: {m.Underruns} / {m.Overruns}  ·  {T("clockDrift")}: {m.DriftPpm:0} ppm  ·  {T("inputClips")}: {m.ClippedSamples}";
        if(m.Running!=0&&m.Connected==0&&!sampling)Status("disconnected");
        else if(statusKey=="disconnected"&&m.Connected!=0)Status((OutputBox.SelectedItem as AudioDevice)?.Id.Length>0?"running":"localRunning");
        if(sampling&&!finishing){SampleProgress.Value=m.SampleFrames/48000d;if(calibrating)CalibrationMessage.Text=T(m.SampleFrames<240000?"ambientNow":"speechNow");if(m.SampleFrames>=(calibrating?720000u:960000u)||recordingClock.Elapsed.TotalSeconds>25)await FinishSample();}
    }
    private void WindowStateChanged(object sender,EventArgs e){if(WindowState==WindowState.Minimized&&!smoke){Hide();desktop?.Notice();}}
    private void WindowSizeChanged(object sender,SizeChangedEventArgs e){if(PresetColumn is not null)PresetColumn.Width=new GridLength(ActualWidth<820?160:230);}
    private void WindowClosing(object? sender,CancelEventArgs e){if(!quitting&&!smoke){e.Cancel=true;Hide();desktop?.Notice();}}
    private void Quit(){quitting=true;meterTimer.Stop();applyTimer.Stop();saveTimer.Stop();SaveState();player?.Stop();player?.Dispose();playbackStream?.Dispose();desktop?.Dispose();engine.Dispose();Close();Application.Current.Shutdown();}
    private void Capture(string path)
    {
        UpdateLayout();var content=(FrameworkElement)Content;int width=(int)(content.ActualWidth+content.Margin.Left+content.Margin.Right),height=(int)(content.ActualHeight+content.Margin.Top+content.Margin.Bottom);
        var visual=new DrawingVisual();using(var drawing=visual.RenderOpen()){drawing.DrawRectangle(Background,null,new Rect(0,0,width,height));drawing.DrawRectangle(new VisualBrush(content),null,new Rect(content.Margin.Left,content.Margin.Top,content.ActualWidth,content.ActualHeight));}
        var image=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);image.Render(visual);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(image));using var stream=File.Create(path);encoder.Save(stream);
    }
    private async Task RunSmoke()
    {
        try{
            string directory=args.SkipWhile(x=>x!="--out").Skip(1).FirstOrDefault()??Path.Combine(AppContext.BaseDirectory,"smoke");Directory.CreateDirectory(directory);
            if(args.Contains("--validate-live")){await ValidateLive(directory);Quit();return;}
            await Task.Delay(300);Capture(Path.Combine(directory,"desktop-tr.png"));
            for(int i=0;i<4;i++){PresetList.SelectedIndex=i;await Task.Delay(40);if(settings.CompressorRatio<1)throw new InvalidOperationException("Preset not applied");}
            MuteBox.IsChecked=true;BypassBox.IsChecked=true;ApplySettings();
            LanguageBox.SelectedIndex=1;Width=780;Height=650;await Task.Delay(150);Capture(Path.Combine(directory,"compact-en.png"));
            AdvancedExpander.IsExpanded=true;AdvancedExpander.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"advanced-en.png"));
            Width=640;Height=480;AdvancedExpander.IsExpanded=false;MainScroll.ScrollToTop();await Task.Delay(100);Capture(Path.Combine(directory,"small-en.png"));
            File.WriteAllText(Path.Combine(directory,"ui-result.json"),System.Text.Json.JsonSerializer.Serialize(new {success=true,presets=4,inputs=((IEnumerable<AudioDevice>)InputBox.ItemsSource).Count(),width=ActualWidth,height=ActualHeight}));
            Quit();
        }catch(Exception ex){File.WriteAllText(Path.Combine(AppContext.BaseDirectory,"smoke-error.txt"),ex.ToString());quitting=true;engine.Dispose();Application.Current.Shutdown(1);}
    }
    private async Task ValidateLive(string directory)
    {
        // Explicit integration-test mode: capture only, RAM sample, no playback or persisted settings.
        var device=((IEnumerable<AudioDevice>)InputBox.ItemsSource).FirstOrDefault(d=>d.Name.Contains("USB PnP",StringComparison.OrdinalIgnoreCase))??InputBox.SelectedItem as AudioDevice??throw new IOException("No input device");
        await Task.Run(()=>engine.Start(device.Id,null));engine.BeginSample(2);Hide();meterTimer.Stop();
        await Task.Delay(2000);
        using var process=Process.GetCurrentProcess();process.Refresh();var cpu=process.TotalProcessorTime;var clock=Stopwatch.StartNew();
        long maxWorkingSet=0;uint underruns=0,overruns=0;
        for(int i=0;i<30;i++){await Task.Delay(1000);process.Refresh();maxWorkingSet=Math.Max(maxWorkingSet,process.WorkingSet64);var m=engine.Metrics();underruns=m.Underruns;overruns=m.Overruns;}
        var metrics=engine.Metrics();process.Refresh();double cpuPercent=(process.TotalProcessorTime-cpu).TotalSeconds/clock.Elapsed.TotalSeconds/Environment.ProcessorCount*100;
        await Task.Run(engine.Stop);var sample=engine.CopySample(false);
        if(metrics.Connected!=1||metrics.ProcessedFrames<48000*30||sample.Length!=96000||sample.Any(x=>!float.IsFinite(x)))throw new IOException("Live capture did not produce bounded samples");
        File.WriteAllText(Path.Combine(directory,"live-result.json"),System.Text.Json.JsonSerializer.Serialize(new {success=true,device=device.Name,durationSeconds=clock.Elapsed.TotalSeconds,cpuPercent,maxWorkingSetMB=maxWorkingSet/1048576d,processedFrames=metrics.ProcessedFrames,sampleFrames=sample.Length,inputDb=metrics.InputDb,dspBlockMs=metrics.ProcessingMs,underruns,overruns,captureOnly=true,measuredEndToEndLatencyMs=(double?)null},new System.Text.Json.JsonSerializerOptions{WriteIndented=true}));
    }
}
