using System;
using System.Linq;
using System.Threading;
using System.Windows;

namespace Ses.Desktop;
public partial class App : Application
{
    private Mutex? instance;
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        bool smoke=e.Args.Contains("--smoke")||e.Args.Contains("--validate-live")||e.Args.Contains("--validate-low-overhead");
        if(e.Args.Contains("--repair-startup")){
            if(smoke){Console.Error.WriteLine("Startup repair cannot be combined with validation.");Shutdown(1);return;}
            Console.WriteLine(DesktopServices.RefreshStartupRegistration()?"Veylo startup target refreshed.":"Veylo startup target unchanged.");Shutdown();return;
        }
        // The legacy mutex prevents a second normal session alongside an older SES build.
        if(!smoke){DesktopServices.RefreshStartupRegistration();instance=new Mutex(true,"Local\\SES-Desktop-"+Environment.UserName,out bool created);if(!created){MessageBox.Show("Veylo zaten açık / Veylo is already running.","Veylo");Shutdown();return;}}
        try{var window=new MainWindow(smoke,e.Args);MainWindow=window;if(e.Args.Contains("--minimized")){window.Opacity=0;window.ShowInTaskbar=false;}if(smoke){window.ShowInTaskbar=false;window.Left=-4000;window.Top=-4000;window.WindowStartupLocation=WindowStartupLocation.Manual;}window.Show();}
        catch(Exception ex){if(smoke){Console.Error.WriteLine(ex);Shutdown(1);}else{MessageBox.Show("Veylo başlatılamadı. Paketi tüm dosyalarıyla yeniden çıkarmayı deneyin.\nVeylo could not start. Extract the complete package and try again.","Veylo");Shutdown(1);}}
    }
    protected override void OnExit(ExitEventArgs e){instance?.Dispose();base.OnExit(e);}
}
