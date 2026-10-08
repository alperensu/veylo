using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using Ses.Core;

namespace Ses.Desktop;

public partial class MainWindow
{
    private enum WorkspacePage { Overview, Processing, Profiles, Calibration, Application }
    private enum ProcessingSection { Background, Level, Tone }

    private void Navigate(WorkspacePage page,ProcessingSection? section=null)
    {
        NavigationList.SelectedIndex=(int)page;
        if(section is not null)ProcessingTabs.SelectedIndex=(int)section;
    }
    private void ProfilesClick(object sender,RoutedEventArgs e)=>Navigate(WorkspacePage.Profiles);
    private void ProcessingTabChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ReferenceEquals(e.Source,ProcessingTabs)||MainScroll is null)return;
        MainScroll.ScrollToTop();
        if(ProcessingTabs.SelectedContent is FrameworkElement section)Motion.Reveal(section);
    }
    private void RunNavigationSmoke()
    {
        if(!OfflineSmoke)throw new InvalidOperationException("Navigation validation requires offline mode");
        if(NavigationList.Items.Count!=5||ProcessingTabs.Items.Count!=3)throw new InvalidOperationException("Unexpected navigation structure");
        var before=Profiles.Serialize(CurrentProfile());
        ProfilesClick(this,new RoutedEventArgs());if(NavigationList.SelectedIndex!=(int)WorkspacePage.Profiles)throw new InvalidOperationException("Profile shortcut opened wrong section");
        TuneVoiceClick(this,new RoutedEventArgs());if(NavigationList.SelectedIndex!=(int)WorkspacePage.Calibration)throw new InvalidOperationException("Calibration shortcut opened wrong section");
        GameBadgeClick(this,new RoutedEventArgs());if(NavigationList.SelectedIndex!=(int)WorkspacePage.Application)throw new InvalidOperationException("Game shortcut opened wrong section");
        foreach(ProcessingSection section in Enum.GetValues<ProcessingSection>()){
            Navigate(WorkspacePage.Processing);
            UpdateLayout();
            // WPF exposes item selection through the TabControl peer, not wrapper peers.
            var tabPeer=UIElementAutomationPeer.CreatePeerForElement(ProcessingTabs);
            var peer=tabPeer?.GetChildren()?[(int)section];
            if(peer?.GetPattern(PatternInterface.SelectionItem) is not ISelectionItemProvider selection)throw new InvalidOperationException("Processing tab has no accessible selection pattern");
            selection.Select();
            if(ProcessingTabs.SelectedIndex!=(int)section||ProcessingPage.Visibility!=Visibility.Visible||string.IsNullOrWhiteSpace(peer.GetName()))throw new InvalidOperationException("Processing section unavailable");
        }
        if(NoiseBox.FontWeight!=FontWeights.Normal||BalanceBox.FontWeight!=FontWeights.Normal)throw new InvalidOperationException("Tab selection changed content typography");
        if(Profiles.Serialize(CurrentProfile())!=before||engine.Metrics().Running!=0)throw new InvalidOperationException("Navigation changed voice settings");
        try{
            MuteKeyBox.SelectedItem=state.MuteKey=="A"?"C":"A";BypassKeyBox.SelectedItem=state.BypassKey=="D"?"E":"D";
            TalkModeBox.SelectedIndex=state.TalkMode==0?1:0;HoldKeyBox.SelectedItem=state.HoldKey=="F"?"G":"F";PresetKeysBox.IsChecked=!state.PresetKeysEnabled;
            var transmission=RequestedShortcuts(true);var application=RequestedShortcuts(false);
            if(transmission.MuteKey!=state.MuteKey||transmission.BypassKey!=state.BypassKey||transmission.PresetKeys!=state.PresetKeysEnabled||
               application.TalkMode!=state.TalkMode||application.HoldKey!=state.HoldKey)throw new InvalidOperationException("Separate settings sections applied each other's pending edits");
        }finally{RestoreShortcutControls();}
    }
}
