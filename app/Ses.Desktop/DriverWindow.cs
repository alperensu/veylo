using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Ses.Core;

namespace Ses.Desktop;
internal sealed class DriverWindow : Window
{
    private readonly bool english;
    private readonly TextBlock status=new(){TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,12,0,18)};
    private readonly WrapPanel actions=new();
    private readonly string helper=Path.Combine(AppContext.BaseDirectory,"Veylo.DriverSetup.exe");
    private bool busy;
    internal bool InstallationAvailable=>((Button)actions.Children[0]).IsEnabled;
    internal DriverWindow(string language)
    {
        english=language=="en";Title=english?"Veylo microphone driver":"Veylo mikrofon sürücüsü";Width=580;Height=440;MinWidth=400;MinHeight=360;WindowStartupLocation=WindowStartupLocation.CenterOwner;
        Background=(Brush)Application.Current.FindResource("BackgroundBrush");Foreground=(Brush)Application.Current.FindResource("TextBrush");FontFamily=new FontFamily("Segoe UI");FontSize=14;
        var panel=new StackPanel{Margin=new Thickness(24)};
        panel.Children.Add(new TextBlock{Text="Veylo Mikrofon",FontSize=24,FontWeight=FontWeights.SemiBold});
        panel.Children.Add(new TextBlock{Text=english?"Capture-only · No continuous audio sent to speakers":"Yalnızca kayıt cihazı · Hoparlörlere sürekli ses göndermez",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,8,0,0)});
        panel.Children.Add(status);panel.Children.Add(actions);
        Add(english?"Install / update":"Kur / güncelle","install");Add(english?"Roll back":"Geri al","rollback");Add(english?"Remove":"Kaldır","remove");
        var links=new WrapPanel{Margin=new Thickness(0,20,0,0)};
        var guide=new Button{Content=english?"Setup guide":"Kurulum rehberi",Margin=new Thickness(0,0,8,8)};
        guide.Click+=(_,_)=>OpenGuide();links.Children.Add(guide);
        var permission=new Button{Content=english?"Microphone permission":"Mikrofon izni",Margin=new Thickness(0,0,8,8)};
        permission.Click+=(_,_)=>Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone"){UseShellExecute=true});links.Children.Add(permission);panel.Children.Add(links);
        panel.Children.Add(new TextBlock{Text=english?"Installation requires administrator permission. Daily Veylo use does not. Production signing and isolated Windows lab validation are required before a daily-use driver release.":"Kurulum yönetici izni ister; günlük Veylo kullanımı istemez. Günlük sürücü teslimatı için Microsoft imzası ve ayrı Windows ortamında doğrulama gerekir.",TextWrapping=TextWrapping.Wrap,FontSize=12,Margin=new Thickness(0,8,0,0)});
        Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};Loaded+=async(_,_)=>await Refresh();Closing+=(_,e)=>{if(busy)e.Cancel=true;};
    }
    private void Add(string label,string action){var button=new Button{Content=label,Margin=new Thickness(0,0,8,0)};button.Click+=async(_,_)=>await Manage(action);actions.Children.Add(button);}
    private void OpenGuide(){string path=Path.Combine(AppContext.BaseDirectory,"docs","DRIVER.md");if(File.Exists(path))Process.Start(new ProcessStartInfo(path){UseShellExecute=true});else Process.Start(new ProcessStartInfo("https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings"){UseShellExecute=true});}
    private async Task Refresh()
    {
        bool installed=false;
        try{if(File.Exists(helper)){
            using var process=Process.Start(new ProcessStartInfo(helper,"status"){UseShellExecute=false,CreateNoWindow=true,RedirectStandardOutput=true,RedirectStandardError=true});
            if(process is not null){string output=await process.StandardOutput.ReadToEndAsync();await process.WaitForExitAsync();installed=process.ExitCode==0&&output.Trim()=="installed";}
        }}catch(Exception ex)when(ex is Win32Exception or IOException or InvalidOperationException){status.Text=english?"Cannot inspect the Veylo driver. Extract the complete package and try again.":"Veylo sürücü durumu okunamadı. Paketi tüm dosyalarıyla yeniden çıkart.";actions.IsEnabled=false;return;}
        bool packaged=File.Exists(Path.Combine(AppContext.BaseDirectory,"driver","SesMicrophone.cat"));
        status.Text=installed?(english?"Veylo device is installed. The main screen shows whether its producer connection is active.":"Veylo cihazı kurulu. Üretici bağlantısının açık olup olmadığı ana ekranda gösterilir."):
            english?"Veylo driver is not installed. Select CABLE Input in the main window to use VB-CABLE. The Veylo Mikrofon route remains unavailable.":"Veylo sürücüsü kurulu değil. VB-CABLE kullanmak için ana pencerede CABLE Input seç. Veylo Mikrofon çıkışı henüz kullanılamaz.";
        if(!packaged)status.Text+="\n\n"+(english?"This development package has no production-signed driver. See the guide for signing and lab requirements.":"Bu geliştirme paketinde üretim imzalı sürücü yok. İmzalama ve laboratuvar gereksinimleri rehberde yer alır.");
        ((Button)actions.Children[0]).IsEnabled=File.Exists(helper)&&packaged;
        ((Button)actions.Children[1]).IsEnabled=((Button)actions.Children[2]).IsEnabled=File.Exists(helper)&&installed;
    }
    private async Task Manage(string action)
    {
        busy=true;actions.IsEnabled=false;status.Text=english?"Waiting for Windows driver setup…":"Windows sürücü işlemi bekleniyor…";
        try{
            using var process=Process.Start(new ProcessStartInfo(helper,action){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden})??throw new IOException("Installer did not start.");await process.WaitForExitAsync();
            await Refresh();status.Text+="\n\n"+(process.ExitCode==0?(english?"Operation completed.":"İşlem tamamlandı."):process.ExitCode==3010?(english?"Restart Windows to complete this operation.":"İşlemi tamamlamak için Windows’u yeniden başlat."):process.ExitCode==1223?(english?"Administrator permission was cancelled.":"Yönetici izni iptal edildi."):(english?"Operation failed. Check the signed package and Windows device status; see the guide.":"İşlem başarısız. İmzalı paketi ve Windows cihaz durumunu kontrol et; rehberi aç."));
        }catch(Win32Exception ex)when(ex.NativeErrorCode==1223){status.Text=english?"Administrator permission was cancelled.":"Yönetici izni iptal edildi.";}
        catch(Exception ex)when(ex is IOException or Win32Exception){status.Text=english?"Cannot run driver setup. Extract the complete package and try again.":"Sürücü yardımcısı çalıştırılamadı. Paketi tüm dosyalarıyla yeniden çıkart.";}
        finally{busy=false;actions.IsEnabled=true;}
    }
}
