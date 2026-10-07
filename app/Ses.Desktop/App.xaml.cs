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
        bool smoke=e.Args.Contains("--smoke")||e.Args.Contains("--validate-live");
        if(!smoke){instance=new Mutex(true,"Local\\SES-Desktop-"+Environment.UserName,out bool created);if(!created){MessageBox.Show("SES zaten açık / SES is already running.","SES");Shutdown();return;}}
        try{var window=new MainWindow(smoke,e.Args);MainWindow=window;if(smoke){window.ShowInTaskbar=false;window.Left=-4000;window.Top=-4000;window.WindowStartupLocation=WindowStartupLocation.Manual;}window.Show();}
        catch(Exception ex){if(smoke){Console.Error.WriteLine(ex);Shutdown(1);}else{MessageBox.Show("SES başlatılamadı. Paketi tüm dosyalarıyla yeniden çıkarmayı deneyin.\nSES could not start. Extract the complete package and try again.","SES");Shutdown(1);}}
    }
    protected override void OnExit(ExitEventArgs e){instance?.Dispose();base.OnExit(e);}
}
