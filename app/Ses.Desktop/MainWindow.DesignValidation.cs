using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;

namespace Ses.Desktop;

public partial class MainWindow
{
    // Offline-only layout checks. These do not change Windows display/accessibility settings.
    private async Task RunDesignSmoke(string directory)
    {
        if(!OfflineSmoke)throw new InvalidOperationException("Design validation requires offline mode");
        var quickButtons=((StackPanel)OverviewPresets.Child).Children.OfType<WrapPanel>().Single().Children.OfType<Button>().ToArray();
        int selectedProfile=PresetList.SelectedIndex;
        try{
            SetBusy(true);
            quickButtons[(selectedProfile+1)%quickButtons.Length].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if(OverviewPresets.IsEnabled||PresetList.SelectedIndex!=selectedProfile)throw new InvalidOperationException("Busy session allowed a quick profile change");
            sampling=true;personalCalibrating=true;SetBusy(false);
            if(OverviewPresets.IsEnabled)throw new InvalidOperationException("Calibration left quick presets enabled");
        }finally{sampling=false;personalCalibrating=false;SetBusy(false);}
        int layouts=0;
        foreach(var language in new[]{0,1}){
            LanguageBox.SelectedIndex=language;
            foreach(var size in new[]{(1160,840),(780,650),(640,480)}){
                Width=size.Item1;Height=size.Item2;
                for(int page=0;page<7;page++){
                    NavigationList.SelectedIndex=page;MainScroll.ScrollToTop();await Task.Delay(40);UpdateLayout();
                    if(MainScroll.ScrollableWidth>1||MainScroll.ActualWidth<400||MainScroll.ActualHeight<140)throw new InvalidOperationException("Page viewport became unusable");
                    foreach(var control in new FrameworkElement[]{MuteBox,BypassBox,LanguageBox}){
                        var bounds=control.TransformToAncestor((Visual)Content).TransformBounds(new Rect(control.RenderSize));
                        if(bounds.Left<0||bounds.Right>ActualWidth+1||bounds.Top<0||bounds.Bottom>ActualHeight+1)throw new InvalidOperationException("Persistent control is clipped");
                    }
                    foreach(var item in NavigationList.Items.Cast<ListBoxItem>()){
                        if(string.IsNullOrWhiteSpace(AutomationProperties.GetName(item)))throw new InvalidOperationException("Navigation accessible name is missing");
                        // Short windows virtualize items outside the scroll viewport.
                        if(item.ActualWidth<=0)continue;
                        var icon=((StackPanel)item.Content).Children.OfType<System.Windows.Shapes.Path>().Single();
                        var bounds=icon.TransformToAncestor(item).TransformBounds(new Rect(icon.RenderSize));
                        if(bounds.Right>item.ActualWidth+1||icon.Width<18||icon.ActualWidth<12)throw new InvalidOperationException($"Navigation icon clipped at {size.Item1} page {page}: {AutomationProperties.GetName(item)}, right={bounds.Right}, item={item.ActualWidth}, icon={icon.ActualWidth}");
                    }
                    if(page==0&&(InputBox.ActualWidth<180||OutputBox.ActualWidth<180))throw new InvalidOperationException("Device fields are too narrow");
                    Capture(Path.Combine(directory,$"design-{(language==0?"tr":"en")}-{size.Item1}-page-{page}.png"));layouts++;
                }
            }
        }
        Width=1160;Height=840;LanguageBox.SelectedIndex=0;NavigationList.SelectedIndex=0;MainScroll.ScrollToTop();await Task.Delay(60);
        for(int dpi=96;dpi<=192;dpi+=48)CaptureWindow(this,Path.Combine(directory,$"design-raster-{dpi}dpi.png"),dpi);
        try{
            ThemePalette.Apply(true);Motion.SetEnabled(this,false);UpdateLayout();
            foreach(var key in new[]{"TextBrush","MutedBrush","SidebarTextBrush","AccentInkBrush"}){
                if(Application.Current.TryFindResource(key) is not SolidColorBrush brush||brush.Color!=SystemColors.WindowTextColor)throw new InvalidOperationException("High-contrast text palette failed");
            }
            if(Application.Current.TryFindResource("SidebarSelectedTextBrush") is not SolidColorBrush selected||selected.Color!=SystemColors.HighlightTextColor)throw new InvalidOperationException("High-contrast selection palette failed");
            if(Application.Current.TryFindResource("OptionSelectedBrush") is not SolidColorBrush option||option.Color!=SystemColors.HighlightColor||
                Application.Current.TryFindResource("OptionSelectedTextBrush") is not SolidColorBrush optionText||optionText.Color!=SystemColors.HighlightTextColor)throw new InvalidOperationException("High-contrast dropdown palette failed");
            Capture(Path.Combine(directory,"design-system-palette.png"));
        }finally{ThemePalette.Apply(SystemParameters.HighContrast);ApplyVisualPolicy();}
        if(engine.Metrics().Running!=0)throw new InvalidOperationException("Design validation opened audio");
        File.WriteAllText(Path.Combine(directory,"design-result.json"),System.Text.Json.JsonSerializer.Serialize(new{
            success=true,layouts,languages=new[]{"tr","en"},sizes=new[]{"1160x840","780x650","640x480"},persistentControlsVisible=true,
            navigationIconsUnclipped=true,accessibleNavigationNames=true,systemPaletteMapping=true,quickPresetBusyGuard=true,rasterDpi=new[]{96,144,192},
            physicalDpiValidated=false,narratorValidated=false,liveAudioValidated=false
        }));
    }
}
