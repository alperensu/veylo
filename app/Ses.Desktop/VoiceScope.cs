using System;
using System.Windows;
using System.Windows.Media;

namespace Ses.Desktop;
// A history of measured output RMS, not an invented spectrum or voice recording.
public sealed class VoiceScope : FrameworkElement
{
    private readonly double[] history=new double[56];
    private readonly Brush accent=new SolidColorBrush(Color.FromRgb(185,243,225));
    private readonly Brush faint=new SolidColorBrush(Color.FromArgb(50,185,243,225));
    private readonly Pen baseline=new(new SolidColorBrush(Color.FromArgb(28,232,242,250)),1);
    public VoiceScope(){accent.Freeze();faint.Freeze();baseline.Freeze();}
    internal void Push(float db){
        if(!Motion.GetEnabled(this)||!IsVisible)return;
        Array.Copy(history,1,history,0,history.Length-1);history[^1]=Math.Clamp((db+60)/60d,0,1);InvalidateVisual();
    }
    protected override void OnRender(DrawingContext context){
        base.OnRender(context);double width=ActualWidth,height=ActualHeight,center=height/2;
        context.DrawLine(baseline,new Point(0,center),new Point(width,center));
        bool live=Motion.GetEnabled(this);
        double cell=width/history.Length;
        for(int i=0;i<history.Length;i++){
            double amplitude=live?history[i]:0;
            double bar=3+amplitude*(height-8);var rect=new Rect(i*cell+1,center-bar/2,Math.Max(1,cell-3),bar);
            context.DrawRoundedRectangle(amplitude>.02?accent:faint,null,rect,2,2);
        }
    }
    internal void Clear(){Array.Clear(history);InvalidateVisual();}
}
