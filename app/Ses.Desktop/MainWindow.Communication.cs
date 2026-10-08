using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Ses.Core;

namespace Ses.Desktop;
public partial class MainWindow
{
    private bool shortcutConflict;
    [DllImport("user32.dll",EntryPoint="RegisterHotKey")]
    private static extern bool TestRegisterKey(IntPtr hwnd,int id,uint modifiers,uint key);
    [DllImport("user32.dll",EntryPoint="UnregisterHotKey")]
    private static extern bool TestUnregisterKey(IntPtr hwnd,int id);
    private ShortcutSettings SavedShortcuts=>new(state.MuteKey,state.BypassKey,state.TalkMode,state.HoldKey,state.PresetKeysEnabled);
    private bool EffectiveMuted=>ShortcutSettings.Muted(state.TalkMode,desktop?.TalkHeld==true,MuteBox.IsChecked==true);
    private void InitializeCommunication()
    {
        HoldKeyBox.ItemsSource=MuteKeyBox.ItemsSource;
        RestoreShortcutControls();
        engine.SetTalkGate(state.TalkMode,false);
    }
    private void RestoreShortcutControls()
    {
        MuteKeyBox.SelectedItem=state.MuteKey;BypassKeyBox.SelectedItem=state.BypassKey;
        TalkModeBox.SelectedIndex=state.TalkMode;HoldKeyBox.SelectedItem=state.HoldKey;PresetKeysBox.IsChecked=state.PresetKeysEnabled;
    }
    private void SelectFactoryShortcut(string id)
    {
        if(quitting||busy||calibrating||sampling||finishing||personalCalibrating)return;
        if(PresetList.ItemsSource is System.Collections.Generic.IEnumerable<ProfileChoice> choices)
        {
            var choice=choices.FirstOrDefault(x=>x.Profile.FactoryId==id);
            if(choice is not null)PresetList.SelectedItem=choice;
        }
    }
    private void ApplyCommunicationKeys()
    {
        var wanted=new ShortcutSettings(MuteKeyBox.SelectedItem as string??"M",BypassKeyBox.SelectedItem as string??"B",TalkModeBox.SelectedIndex,HoldKeyBox.SelectedItem as string??"T",PresetKeysBox.IsChecked==true);
        try
        {
            wanted.Validate();
            if(desktop?.Configure(wanted)!=true){ShortcutConflict();return;}
            state.MuteKey=wanted.MuteKey;state.BypassKey=wanted.BypassKey;state.TalkMode=wanted.TalkMode;state.HoldKey=wanted.HoldKey;state.PresetKeysEnabled=wanted.PresetKeys;
            shortcutConflict=false;UpdateCommunicationLabel();if(SaveState())Status("shortcutSaved");
        }
        catch(InvalidDataException){ShortcutConflict();}
    }
    private void ShortcutConflict(){shortcutConflict=true;RestoreShortcutControls();UpdateCommunicationLabel();Status("hotkeyConflict");}
    private void UpdateCommunicationLabel()
    {
        if(TalkStateText is null)return;
        string value=state.TalkMode==0?T("talkOpen"):T(state.TalkMode==1?"talkPush":"talkMute")+" · Ctrl+Alt+"+state.HoldKey+" · "+T(EffectiveMuted?"talkClosed":"talkPassing");
        if(shortcutConflict)value+=" · "+T("hotkeyConflict");
        if(TalkStateText.Text!=value)TalkStateText.Text=value;
    }
    private void SensitivityModeChanged(object sender,SelectionChangedEventArgs e){if(ready&&!suppress)ApplySettings();}
    private async Task RunCommunicationSmoke(string directory)
    {
        RunWindowsShortcutSmoke();
        ShortcutConflict();SessionStatus();UpdateCommunicationLabel();if(!TalkStateText.Text.Contains(T("hotkeyConflict"),StringComparison.Ordinal))throw new InvalidOperationException("Session status hid shortcut conflict");shortcutConflict=false;
        Width=1120;Height=820;LanguageBox.SelectedIndex=0;
        state.TalkMode=1;engine.SetTalkGate(1,false);MuteBox.IsChecked=false;BypassBox.IsChecked=true;ApplySettings();
        if(!EffectiveMuted)throw new InvalidOperationException("PTT must start closed, including bypass");
        engine.SetTalkGate(1,true);MuteBox.IsChecked=true;ApplySettings();
        if(!EffectiveMuted)throw new InvalidOperationException("Manual mute must dominate PTT");
        engine.SetTalkGate(2,true);state.TalkMode=2;MuteBox.IsChecked=false;ApplySettings();
        // Pure policy/native tests cover held state; no physical-key simulation. Temporary registrations are cleaned up.
        state.TalkMode=0;engine.SetTalkGate(0,false);BypassBox.IsChecked=false;RestoreShortcutControls();
        foreach(string id in ShortcutSettings.FactoryIds){SelectFactoryShortcut(id);if((PresetList.SelectedItem as ProfileChoice)?.Profile.FactoryId!=id)throw new InvalidOperationException("Wrong shortcut profile");}
        NavigationList.SelectedIndex=1;SensitivityBox.IsChecked=true;SensitivityModeBox.SelectedIndex=1;
        SensitivityAttackSlider.Value=5;SensitivityHoldSlider.Value=200;SensitivityReleaseSlider.Value=180;SensitivityHysteresisSlider.Value=4;SensitivityRatioSlider.Value=3;SensitivityReductionSlider.Value=30;ApplySettings();
        if(settings.SensitivityMode!=1||settings.SensitivityRatio!=3||settings.SensitivityHoldMs!=200)throw new InvalidOperationException("Advanced sensitivity not applied");
        SensitivityAdvanced.IsExpanded=true;SensitivityAdvanced.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"expander-tr.png"));
        NavigationList.SelectedIndex=6;MainScroll.ScrollToTop();TalkModeBox.SelectedIndex=1;PresetKeysBox.IsChecked=true;CommunicationPanel.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"communication-tr.png"));
        LanguageBox.SelectedIndex=1;Width=640;Height=480;CommunicationPanel.BringIntoView();await Task.Delay(120);Capture(Path.Combine(directory,"communication-small-en.png"));
        NavigationList.SelectedIndex=1;SensitivityAdvanced.BringIntoView();await Task.Delay(100);Capture(Path.Combine(directory,"expander-small-en.png"));
        File.WriteAllText(Path.Combine(directory,"communication-result.json"),"{\"success\":true,\"factoryHotkeys\":5,\"windowsRegistrationRollback\":true,\"globalKeyboardSimulation\":false,\"expander\":true}");
        RestoreShortcutControls();SensitivityAdvanced.IsExpanded=false;ApplySettings();
    }
    private void RunWindowsShortcutSmoke()
    {
        // Temporary, invisible test window; never sends keyboard input or changes user settings.
        var handle=new System.Windows.Interop.WindowInteropHelper(this).Handle;
        var free=new System.Collections.Generic.List<char>();
        for(char key='A';key<='Z'&&free.Count<4;key++)if(TestRegisterKey(handle,10000,0x4003,key)){TestUnregisterKey(handle,10000);free.Add(key);}
        if(free.Count<4)throw new InvalidOperationException("Not enough free test shortcut chords");
        using var registry=new HotkeyRegistry((id,key)=>TestRegisterKey(handle,id,0x4003,(uint)key),id=>TestUnregisterKey(handle,id));
        if(!registry.Apply(new(free[0].ToString(),free[1].ToString())))throw new InvalidOperationException("Windows shortcut registration failed");
        if(!TestRegisterKey(handle,10000,0x4003,free[2]))throw new InvalidOperationException("Windows conflict fixture failed");
        try
        {
            if(registry.Apply(new(free[3].ToString(),free[2].ToString())))throw new InvalidOperationException("Windows accepted conflicting shortcut");
            if(!TestRegisterKey(handle,10001,0x4003,free[3]))throw new InvalidOperationException("Rollback leaked new Windows shortcut");
            if(TestRegisterKey(handle,10002,0x4003,free[0]))throw new InvalidOperationException("Rollback released working shortcut");
        }
        finally{TestUnregisterKey(handle,10000);TestUnregisterKey(handle,10001);TestUnregisterKey(handle,10002);}
    }
}
