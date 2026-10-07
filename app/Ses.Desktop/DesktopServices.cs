using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace Ses.Desktop;
internal sealed class DesktopServices : IDisposable
{
    private readonly Window window;
    private readonly Forms.NotifyIcon tray;
    private readonly HwndSource source;
    private readonly Action mute,bypass;
    private readonly IntPtr hwnd;
    [DllImport("user32.dll",SetLastError=true)]private static extern bool RegisterHotKey(IntPtr hwnd,int id,uint modifiers,uint key);
    [DllImport("user32.dll")]private static extern bool UnregisterHotKey(IntPtr hwnd,int id);
    [DllImport("dwmapi.dll")]private static extern int DwmSetWindowAttribute(IntPtr hwnd,int attribute,ref int value,int size);
    public DesktopServices(Window window,Action mute,Action bypass,Action exit)
    {
        this.window=window;this.mute=mute;this.bypass=bypass;hwnd=new WindowInteropHelper(window).Handle;
        source=HwndSource.FromHwnd(hwnd);source.AddHook(Hook);int dark=1;DwmSetWindowAttribute(hwnd,20,ref dark,sizeof(int));
        tray=new Forms.NotifyIcon {Text="SES",Visible=true};
        string icon=Path.Combine(AppContext.BaseDirectory,"ses.ico");tray.Icon=File.Exists(icon)?new System.Drawing.Icon(icon):(System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        tray.DoubleClick+=(_,_)=>window.Dispatcher.Invoke(Show);
        var menu=new Forms.ContextMenuStrip();
        menu.Items.Add(MainWindow.T("show"),null,(_,_)=>window.Dispatcher.Invoke(Show));
        menu.Items.Add(MainWindow.T("mute"),null,(_,_)=>window.Dispatcher.Invoke(mute));
        menu.Items.Add(MainWindow.T("bypass"),null,(_,_)=>window.Dispatcher.Invoke(bypass));
        menu.Items.Add(new Forms.ToolStripSeparator());menu.Items.Add(MainWindow.T("exit"),null,(_,_)=>window.Dispatcher.Invoke(exit));tray.ContextMenuStrip=menu;
    }
    private IntPtr Hook(IntPtr h,int message,IntPtr w,IntPtr l,ref bool handled)
    {
        if(message==0x0312){if(w.ToInt32()==1)mute();else if(w.ToInt32()==2)bypass();handled=true;}return IntPtr.Zero;
    }
    public bool Keys(string m,string b)
    {
        UnregisterHotKey(hwnd,1);UnregisterHotKey(hwnd,2);
        if(!Ses.Core.UserStore.ValidKey(m)||!Ses.Core.UserStore.ValidKey(b)||m==b)return false;
        bool a=RegisterHotKey(hwnd,1,0x4003,m[0]);bool c=RegisterHotKey(hwnd,2,0x4003,b[0]);return a&&c;
    }
    public void Show(){window.Show();window.WindowState=WindowState.Normal;window.Activate();}
    public void Translate()
    {
        var items=tray.ContextMenuStrip!.Items;
        items[0].Text=MainWindow.T("show");items[1].Text=MainWindow.T("mute");items[2].Text=MainWindow.T("bypass");items[4].Text=MainWindow.T("exit");
    }
    public void Notice(){tray.ShowBalloonTip(2500,"SES",MainWindow.T("trayHint"),Forms.ToolTipIcon.Info);}
    public static bool StartsWithWindows()
    {
        using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");return key?.GetValue("SES") is string;
    }
    public static void Startup(bool enabled)
    {
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(enabled){string path=Environment.ProcessPath??throw new IOException("Cannot determine executable path.");key.SetValue("SES","\""+path+"\" --minimized");}else key.DeleteValue("SES",false);
    }
    public void Dispose(){UnregisterHotKey(hwnd,1);UnregisterHotKey(hwnd,2);source.RemoveHook(Hook);tray.Visible=false;tray.Icon?.Dispose();tray.ContextMenuStrip?.Dispose();tray.Dispose();}
}
