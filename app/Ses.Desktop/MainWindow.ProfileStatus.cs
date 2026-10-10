using System;
using System.Linq;
using System.Text.Json;
using System.Windows;
using Ses.Core;

namespace Ses.Desktop;

public partial class MainWindow
{
    private bool CanChangeProfile => ready&&!suppress&&!busy&&!calibrating&&!sampling&&!personalCalibrating&&!finishing&&!quitting;

    private void RefreshProfileStatus()
    {
        if(ModifiedLabel is null||PresetList is null)return;
        var selected=PresetList.SelectedItem as ProfileChoice;
        // Compare the actual settings, including controls without a quick slider.
        // Transmission controls are separate and never make a profile custom.
        bool changed=true;
        try{changed=selected is null||JsonSerializer.Serialize(settings)!=JsonSerializer.Serialize(selected.Profile.Settings);}
        catch(ArgumentException){/* A pending invalid numeric edit is custom until validation restores it. */}
        ModifiedLabel.Text=changed?T("custom"):"";
        if(selected is not null)ActiveProfileText.Text=T("activeProfile")+" · "+selected.Name;
        ReapplyProfileButton.IsEnabled=selected is not null&&CanChangeProfile;
        BypassNotice.Visibility=BypassBox.IsChecked==true?Visibility.Visible:Visibility.Collapsed;
        ResizeProfileNotice();
        ResumeProcessingButton.IsEnabled=ready&&!quitting;
        CurrentToneText.Text=T("currentTone")+" · "+T("highpass")+$": {settings.HighpassHz:0.#} Hz · EQ: "+
            string.Join(" / ",settings.Bands.Select(b=>$"{b.GainDb:+0.#;-0.#;0} dB"));
    }

    private void ResizeProfileNotice()
    {
        // Keep the warning and return action visible without taking away the
        // working viewport in a short window. Section copy remains in the page.
        bool compact=BypassBox?.IsChecked==true&&ActualHeight>0&&ActualHeight<600;
        if(PageDescription is not null)PageDescription.Visibility=compact?Visibility.Collapsed:Visibility.Visible;
        if(PageHeading is not null)PageHeading.Margin=new Thickness(0,0,0,compact?8:22);
    }

    private void ApplySelectedProfile(ProfileChoice choice)
    {
        settings=choice.Profile.Settings.Clone();
        LoadControls();
        ProfileNameBox.Text=choice.Profile.FactoryId is null?choice.Name:(state.Language=="en"?"My voice":"Benim sesim");
        if(TryApplySettings())state.ActiveProfile=ProfileKey(choice.Profile);
    }

    private void ReapplyProfileClick(object sender,RoutedEventArgs e)
    {
        if(!CanChangeProfile||PresetList.SelectedItem is not ProfileChoice choice)return;
        // Deliberately keep mute/bypass and the selected audio route unchanged.
        ApplySelectedProfile(choice);
    }

    private void ResumeProcessingClick(object sender,RoutedEventArgs e)
    {
        if(!ready||quitting||suppress)return;
        BypassBox.IsChecked=false;
    }
}
