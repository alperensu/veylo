using System;
using System.Windows;
using System.Windows.Media;

namespace Ses.Desktop;

// A history of measured output RMS, not an invented spectrum or voice recording.
public sealed class VoiceScope : FrameworkElement
{
    private readonly double[] history=new double[56];
    private int sampleCount;
    internal void Push(float db){
        if(!Motion.GetEnabled(this)||!IsVisible)return;
        Array.Copy(history,1,history,0,history.Length-1);
        history[^1]=float.IsFinite(db)?Math.Clamp((db+60)/60d,0,1):0;
        sampleCount=Math.Min(sampleCount+1,history.Length);
        InvalidateVisual();
    }
    protected override void OnRender(DrawingContext context){
        base.OnRender(context);
        double width=ActualWidth,height=ActualHeight;
        if(width<=0||height<=0)return;
        var accent=TryFindResource("AccentBrush") as Brush??SystemColors.HighlightBrush;
        var gridBrush=TryFindResource("BorderBrush") as Brush??SystemColors.GrayTextBrush;
        var gridPen=new Pen(gridBrush,1);
        double top=3,bottom=Math.Max(top,height-3),range=bottom-top;
        for(int i=0;i<3;i++){
            double y=bottom-i*range/2;
            context.DrawLine(gridPen,new Point(0,y),new Point(width,y));
        }
        if(!Motion.GetEnabled(this)||sampleCount==0)return;
        var trace=new StreamGeometry();
        int first=history.Length-sampleCount;
        using(var drawing=trace.Open()){
            drawing.BeginFigure(new Point(first*width/(history.Length-1),bottom-history[first]*range),false,false);
            for(int i=first+1;i<history.Length;i++)drawing.LineTo(new Point(i*width/(history.Length-1),bottom-history[i]*range),true,false);
        }
        trace.Freeze();
        context.DrawGeometry(null,new Pen(accent,2){StartLineCap=PenLineCap.Round,EndLineCap=PenLineCap.Round,LineJoin=PenLineJoin.Round},trace);
    }
    internal void Clear(){Array.Clear(history);sampleCount=0;InvalidateVisual();}
}
