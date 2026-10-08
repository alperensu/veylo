using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Win32;
using Ses.Core;
using System.Threading;
using Forms = System.Windows.Forms;

namespace Ses.Desktop;
internal sealed class DesktopServices : IDisposable
{
    private readonly Window window;
    private readonly Forms.NotifyIcon tray;
    private readonly HwndSource source;
    private readonly Action mute,bypass;
    private readonly IntPtr hwnd;
    private readonly HotkeyRegistry keys;
    private readonly Action<string> preset;
    private readonly Action<int,bool> gate;
    private readonly object gateLock=new();
    private readonly Timer holdTimer;
    private ShortcutSettings shortcuts=new();
    private bool disposed;
    private int held;
    public bool TalkHeld=>Volatile.Read(ref held)!=0;
    [DllImport("user32.dll",SetLastError=true)]private static extern bool RegisterHotKey(IntPtr hwnd,int id,uint modifiers,uint key);
    [DllImport("user32.dll")]private static extern bool UnregisterHotKey(IntPtr hwnd,int id);
    [DllImport("user32.dll")]private static extern short GetAsyncKeyState(int key);
    [DllImport("dwmapi.dll")]private static extern int DwmSetWindowAttribute(IntPtr hwnd,int attribute,ref int value,int size);
    public DesktopServices(Window window,Action mute,Action bypass,Action exit,Action<string> preset,Action<int,bool> gate)
    {
        this.window=window;this.mute=mute;this.bypass=bypass;this.preset=preset;this.gate=gate;hwnd=new WindowInteropHelper(window).Handle;
        keys=new((id,key)=>RegisterHotKey(hwnd,id,0x4003,(uint)key),id=>UnregisterHotKey(hwnd,id));
        holdTimer=new Timer(_=>PollHold(),null,Timeout.Infinite,Timeout.Infinite);
        source=HwndSource.FromHwnd(hwnd);source.AddHook(Hook);int dark=1;DwmSetWindowAttribute(hwnd,20,ref dark,sizeof(int));
        tray=new Forms.NotifyIcon {Text="Veylo",Visible=true};
        string icon=Path.Combine(AppContext.BaseDirectory,"veylo.ico");tray.Icon=File.Exists(icon)?new System.Drawing.Icon(icon):(System.Drawing.Icon)System.Drawing.SystemIcons.Application.Clone();
        tray.DoubleClick+=(_,_)=>window.Dispatcher.Invoke(Show);
        var menu=new Forms.ContextMenuStrip();
        menu.Items.Add(MainWindow.T("show"),null,(_,_)=>window.Dispatcher.Invoke(Show));
        menu.Items.Add(MainWindow.T("mute"),null,(_,_)=>window.Dispatcher.Invoke(mute));
        menu.Items.Add(MainWindow.T("bypass"),null,(_,_)=>window.Dispatcher.Invoke(bypass));
        menu.Items.Add(new Forms.ToolStripSeparator());menu.Items.Add(MainWindow.T("exit"),null,(_,_)=>window.Dispatcher.Invoke(exit));tray.ContextMenuStrip=menu;
    }
    private IntPtr Hook(IntPtr h,int message,IntPtr w,IntPtr l,ref bool handled)
    {
        if(message==0x0312&&keys.ActionFor(w.ToInt32()) is string action){if(action=="mute")mute();else if(action=="bypass")bypass();else if(action!="hold")preset(action);handled=true;}return IntPtr.Zero;
    }
    public bool Configure(ShortcutSettings wanted)
    {
        wanted.Validate();if(!keys.Apply(wanted))return false;
        lock(gateLock){shortcuts=wanted;Volatile.Write(ref held,0);gate(wanted.TalkMode,false);holdTimer.Change(wanted.TalkMode==0?Timeout.Infinite:0,wanted.TalkMode==0?Timeout.Infinite:20);}
        return true;
    }
    private void PollHold()
    {
        lock(gateLock)
        {
            if(disposed||shortcuts.TalkMode==0)return;
            // Only configured chord state is sampled. No hooks, key history or keyboard log.
            bool down=(GetAsyncKeyState(0x11)&0x8000)!=0&&(GetAsyncKeyState(0x12)&0x8000)!=0&&(GetAsyncKeyState(shortcuts.HoldKey[0])&0x8000)!=0;
            Volatile.Write(ref held,down?1:0);gate(shortcuts.TalkMode,down);
        }
    }
    public void Show(){window.Show();window.WindowState=WindowState.Normal;window.Activate();}
    public void Translate()
    {
        var items=tray.ContextMenuStrip!.Items;
        items[0].Text=MainWindow.T("show");items[1].Text=MainWindow.T("mute");items[2].Text=MainWindow.T("bypass");items[4].Text=MainWindow.T("exit");
    }
    public void Notice(){tray.ShowBalloonTip(2500,"Veylo",MainWindow.T("trayHint"),Forms.ToolTipIcon.Info);}
    public static bool StartsWithWindows()
    {
        // Preserve the existing opt-in preference; only its executable target changes.
        using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");return key?.GetValue("SES") is string;
    }
    public static bool RefreshStartupRegistration()
    {
        const string run=@"Software\Microsoft\Windows\CurrentVersion\Run";
        try{
            using var read=Registry.CurrentUser.OpenSubKey(run);
            if(read?.GetValue("SES",null,RegistryValueOptions.DoNotExpandEnvironmentNames) is not string saved||read.GetValueKind("SES")!=RegistryValueKind.String||
                !StartupRegistration.TryGetTarget(saved,out string target)||Environment.ProcessPath is not string current)return false;
            static Version? FileVersion(string path){
                if(!File.Exists(path))return null;
                var info=FileVersionInfo.GetVersionInfo(path);
                return string.IsNullOrEmpty(info.FileVersion)?null:new Version(info.FileMajorPart,info.FileMinorPart,info.FileBuildPart,info.FilePrivatePart);
            }
            string? upgraded=StartupRegistration.TryUpgrade(saved,current,FileVersion(target),FileVersion(current));
            if(upgraded is null)return false;
            using var write=Registry.CurrentUser.OpenSubKey(run,writable:true);
            // Do not recreate a disabled entry or overwrite an intervening edit.
            if(write?.GetValue("SES",null,RegistryValueOptions.DoNotExpandEnvironmentNames) is not string latest||latest!=saved||write.GetValueKind("SES")!=RegistryValueKind.String)return false;
            write.SetValue("SES",upgraded,RegistryValueKind.String);return true;
        }
        catch(Exception ex)when(ex is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException or System.ComponentModel.Win32Exception){return false;}
    }
    public static void Startup(bool enabled)
    {
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if(enabled){string path=Environment.ProcessPath??throw new IOException("Cannot determine executable path.");key.SetValue("SES","\""+path+"\" --minimized");}else key.DeleteValue("SES",false);
    }
    public void Dispose(){lock(gateLock){disposed=true;holdTimer.Change(Timeout.Infinite,Timeout.Infinite);}holdTimer.Dispose();keys.Dispose();source.RemoveHook(Hook);tray.Visible=false;tray.Icon?.Dispose();tray.ContextMenuStrip?.Dispose();tray.Dispose();}
}
