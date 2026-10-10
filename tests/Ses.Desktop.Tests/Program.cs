using System.Reflection;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Automation.Peers;
using Ses.Core;
using Ses.Desktop;
using Application = System.Windows.Application;
using TextBox = System.Windows.Controls.TextBox;

internal static class Program
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;
    private static FieldInfo Field(string name) => typeof(MainWindow).GetField(name, Private) ?? throw new MissingFieldException(name);
    private static T Read<T>(MainWindow window, string name) => (T)Field(name).GetValue(window)!;
    private static object? Call(MainWindow window, string name, params object?[] args)
        => (typeof(MainWindow).GetMethod(name, Private) ?? throw new MissingMethodException(name)).Invoke(window, args);
    private static void Require(bool condition, string error)
    {
        if (!condition) throw new InvalidOperationException(error);
    }
    private static T Complete<T>(Task<T> task)
    {
        if (!task.IsCompleted)
        {
            var frame = new DispatcherFrame();
            var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
            bool expired = false;
            timeout.Tick += (_, _) => { expired = true; frame.Continue = false; };
            task.GetAwaiter().OnCompleted(() => frame.Continue = false);
            timeout.Start();
            try { Dispatcher.PushFrame(frame); }
            finally { timeout.Stop(); }
            Require(!expired, "Offline continuation timed out");
        }
        return task.GetAwaiter().GetResult();
    }
    private static void CheckOfflineGate<T>(MainWindow window, T result) where T : class
    {
        var method = (typeof(MainWindow).GetMethod("AwaitOffline", Private) ?? throw new MissingMethodException("AwaitOffline")).MakeGenericMethod(typeof(T));
        Field("quitting").SetValue(window, false);
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = (Task<T?>)method.Invoke(window, [completion.Task])!;
        Require(!pending.IsCompleted, "Offline gate fixture must begin pending");
        Field("quitting").SetValue(window, true);
        completion.SetResult(result);
        Require(Complete(pending) is null, "In-flight offline result survived shutdown");
        Field("quitting").SetValue(window, false);
        var normal = (Task<T?>)method.Invoke(window, [Task.FromResult(result)])!;
        Require(ReferenceEquals(Complete(normal), result), "Normal offline result was discarded");
    }
    private static void ShutdownChecks(MainWindow window)
    {
        Field("smoke").SetValue(window, true);
        foreach (string name in new[] { "meterTimer", "sessionTimer", "applyTimer", "saveTimer", "gameTimer" })
            Read<DispatcherTimer>(window, name).Stop();
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            Field("rawSample").SetValue(window, new float[4800]);
            Field("matched").SetValue(window, null);
            Field("quitting").SetValue(window, true);
            var rendered = (Task<MatchedSample?>)Call(window, "RenderSample")!;
            Require(Complete(rendered) is null && Read<MatchedSample?>(window, "matched") is null,
                "Offline render published a result after shutdown");
            // An oversized fixture throws before SoundPlayer.Play in the old
            // implementation. The guarded path must ignore it without any audio.
            Call(window, "Play", (object)new float[AudioSamples.MaxFrames + 1]);
            Require(Read<object?>(window, "player") is null && Read<object?>(window, "playbackStream") is null,
                "Shutdown created a playback resource");
            CheckOfflineGate(window, new MatchedSample([], []));
            CheckOfflineGate(window, new PersonalCalibrationResult(false, "calibrationIncomplete", null));
            var normalRender = Complete((Task<MatchedSample?>)Call(window, "RenderSample")!);
            Require(normalRender?.Raw.Length == 3840 && ReferenceEquals(normalRender, Read<MatchedSample?>(window, "matched")),
                "Normal offline rendering no longer publishes its aligned result");
            Field("quitting").SetValue(window, true);
            Require(Complete((Task<MatchedSample?>)Call(window, "RenderSample")!) is null,
                "Cached comparison escaped shutdown guard");
            string statusBefore = Read<string>(window, "statusKey");
            var analysis = (Task)Call(window, "AnalyzePersonalSample")!;
            Require(analysis.IsCompleted && Read<string>(window, "statusKey") == statusBefore,
                "Personal analysis started or published UI after shutdown");
            analysis.GetAwaiter().GetResult();
            Field("quitting").SetValue(window, false);
            Call(window, "SetBusy", true);
            Field("quitting").SetValue(window, true);
            Call(window, "SetBusy", false);
            Require(!Read<System.Windows.Controls.Button>(window, "RecordButton").IsEnabled && !Read<bool>(window, "busy"),
                "Offline completion re-enabled controls during shutdown");
        }
        finally
        {
            Field("quitting").SetValue(window, false);
            Call(window, "SetBusy", false);
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }
    private static void AccessibilityChecks(MainWindow window)
    {
        Field("ready").SetValue(window, false);
        foreach (string language in new[] { "tr", "en" })
        {
            Call(window, "ChangeLanguage", language);
            foreach (var (name, key) in new[] { ("InputMeter", "inputMeterName"), ("OutputMeter", "outputMeterName"),
                ("SampleProgress", "sampleProgressName"), ("SensitivityMeter", "sensitivityInput"), ("PersonalProgress", "personalProgress") })
            {
                var element = Read<UIElement>(window, name);
                var peer = UIElementAutomationPeer.CreatePeerForElement(element);
                string expected = MainWindow.T(key);
                Require(expected != key && peer is not null && peer.GetName() == expected, name + " has an incorrect screen-reader name in " + language);
            }
            // Inspect actual peers created by the production EQ DataTemplate.
            // This checks names, without showing/focusing a window or editing audio.
            var template = Read<System.Windows.Controls.ItemsControl>(window, "BandsControl").ItemTemplate;
            var row = (FrameworkElement)template.LoadContent();
            row.DataContext = new EqBand();
            var controls = Descendants(row).OfType<System.Windows.Controls.Control>()
                .Where(c => c is System.Windows.Controls.ComboBox or TextBox or System.Windows.Controls.Slider).ToArray();
            var expectedNames = new[] { "eqTypeName", "eqFrequencyName", "eqGainName", "eqQName" }.Select(MainWindow.T).ToHashSet();
            var actualNames = controls.Select(c => UIElementAutomationPeer.CreatePeerForElement(c)?.GetName() ?? "").ToHashSet();
            Require(controls.Length == 4 && actualNames.SetEquals(expectedNames), "EQ screen-reader names are not localized in " + language);
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        foreach (object child in LogicalTreeHelper.GetChildren(parent))
            if (child is DependencyObject element)
            {
                yield return element;
                foreach (var descendant in Descendants(element)) yield return descendant;
            }
    }

    private static string SettingsJson(AudioSettings value)=>System.Text.Json.JsonSerializer.Serialize(value);

    private static void ProfileStatusChecks(MainWindow window,NativeEngine engine)
    {
        var state=Read<UserState>(window,"state");
        var factory=Profiles.Factory();
        var warm=factory.Single(p=>p.FactoryId=="warm");
        var customized=warm.Settings.Clone();customized.Bands[0].GainDb=5;customized.NoiseAutoEnabled=true;
        // Exercise the startup reconstruction without a real saved-state file.
        Field("ready").SetValue(window,false);
        state.Settings=customized.Clone();state.ActiveProfile="warm";
        Field("settings").SetValue(window,state.Settings.Clone());
        Call(window,"RebuildProfiles","warm");Call(window,"LoadControls");
        string snapshot=SettingsJson(customized);
        Require(SettingsJson(Read<AudioSettings>(window,"settings"))==snapshot&&
            Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text==MainWindow.T("custom"),
            "Startup reconstruction overwrote saved changes or mislabeled them as a factory tone");
        Call(window,"RebuildProfiles",(object?)null);
        Require(SettingsJson(Read<AudioSettings>(window,"settings"))==snapshot&&
            Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text==MainWindow.T("custom"),
            "Profile rebuild lost the modified saved tone");

        var presets=Read<System.Windows.Controls.ListBox>(window,"PresetList");
        var selected=presets.SelectedItem;
        var reapply=Read<System.Windows.Controls.Button>(window,"ReapplyProfileButton");
        reapply.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        Require(SettingsJson(Read<AudioSettings>(window,"settings"))==snapshot,"Profile reapply ignored startup readiness guard");
        presets.SelectedItem=null;Call(window,"RefreshProfileStatus");
        Require(!reapply.IsEnabled&&Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text==MainWindow.T("custom"),
            "Missing selected profile was treated as an unchanged tone");
        Call(window,"RebuildProfiles","missing-profile");
        Require(presets.SelectedItem is ProfileChoice fallback&&fallback.Profile.FactoryId=="natural"&&SettingsJson(Read<AudioSettings>(window,"settings"))==snapshot,
            "Missing profile fallback overwrote saved settings");
        Call(window,"RebuildProfiles","warm");selected=presets.SelectedItem;
        var mute=Read<System.Windows.Controls.CheckBox>(window,"MuteBox");
        var bypass=Read<System.Windows.Controls.CheckBox>(window,"BypassBox");
        mute.IsChecked=true;bypass.IsChecked=true;
        Field("ready").SetValue(window,true);Call(window,"ApplySettings");
        foreach(string flag in new[]{"suppress","busy","calibrating","sampling","personalCalibrating","finishing","quitting"})
        {
            Field(flag).SetValue(window,true);
            reapply.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
            Require(SettingsJson(Read<AudioSettings>(window,"settings"))==snapshot,"Profile reapply ignored "+flag+" guard");
            Field(flag).SetValue(window,false);
        }
        reapply.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        Require(ReferenceEquals(presets.SelectedItem,selected)&&SettingsJson(Read<AudioSettings>(window,"settings"))==SettingsJson(warm.Settings)&&
            SettingsJson(Read<AudioSettings>(window,"lastAppliedSettings"))==SettingsJson(warm.Settings)&&
            Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text.Length==0&&mute.IsChecked==true&&bypass.IsChecked==true,
            "Reapply did not restore the same selected tone, reach the engine, or preserve transmission controls");

        var noise=Read<System.Windows.Controls.CheckBox>(window,"NoiseBox");
        noise.IsChecked=false;
        Require(Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text==MainWindow.T("custom"),"Processing toggle was not reflected in profile status");
        noise.IsChecked=true;
        Require(Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text.Length==0,"Returning a processing toggle to its profile value stayed custom");
        var warmth=Read<System.Windows.Controls.Slider>(window,"WarmthSlider");
        warmth.Value=warm.Settings.Bands[0].GainDb+1;
        Require(Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text==MainWindow.T("custom"),"Pending slider edit was not reflected immediately");
        warmth.Value=warm.Settings.Bands[0].GainDb;
        Call(window,"ApplySettings");
        Require(Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text.Length==0,"Returning a slider to its profile value stayed custom");

        string before=SettingsJson(Read<AudioSettings>(window,"settings"));
        string input=state.InputId,output=state.OutputId,mode=state.OutputMode;
        var notice=Read<FrameworkElement>(window,"BypassNotice");
        var resume=Read<System.Windows.Controls.Button>(window,"ResumeProcessingButton");
        Require(notice.Visibility==Visibility.Visible&&resume.IsEnabled,"Bypass did not expose a persistent notice/action");
        // This safety control remains usable while profile changes are blocked.
        Call(window,"SetBusy",true);
        resume.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Button.ClickEvent));
        Call(window,"SetBusy",false);
        Require(bypass.IsChecked==false&&mute.IsChecked==true&&notice.Visibility==Visibility.Collapsed&&
            SettingsJson(Read<AudioSettings>(window,"settings"))==before&&state.InputId==input&&state.OutputId==output&&state.OutputMode==mode&&
            Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text.Length==0,
            "Return to processing changed mute, route or profile settings");
        mute.IsChecked=false;bypass.IsChecked=true;
        Require(Read<System.Windows.Controls.TextBlock>(window,"ModifiedLabel").Text.Length==0,"Mute/bypass incorrectly made the tone custom");

        foreach(string language in new[]{"tr","en"})
        {
            Call(window,"ChangeLanguage",language);Call(window,"RebuildProfiles",(object?)null);
            foreach(var (name,key) in new[]{("ReapplyProfileButton","reapplyProfile"),("ResumeProcessingButton","resumeProcessing")})
            {
                var peer=UIElementAutomationPeer.CreatePeerForElement(Read<UIElement>(window,name));
                Require(peer is not null&&peer.GetName()==MainWindow.T(key)&&MainWindow.T(key)!=key,"Profile action is not localized/accessibly named: "+name);
            }
            Require(Read<System.Windows.Controls.TextBlock>(window,"BypassNoticeText").Text==MainWindow.T("bypassNotice")&&
                System.Windows.Automation.AutomationProperties.GetLiveSetting(Read<UIElement>(window,"BypassNoticeText"))==System.Windows.Automation.AutomationLiveSetting.Polite&&
                SettingsJson(Read<AudioSettings>(window,"settings"))==before,"Translation altered the tone or bypass notice is not a polite live region");
        }
        Call(window,"ChangeLanguage","tr");Call(window,"RebuildProfiles",(object?)null);
        bypass.IsChecked=false;
        foreach(var choice in ((IEnumerable<ProfileChoice>)presets.ItemsSource).Take(factory.Count))
        {
            presets.SelectedItem=choice;
            Require(SettingsJson(Read<AudioSettings>(window,"settings"))==SettingsJson(choice.Profile.Settings)&&
                SettingsJson(Read<AudioSettings>(window,"lastAppliedSettings"))==SettingsJson(choice.Profile.Settings),
                "Factory selection did not apply complete settings: "+choice.Profile.FactoryId);
        }
        Require(engine.Metrics().Running==0&&engine.Metrics().ProcessedFrames==0,"Profile status checks opened or processed an audio stream");
        Field("ready").SetValue(window,false);
        Read<DispatcherTimer>(window,"applyTimer").Stop();
        Call(window,"RebuildProfiles","natural");
        Field("settings").SetValue(window,factory[0].Settings.Clone());Call(window,"LoadControls");
    }
    private static void QuitChecks(MainWindow window, NativeEngine engine, Application application)
    {
        Field("ready").SetValue(window, true);
        Field("smoke").SetValue(window, true);
        Field("matched").SetValue(window, null);
        var sample = new float[AudioSamples.MaxFrames];
        for (int i = 0; i < sample.Length; i++) sample[i] = .01f * (float)Math.Sin(i * .03);
        Field("rawSample").SetValue(window, sample);
        var lifecycle = Read<SemaphoreSlim>(window, "lifecycle");
        Require(lifecycle.Wait(0), "Quit lifecycle fixture was already held");
        var previous = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        bool released = false, closed = false, exited = false;
        window.Closed += (_, _) => closed = true;
        DispatcherFrame? exitFrame = null;
        application.Exit += (_, _) => { exited = true; if (exitFrame is not null) exitFrame.Continue = false; };
        try
        {
            var rendering = (Task<MatchedSample?>)Call(window, "RenderSample")!;
            Require(!rendering.IsCompleted, "Quit fixture needs an in-flight render");
            // Invoke the exact production method used by the tray's exit callback.
            // Hold its lifecycle semaphore until the real offline render returns.
            Call(window, "Quit");
            Require(Read<bool>(window, "quitting"), "Production Quit did not begin");
            Require(Complete(rendering) is null && Read<MatchedSample?>(window, "matched") is null,
                "Production Quit allowed an in-flight render to publish");
            Require(!closed && !exited && Read<object?>(window, "player") is null,
                "Quit ignored the lifecycle barrier or created playback");
            lifecycle.Release(); released = true;
            var frame = new DispatcherFrame();
            var timeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
            bool expired = false;
            timeout.Tick += (_, _) => { expired = true; frame.Continue = false; };
            timeout.Start();
            // A fixture without Application.Run owns its nested dispatcher frame.
            // Stop on the real Application.Exit event rather than its timeout.
            exitFrame = frame;
            try { if (!exited) Dispatcher.PushFrame(frame); }
            finally { timeout.Stop(); }
            var nativeHandle = (System.Runtime.InteropServices.SafeHandle)typeof(NativeEngine).GetField("handle", Private)!.GetValue(engine)!;
            Require(!expired && closed && exited && nativeHandle.IsClosed,
                 $"Production Quit incomplete: expired={expired}, closed={closed}, exited={exited}, nativeClosed={nativeHandle.IsClosed}, dispatcherShutdown={application.Dispatcher.HasShutdownStarted}");
        }
        finally
        {
            if (!released) lifecycle.Release();
            SynchronizationContext.SetSynchronizationContext(previous);
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        bool verifyQuit = args.SequenceEqual(new[] { "--verify-quit" });
        if (args.Length > 0 && !verifyQuit) { Console.Error.WriteLine("Unknown desktop test arguments."); return 1; }
        // Plain Application: never invoke SES App.OnStartup/WindowLoaded, show a
        // window, enumerate/open microphones, register hotkeys or start audio.
        var application = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        application.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Veylo;component/Resources/Theme.xaml") });
        application.Resources.MergedDictionaries.Add(new ResourceDictionary { Source = new Uri("pack://application:,,,/Veylo;component/Resources/tr.xaml") });
        string root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "profile-tests-" + Guid.NewGuid().ToString("N")));
        MainWindow? window = null;
        NativeEngine? engine = null;
        try
        {
            Directory.CreateDirectory(root);
            string blocker = Path.Combine(root, "not-a-directory");
            File.WriteAllText(blocker, "isolated write failure fixture");
            window = new MainWindow(smoke: true, args: []);
            Require(window.Title == "Veylo" && typeof(MainWindow).Assembly.GetName().Name == "Veylo", "Public Veylo identity is missing");
            engine = Read<NativeEngine>(window, "engine");
            Require(!Read<bool>(window, "ready") && engine.Metrics().Running == 0, "Window unexpectedly started");
            ProfileStatusChecks(window,engine);
            // Replace only this unshown smoke window's store and lifecycle flags.
            // Persistence checks do not pump the dispatcher. ShutdownChecks
            // later uses the plain Application dispatcher with all timers stopped.
            Field("store").SetValue(window, new UserStore(blocker));
            Field("smoke").SetValue(window, false);
            Field("ready").SetValue(window, true);
            Read<TextBox>(window, "ProfileNameBox").Text = "Write failure";
            Call(window, "SaveProfileClick", window, new RoutedEventArgs());
            Require(Read<string>(window, "statusKey") == "error", "Profile write failure was reported as success");
            Require(!File.Exists(Path.Combine(blocker, "state.json")), "Failure fixture unexpectedly persisted");

            var validStore = new UserStore(Path.Combine(root, "valid"));
            Field("store").SetValue(window, validStore);
            Read<TextBox>(window, "ProfileNameBox").Text = "Saved voice";
            Call(window, "SaveProfileClick", window, new RoutedEventArgs());
            Require(Read<string>(window, "statusKey") == "saved", "Successful profile save not reported");
            var saved = validStore.Load();
            Require(!validStore.LoadWarning && saved.Profiles.Any(p => p.Name == "Saved voice"), "Successful save did not survive reload");

            var incoming = Profiles.Deserialize(Profiles.Serialize(new VoiceProfile { Name = "Imported voice" }));
            string beforeFailure = File.ReadAllText(Path.Combine(root, "valid", "state.json"));
            Field("store").SetValue(window, new UserStore(blocker));
            Call(window, "ImportProfile", incoming);
            Require(Read<string>(window, "statusKey") == "error", "Import write failure was reported as success");
            Require(File.ReadAllText(Path.Combine(root, "valid", "state.json")) == beforeFailure, "Failed import changed the last persisted settings");
            Field("store").SetValue(window, validStore);
            Call(window, "ImportProfile", incoming);
            saved = validStore.Load();
            Require(Read<string>(window, "statusKey") == "imported" && !validStore.LoadWarning && saved.Profiles.Count(p => p.Name == "Imported voice") == 1,
                "Successful import did not survive reload or duplicated the retry");

            string atomicFailure = Path.Combine(root, "atomic-failure");
            Directory.CreateDirectory(Path.Combine(atomicFailure, "state.json"));
            Field("store").SetValue(window, new UserStore(atomicFailure));
            Call(window, "SaveProfileClick", window, new RoutedEventArgs());
            Require(Read<string>(window, "statusKey") == "error", "Atomic replacement failure was reported as success");
            Call(window, "ImportProfile", incoming);
            Require(Read<string>(window, "statusKey") == "error", "Atomic import replacement failure was reported as success");
            Require(!Directory.EnumerateFiles(atomicFailure, "state.*.tmp").Any(), "Failed atomic write left temporary settings behind");

            ShutdownChecks(window);
            AccessibilityChecks(window);

            Require(engine.Metrics().Running == 0 && engine.Metrics().ProcessedFrames == 0, "Persistence tests started or processed audio");
            if (verifyQuit) QuitChecks(window, engine, application);
            Console.WriteLine("Passed: profile state/reapply/bypass regressions; persistence and offline shutdown regressions; actual TR/EN meter/progress/EQ/action automation peer names; no audio or user state used.");
            if (verifyQuit) Console.WriteLine("Passed: production Quit during a real in-flight offline render; window, native handle and application closed.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
        finally
        {
            if (window is not null)
            {
                Field("ready").SetValue(window, false);
                Field("smoke").SetValue(window, true);
                foreach (string name in new[] { "meterTimer", "sessionTimer", "applyTimer", "saveTimer", "gameTimer" })
                    Read<DispatcherTimer>(window, name).Stop();
                Call(window, "StopExperience");
            }
            engine?.Dispose();
            // Root is created by this test beneath its own executable directory.
            if (!root.StartsWith(Path.GetFullPath(AppContext.BaseDirectory), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Test cleanup escaped its output directory");
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
            if (!application.Dispatcher.HasShutdownStarted) application.Shutdown();
        }
    }
}
