using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

namespace Ses.Desktop;

// Override at application scope so modeless dialogs and popup templates use the same palette.
internal static class ThemePalette
{
    private static readonly Dictionary<string,Brush> normal=new();
    private static bool highContrastApplied;

    internal static void Apply(bool highContrast){
        var application=Application.Current;
        if(application is null)return;
        var system=new Dictionary<string,Brush>{
            ["BackgroundBrush"]=SystemColors.WindowBrush,
            ["SurfaceBrush"]=SystemColors.WindowBrush,
            ["GlassChromeBrush"]=SystemColors.WindowBrush,
            ["CardSecondaryBrush"]=SystemColors.WindowBrush,
            ["ControlBrush"]=SystemColors.WindowBrush,
            ["BorderBrush"]=SystemColors.WindowTextBrush,
            ["GlassEdge"]=SystemColors.WindowTextBrush,
            ["ControlBorderBrush"]=SystemColors.WindowTextBrush,
            ["HoverBorderBrush"]=SystemColors.HighlightBrush,
            ["TextBrush"]=SystemColors.WindowTextBrush,
            ["MutedBrush"]=SystemColors.WindowTextBrush,
            ["AccentBrush"]=SystemColors.HighlightBrush,
            ["AccentTextBrush"]=SystemColors.HighlightTextBrush,
            ["AccentInkBrush"]=SystemColors.WindowTextBrush,
            ["AccentWashBrush"]=SystemColors.WindowBrush,
            ["OptionSelectedBrush"]=SystemColors.HighlightBrush,
            ["OptionSelectedTextBrush"]=SystemColors.HighlightTextBrush,
            ["FocusBrush"]=SystemColors.WindowTextBrush,
            ["TrackBrush"]=SystemColors.GrayTextBrush,
            ["SidebarBrush"]=SystemColors.WindowBrush,
            ["SidebarTextBrush"]=SystemColors.WindowTextBrush,
            ["SidebarMutedBrush"]=SystemColors.WindowTextBrush,
            ["SidebarHoverBrush"]=SystemColors.WindowBrush,
            ["SidebarSelectedBrush"]=SystemColors.HighlightBrush,
            ["SidebarSelectedTextBrush"]=SystemColors.HighlightTextBrush
        };
        if(normal.Count==0){
            foreach(var key in system.Keys)if(application.TryFindResource(key) is Brush brush)normal.Add(key,brush);
        }
        if(!highContrast&&!highContrastApplied)return;
        foreach(var item in highContrast?system:normal)application.Resources[item.Key]=item.Value;
        highContrastApplied=highContrast;
    }
}
