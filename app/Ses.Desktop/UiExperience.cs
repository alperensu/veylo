using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Ses.Core;

namespace Ses.Desktop;
public partial class MainWindow
{
    private readonly GameModePolicy gamePolicy=new();
    private readonly Stopwatch uiClock=Stopwatch.StartNew();
    private readonly DispatcherTimer gameTimer=new(){Interval=TimeSpan.FromSeconds(5)};
    private bool detectingGame;
    private bool forceSmokeEffects;
    private bool? lastEffects;
    private void InitializeExperience(){
        GameModeBox.IsChecked=state.GameModeEnabled;EffectsBox.IsChecked=state.EffectsEnabled;
        GameProcessesBox.Text=string.Join(", ",state.GameProcessNames);gameTimer.Tick+=GameTick;
        SystemParameters.StaticPropertyChanged+=WindowsVisualSettingsChanged;
        IsVisibleChanged+=(_,_)=>ApplyVisualPolicy();ApplyVisualPolicy();
        if((!smoke||args.Contains("--validate-live",StringComparer.Ordinal))&&state.GameModeEnabled){gameTimer.Start();_ = DetectGame();}
    }
    private void StopExperience(){gameTimer.Stop();SystemParameters.StaticPropertyChanged-=WindowsVisualSettingsChanged;}
    private void WindowsVisualSettingsChanged(object? sender,PropertyChangedEventArgs e){
        if(e.PropertyName is nameof(SystemParameters.ClientAreaAnimation) or nameof(SystemParameters.HighContrast))Dispatcher.BeginInvoke(ApplyVisualPolicy);
    }
    private async void GameTick(object? sender,EventArgs e)=>await DetectGame();
    private async Task DetectGame(){
        if(quitting||detectingGame)return;detectingGame=true;
        try{
            if(!state.GameModeEnabled)return;
            while(true){
                var names=state.GameProcessNames;
                var custom=names.ToArray(); // Capture UI-owned settings before the background read.
                var snapshot=await Task.Run(()=>GameDetector.FindMatches(custom));
                if(quitting)return;
                // Re-read after an edit so an obsolete custom match cannot start the hold.
                if(state.GameModeEnabled&&!ReferenceEquals(names,state.GameProcessNames))continue;
                gamePolicy.Update(state.GameModeEnabled,snapshot,custom,uiClock.Elapsed.TotalSeconds);ApplyVisualPolicy();return;
            }
        }
        catch(Exception ex)when(ex is Win32Exception or InvalidOperationException){if(!quitting){GameModeDetail.Text=T("gameDetectionError");}}
        finally{detectingGame=false;}
    }
    private void ApplyVisualPolicy(){
        if(quitting||GameModeDetail is null)return;
        bool glass=state.EffectsEnabled&&!SystemParameters.HighContrast&&!gamePolicy.Active&&IsVisible;
        bool effects=glass&&(SystemParameters.ClientAreaAnimation||(smoke&&forceSmokeEffects));
        if(Motion.GetEnabled(this)!=effects)Scope.Clear();
        Motion.SetEnabled(this,effects);
        if(lastEffects!=glass){
            Resources["SurfaceBrush"]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(glass?"#A6213038":"#202C33"));
            Resources["GlassChromeBrush"]=new SolidColorBrush((Color)ColorConverter.ConvertFromString(glass?"#8A1C2B32":"#1B272F"));
            AmbientBackdrop.Visibility=glass?Visibility.Visible:Visibility.Collapsed;Scope.Clear();lastEffects=glass;
        }
        var interval=TimeSpan.FromMilliseconds(gamePolicy.Active?200:100);if(meterTimer.Interval!=interval)meterTimer.Interval=interval;
        GameBadgeText.Text=T(gamePolicy.Active?"gameActive":state.GameModeEnabled?"gameArmed":"gameOff");
        GameModeDetail.Text=gamePolicy.Active?T("gameDetected")+" · "+gamePolicy.DetectedName+"\n"+T("gameActiveHint"):
            T(!state.GameModeEnabled?"gameDisabledHint":!state.EffectsEnabled?"effectsDisabledHint":!(SystemParameters.ClientAreaAnimation||(smoke&&forceSmokeEffects))||SystemParameters.HighContrast?"systemReducedMotion":"gameWaitingHint");
        if(!effects){foreach(var page in new FrameworkElement[]{OverviewPage,NoisePage,BalancePage,QualityPage,ProfilesPage,TestPage,PreferencesPage})Motion.Reset(page);}
    }
    private async void GameModeChanged(object sender,RoutedEventArgs e){
        if(!ready||suppress||quitting)return;
        state.GameModeEnabled=GameModeBox.IsChecked==true;state.EffectsEnabled=EffectsBox.IsChecked==true;
        gamePolicy.Update(state.GameModeEnabled,Array.Empty<GameObservation>(),state.GameProcessNames,uiClock.Elapsed.TotalSeconds);ApplyVisualPolicy();ScheduleSave();
        if(!smoke){if(state.GameModeEnabled){gameTimer.Start();await DetectGame();}else gameTimer.Stop();}
    }
    private void SaveGameProcesses(object sender,RoutedEventArgs e){
        if(quitting)return;
        var names=GameProcessesBox.Text.Split(',',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries);
        try{var values=new System.Collections.Generic.List<string>(names);GameModePolicy.ValidateNames(values);state.GameProcessNames=values;GameProcessesBox.Text=string.Join(", ",values);ScheduleSave();GameModeDetail.Text=T("gameListSaved");}
        catch(System.IO.InvalidDataException){GameModeDetail.Text=T("gameListInvalid");}
    }
    private void GameBadgeClick(object sender,RoutedEventArgs e){NavigationList.SelectedIndex=6;GameSettingsPanel.BringIntoView();}
    private void TuneVoiceClick(object sender,RoutedEventArgs e){NavigationList.SelectedIndex=5;PersonalCalibrateButton.BringIntoView();}
    private void MinimizeClick(object sender,RoutedEventArgs e)=>WindowState=WindowState.Minimized;
    private void MaximizeClick(object sender,RoutedEventArgs e)=>WindowState=WindowState==WindowState.Maximized?WindowState.Normal:WindowState.Maximized;
    private void HideClick(object sender,RoutedEventArgs e)=>Close();
    private void CaptionDrag(object sender,MouseButtonEventArgs e){if(e.ChangedButton!=MouseButton.Left)return;if(e.ClickCount==2)MaximizeClick(sender,e);else DragMove();}
    private async Task RunExperienceSmoke(string directory){
        // Explicit visual-test override only: real windows always honor OS reduced motion.
        forceSmokeEffects=true;GameModeBox.IsChecked=true;EffectsBox.IsChecked=true;ApplyVisualPolicy();
        MuteBox.IsChecked=false;BypassBox.IsChecked=false;Width=1120;Height=820;LanguageBox.SelectedIndex=0;NavigationList.SelectedIndex=0;
        await Task.Delay(350);Capture(System.IO.Path.Combine(directory,"glass-desktop-tr.png"));
        NavigationList.SelectedIndex=4;await Task.Delay(350);Capture(System.IO.Path.Combine(directory,"glass-profiles-tr.png"));
        var settingsBefore=Profiles.Serialize(CurrentProfile());
        var observed=await Task.Run(GameDetector.Read);if(Array.Exists(observed,p=>string.IsNullOrWhiteSpace(p.ProcessName)))throw new InvalidOperationException("Detector returned invalid process metadata"); // Another Veylo instance is legitimate; self exclusion is by PID.
        await StartSession();if(engine.Metrics().Connected!=1)throw new System.IO.IOException("Game UI test needs an available microphone");
        GameBadge.RaiseEvent(new MouseEventArgs(Mouse.PrimaryDevice,0){RoutedEvent=UIElement.MouseEnterEvent});
        if(GameBadge.RenderTransform is not ScaleTransform scale||!scale.HasAnimatedProperties)throw new InvalidOperationException("Hover animation did not start");
        var before=engine.Metrics();gamePolicy.Update(true,new[]{new GameObservation("VALORANT-Win64-Shipping")},state.GameProcessNames,uiClock.Elapsed.TotalSeconds);ApplyVisualPolicy();NavigationList.SelectedIndex=0;
        await Task.Delay(350);
        if(Motion.GetEnabled(GameBadge)||scale.HasAnimatedProperties||AmbientBackdrop.Visibility!=Visibility.Collapsed||meterTimer.Interval.TotalMilliseconds!=200||engine.Metrics().Running!=1||Profiles.Serialize(CurrentProfile())!=settingsBefore)throw new InvalidOperationException("Game mode changed audio settings or failed to stop effects");
        Capture(System.IO.Path.Combine(directory,"game-active-tr.png"));
        NavigationList.SelectedIndex=6;await Task.Delay(150);Capture(System.IO.Path.Combine(directory,"game-settings-tr.png"));
        GameProcessesBox.Text="../bad.exe";SaveGameProcesses(this,new RoutedEventArgs());if(state.GameProcessNames.Count!=0)throw new InvalidOperationException("Invalid game process accepted");
        GameProcessesBox.Text="MyGame.exe";SaveGameProcesses(this,new RoutedEventArgs());if(state.GameProcessNames.Count!=1)throw new InvalidOperationException("Game process list did not save");
        GameModeBox.IsChecked=false;if(gamePolicy.Active||!Motion.GetEnabled(this))throw new InvalidOperationException("Manual game-mode disable did not restore effects");
        EffectsBox.IsChecked=false;if(Motion.GetEnabled(this))throw new InvalidOperationException("Manual effect disable failed");EffectsBox.IsChecked=true;
        Hide();if(Motion.GetEnabled(this)||engine.Metrics().Running!=1)throw new InvalidOperationException("Hidden UI must stop motion but retain audio");Show();
        MaximizeClick(this,new RoutedEventArgs());if(WindowState!=WindowState.Maximized)throw new InvalidOperationException("Maximize failed");MaximizeClick(this,new RoutedEventArgs());
        Width=640;Height=480;LanguageBox.SelectedIndex=1;NavigationList.SelectedIndex=6;await Task.Delay(350);Capture(System.IO.Path.Combine(directory,"glass-settings-small-en.png"));
        NavigationList.SelectedIndex=1;await Task.Delay(350);Capture(System.IO.Path.Combine(directory,"glass-noise-small-en.png"));
        NavigationList.SelectedIndex=0;await Task.Delay(350);Capture(System.IO.Path.Combine(directory,"glass-small-en.png"));
        if(MainScroll.ScrollableWidth>1)throw new InvalidOperationException("Small layout has horizontal overflow");
        if(engine.Metrics().Connected!=1||engine.Metrics().ProcessedFrames<=before.ProcessedFrames)throw new InvalidOperationException("Microphone frames did not continue through visual policy changes");
        await EngineOperation(engine.Stop);
        System.IO.File.WriteAllText(System.IO.Path.Combine(directory,"experience-result.json"),System.Text.Json.JsonSerializer.Serialize(new{success=true,gameEffectsStopped=true,audioContinued=true,settingsPreserved=true,hiddenMotionStopped=true,manualControls=true,gameListValidation=true,hoverClockCancelled=true,processMetadataReadable=true,observedProcesses=observed.Length,systemAnimations=SystemParameters.ClientAreaAnimation,visualTestOverride=true,framesAdvanced=engine.Metrics().ProcessedFrames-before.ProcessedFrames}));
        forceSmokeEffects=false;ApplyVisualPolicy();
    }
}
