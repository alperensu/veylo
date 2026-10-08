using System;
using System.Windows;
using System.Windows.Input;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Ses.Desktop;
public static class Motion
{
    public static readonly DependencyProperty EnabledProperty=DependencyProperty.RegisterAttached("Enabled",typeof(bool),typeof(Motion),new FrameworkPropertyMetadata(true,FrameworkPropertyMetadataOptions.Inherits,Changed));
    public static bool GetEnabled(DependencyObject d)=>(bool)d.GetValue(EnabledProperty);
    public static void SetEnabled(DependencyObject d,bool value)=>d.SetValue(EnabledProperty,value);
    public static readonly DependencyProperty InteractiveProperty=DependencyProperty.RegisterAttached("Interactive",typeof(bool),typeof(Motion),new PropertyMetadata(false,Attach));
    public static bool GetInteractive(DependencyObject d)=>(bool)d.GetValue(InteractiveProperty);
    public static void SetInteractive(DependencyObject d,bool value)=>d.SetValue(InteractiveProperty,value);
    private static void Attach(DependencyObject d,DependencyPropertyChangedEventArgs e){
        if(d is not FrameworkElement element)return;
        if((bool)e.NewValue){element.MouseEnter+=Enter;element.MouseLeave+=Leave;element.PreviewMouseLeftButtonDown+=Press;element.PreviewMouseLeftButtonUp+=Release;element.Unloaded+=Unload;if(element is CheckBox check){check.Checked+=ToggleChanged;check.Unchecked+=ToggleChanged;}}
        else{element.MouseEnter-=Enter;element.MouseLeave-=Leave;element.PreviewMouseLeftButtonDown-=Press;element.PreviewMouseLeftButtonUp-=Release;element.Unloaded-=Unload;if(element is CheckBox check){check.Checked-=ToggleChanged;check.Unchecked-=ToggleChanged;}Reset(element);}
    }
    private static void Changed(DependencyObject d,DependencyPropertyChangedEventArgs e){if(!(bool)e.NewValue&&d is FrameworkElement element)Reset(element);}
    private static void Enter(object sender,MouseEventArgs e)=>Scale((FrameworkElement)sender,1.025);
    private static void Leave(object sender,MouseEventArgs e)=>Scale((FrameworkElement)sender,1);
    private static void Press(object sender,MouseButtonEventArgs e)=>Scale((FrameworkElement)sender,.97);
    private static void Release(object sender,MouseButtonEventArgs e)=>Scale((FrameworkElement)sender,((FrameworkElement)sender).IsMouseOver?1.025:1);
    private static void Unload(object sender,RoutedEventArgs e)=>Reset((FrameworkElement)sender);
    private static void Scale(FrameworkElement element,double value){
        if(element is CheckBox||!GetEnabled(element)||!element.IsVisible)return;
        if(element.RenderTransform is not ScaleTransform transform){transform=new ScaleTransform(1,1);element.RenderTransform=transform;element.RenderTransformOrigin=new Point(.5,.5);}
        var animation=new DoubleAnimation(transform.ScaleX,value,TimeSpan.FromMilliseconds(180)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut},FillBehavior=FillBehavior.Stop};
        transform.ScaleX=value;transform.ScaleY=value;transform.BeginAnimation(ScaleTransform.ScaleXProperty,animation);transform.BeginAnimation(ScaleTransform.ScaleYProperty,animation);
    }
    private static void ToggleChanged(object sender,RoutedEventArgs e){
        var check=(CheckBox)sender;if(!check.IsLoaded||check.Template.FindName("Knob",check) is not FrameworkElement knob)return;
        var transform=knob.RenderTransform as TranslateTransform;
        if(transform is null)return;double from=transform.X,to=check.IsChecked==true?16:0;
        if(transform.IsFrozen){transform=transform.CloneCurrentValue();knob.RenderTransform=transform;}
        transform.BeginAnimation(TranslateTransform.XProperty,null);transform.X=to;
        if(GetEnabled(check))transform.BeginAnimation(TranslateTransform.XProperty,new DoubleAnimation(from,to,TimeSpan.FromMilliseconds(180)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut},FillBehavior=FillBehavior.Stop});
    }
    internal static void Reveal(FrameworkElement element){
        Reset(element);if(!GetEnabled(element))return;
        var transform=new TranslateTransform();element.RenderTransform=transform;
        transform.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(12,0,TimeSpan.FromMilliseconds(300)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut},FillBehavior=FillBehavior.Stop});
        element.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(.45,1,TimeSpan.FromMilliseconds(220)){FillBehavior=FillBehavior.Stop});
    }
    internal static void Reset(FrameworkElement element){
        element.BeginAnimation(UIElement.OpacityProperty,null);
        if(element.RenderTransform is ScaleTransform scale&&!scale.IsFrozen){scale.BeginAnimation(ScaleTransform.ScaleXProperty,null);scale.BeginAnimation(ScaleTransform.ScaleYProperty,null);scale.ScaleX=scale.ScaleY=1;}
        if(element.RenderTransform is TranslateTransform translate&&!translate.IsFrozen){translate.BeginAnimation(TranslateTransform.XProperty,null);translate.BeginAnimation(TranslateTransform.YProperty,null);translate.Y=0;}
    }
}
