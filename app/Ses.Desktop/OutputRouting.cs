using System;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Ses.Core;

namespace Ses.Desktop;

public partial class MainWindow
{
    private AudioDevice[] outputDevices=[];
    private AudioDevice[] captureDevices=[];
    private bool refreshingRoute;
    private OutputRoute SelectedRoute=>(OutputBox.SelectedItem as OutputRoute)??new("local","",T("localDestination"));

    private void RebuildOutputs()
    {
        bool previous=suppress;suppress=true;
        var routes=OutputRouting.Choices(outputDevices,state.OutputId,T("cableMissingDestination"),T("driverDestination"),T("localDestination"));
        OutputBox.ItemsSource=routes;
        OutputBox.SelectedItem=OutputRouting.Choose(routes,state.OutputMode,state.OutputId);
        if(SelectedRoute is {Mode:"cable",Available:true} cable)state.OutputId=cable.Id;
        suppress=previous;
    }

    private void StartSelectedRoute(string inputId,OutputRoute route)
    {
        var input=captureDevices.FirstOrDefault(d=>d.Id==inputId);
        if(!OutputRouting.CanUseInput(input,route))throw new AudioDeviceException(input is null?-7:-6,"Wait for the saved physical microphone or select an available microphone.");
        if(OfflineSmoke)return;
        engine.Start(inputId,OutputRouting.EffectiveKind(route)==2?route.Id:null,route.Mode=="driver");
    }

    private async void OutputChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready||suppress||busy||sampling||quitting||OutputBox.SelectedItem is not OutputRoute route)return;
        state.OutputMode=route.Mode;
        if(route.Mode=="cable")state.OutputId=route.Id;
        await RestartRoute();
    }

    private async Task RestartRoute()
    {
        if(quitting||busy||sampling)return;
        string inputId=(InputBox.SelectedItem as AudioDevice)?.Id??state.InputId;
        if(inputId.Length==0){ScheduleSave();RouteText();return;}
        var route=SelectedRoute;SetBusy(true);
        try{ApplySettings();await EngineOperation(()=>{engine.Stop();StartSelectedRoute(inputId,route);});if(!quitting){SessionStatus();ScheduleSave();}}
        catch(AudioDeviceException ex){Status(ex.Code==-4?"permissionError":ex.Code==-6?"feedbackInput":ex.Code==-7?"disconnected":"deviceOpenError");}
        finally{SetBusy(false);RouteText();}
    }

    private async Task ReconnectMissingCable()
    {
        if(quitting)return;
        var metrics=engine.Metrics();
        if(refreshingRoute||busy||sampling||!OutputRouting.NeedsRefresh(SelectedRoute,metrics.OutputKind,metrics.Connected))return;
        refreshingRoute=true;SetBusy(true);
        try{await RefreshDevices();}finally{SetBusy(false);refreshingRoute=false;}
        // Compare the selected destination with the actual stream on every poll.
        // A deferred restart remains pending even after enumeration finds the cable.
        if(!quitting&&engine.Metrics().OutputKind!=OutputRouting.EffectiveKind(SelectedRoute))await RestartRoute();
    }

    private async Task RunRoutingSmoke(string directory)
    {
        var original=SelectedRoute;
        string before=Profiles.Serialize(CurrentProfile());
        // Exercise the actual selection event, not only the pure routing policy.
        foreach(string mode in new[]{"local","driver",original.Mode})
        {
            var routes=(OutputRoute[])OutputBox.ItemsSource;
            OutputBox.SelectedItem=OutputRouting.Choose(routes,mode,state.OutputId);
            for(int i=0;i<100&&busy;i++)await Task.Delay(20);
            await StartSession();
            if(busy||engine.Metrics().Running!=0||state.OutputMode!=mode||SelectedRoute.Mode!=mode||Profiles.Serialize(CurrentProfile())!=before)throw new InvalidOperationException("Offline output selection failed, opened a device or changed voice settings");
        }
        string selectedId=SelectedRoute.Id;
        LanguageBox.SelectedIndex=0;Width=1120;Height=820;Navigate(WorkspacePage.Overview);
        if(SelectedRoute.Id!=selectedId)throw new InvalidOperationException("Translation changed output selection");
        await Task.Delay(150);Capture(System.IO.Path.Combine(directory,"cable-routing-tr.png"));
        System.IO.File.WriteAllText(System.IO.Path.Combine(directory,"routing-result.json"),System.Text.Json.JsonSerializer.Serialize(new{success=true,selectedMode=SelectedRoute.Mode,available=SelectedRoute.Available,requestedOutputKind=OutputRouting.EffectiveKind(SelectedRoute),outputKind=engine.Metrics().OutputKind,nativeStreamOpened=false,liveTransportValidated=false,selectionEvents=true,settingsPreserved=true,translationPreserved=true}));
        await EngineOperation(engine.Stop);
    }
}
