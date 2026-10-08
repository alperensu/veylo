using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.Cryptography.Pkcs;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;

namespace Ses.DriverSetup;
internal static class Program
{
    private const string Hardware="ROOT\\SES_MICROPHONE";
    private const long MaximumPackageFileBytes=16*1024*1024;
    private static readonly string[] PackageFiles={"SesMicrophone.inf","SesMicrophone.sys","SesMicrophone.cat"};
    private static readonly Guid Media=new("4d36e96c-e325-11ce-bfc1-08002be10318");
    internal static string? ParseAction(string[] args)=>args.Length==0?"status":args.Length==1&&args[0] is "status" or "package-status" or "install" or "remove" or "rollback"?args[0]:null;
    private static int Main(string[] args)
    {
        string? action=ParseAction(args);
        if(action is null){Console.Error.WriteLine("status | package-status | install | remove | rollback");return 2;}
        try
        {
            if(action=="status"){using var devices=new Devices();Console.WriteLine(devices.Find().Count>0?"installed":"missing");return 0;}
            if(action=="package-status")
            {
                try{ReadPackage(Path.Combine(AppContext.BaseDirectory,"driver"));Console.WriteLine("ready");}
                catch(Exception ex)when(IsPackageError(ex)){Console.WriteLine("unavailable");}
                return 0;
            }
            using var identity=WindowsIdentity.GetCurrent();
            if(!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            {
                using var elevated=Process.Start(new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=true,Verb="runas",Arguments=action,WindowStyle=ProcessWindowStyle.Hidden})??throw new IOException("Cannot start installer.");
                elevated.WaitForExit();return elevated.ExitCode;
            }
            using var list=new Devices();var own=list.Find();bool reboot=false;
            if(action=="install")
            {
                string stage=StagePackage(ReadPackage(Path.Combine(AppContext.BaseDirectory,"driver")));
                try
                {
                    bool created=own.Count==0;DeviceInfo info=created?list.Create():own[0];
                    // Windows verifies catalog membership and kernel signing policy again.
                    // Never disable these checks or import test certificates.
                    try{if(!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero,Hardware,Path.Combine(stage,"SesMicrophone.inf"),1,out reboot))throw Error();}
                    catch{if(created)list.Remove(info);throw;}
                }
                finally{RemoveStage(stage);}
            }
            else if(action=="remove")
            {
                // Package identity comes from the exact SES PnP device, never a user argument.
                var snapshot=own.Select(info=>(Info:info,Inf:list.InfName(info))).ToArray();
                var packages=PlanPackageRemoval(snapshot.Select(item=>item.Inf));
                foreach(var item in snapshot)reboot|=list.Remove(item.Info);
                foreach(string inf in packages)
                {
                    string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"INF",inf);
                    if(!DiUninstallDriver(IntPtr.Zero,path,0,out bool needs))throw Error();reboot|=needs;
                }
            }
            else
            {
                if(own.Count==0)throw new IOException("Veylo device is not installed.");
                foreach(var item in own){var info=item;if(!DiRollbackDriver(IntPtr.Zero,list.Handle,ref info,0,out bool needs))throw Error();reboot|=needs;}
            }
            Console.WriteLine(reboot?"restart-required":"complete");return reboot?3010:0;
        }
        catch(Win32Exception ex){Console.Error.WriteLine($"Windows error {ex.NativeErrorCode}: {ex.Message}");return ex.NativeErrorCode==1223?1223:1603;}
        catch(Exception ex)when(ex is IOException or UnauthorizedAccessException or CryptographicException or InvalidDataException){Console.Error.WriteLine(ex.Message);return 1603;}
    }
    private static bool IsPackageError(Exception ex)=>ex is IOException or UnauthorizedAccessException or CryptographicException or InvalidDataException;
    internal static string[] PlanPackageRemoval(IEnumerable<string?> names)=>names.Where(name=>name is not null&&System.Text.RegularExpressions.Regex.IsMatch(name,@"\Aoem[0-9]+\.inf\z",System.Text.RegularExpressions.RegexOptions.IgnoreCase)).Select(name=>name!).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    internal static Dictionary<string,byte[]> ReadPackage(string package)
    {
        package=Path.GetFullPath(package);EnsureNoReparsePath(package);
        using var expected=typeof(Program).Assembly.GetManifestResourceStream("SES.Expected.inf")!;using var memory=new MemoryStream();expected.CopyTo(memory);
        var files=new Dictionary<string,byte[]>();var handles=new Dictionary<string,FileStream>();
        try
        {
            foreach(string name in PackageFiles)
            {
                string path=Path.Combine(package,name);EnsureNoReparsePath(path);
                var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);handles.Add(name,input);
                long length=input.Length;
                if(length==0||length>MaximumPackageFileBytes)throw new InvalidDataException("Complete signed Veylo driver package is required.");
                byte[] bytes=new byte[checked((int)length)];input.ReadExactly(bytes);files[name]=bytes;
            }
            if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(memory.ToArray()),SHA256.HashData(files["SesMicrophone.inf"])))throw new InvalidDataException("Unexpected driver INF; only the Veylo package can be managed.");
            VerifyMicrosoftCatalog(files["SesMicrophone.cat"]);
            foreach(string name in new[]{"SesMicrophone.inf","SesMicrophone.sys"})
                CatalogMembership.Verify(Path.Combine(package,"SesMicrophone.cat"),Path.Combine(package,name),handles[name]);
            return files;
        }
        finally{foreach(var handle in handles.Values)handle.Dispose();}
    }
    private static string StageRoot=>Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"Veylo Driver Packages");
    private static string StagePackage(Dictionary<string,byte[]> files)
    {
        EnsureNoReparsePath(StageRoot);Directory.CreateDirectory(StageRoot);EnsureNoReparsePath(StageRoot);
        string stage=Path.Combine(StageRoot,Guid.NewGuid().ToString("N"));
        if(Directory.Exists(stage)||File.Exists(stage))throw new IOException("Driver staging directory already exists.");
        Directory.CreateDirectory(stage);
        try
        {
            EnsureNoReparsePath(stage);
            foreach(string name in PackageFiles)
            {
                using var output=new FileStream(Path.Combine(stage,name),FileMode.CreateNew,FileAccess.Write,FileShare.None);
                output.Write(files[name]);
            }
            return stage;
        }
        catch{RemoveStage(stage);throw;}
    }
    private static void RemoveStage(string stage)
    {
        string full=Path.GetFullPath(stage),root=Path.GetFullPath(StageRoot);
        if(!string.Equals(Path.GetDirectoryName(full),root,StringComparison.OrdinalIgnoreCase)||!Guid.TryParseExact(Path.GetFileName(full),"N",out _))throw new IOException("Unsafe driver staging directory.");
        EnsureNoReparsePath(full);
        // Delete only this invocation's fixed package files; never traverse or recursively
        // remove unexpected entries, other versions, or the shared parent directory.
        foreach(string name in PackageFiles){string path=Path.Combine(full,name);EnsureNoReparsePath(path);File.Delete(path);}
        Directory.Delete(full,false);
    }
    internal static void EnsureNoReparsePath(string path)
    {
        string? current=Path.GetFullPath(path);
        while(current is not null)
        {
            try{if((File.GetAttributes(current)&FileAttributes.ReparsePoint)!=0)throw new IOException("Reparse points are not allowed in driver package paths.");}
            catch(FileNotFoundException){}
            catch(DirectoryNotFoundException){}
            current=Path.GetDirectoryName(current);
        }
    }
    internal static void VerifyMicrosoftCatalog(string path)
    {
        EnsureNoReparsePath(path);using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);
        if(input.Length==0||input.Length>MaximumPackageFileBytes)throw new InvalidDataException("Invalid driver catalog size.");
        byte[] bytes=new byte[checked((int)input.Length)];input.ReadExactly(bytes);VerifyMicrosoftCatalog(bytes);
    }
    private static void VerifyMicrosoftCatalog(byte[] bytes)
    {
        var cms=new SignedCms();cms.Decode(bytes);
        if(cms.SignerInfos.Count!=1)throw new CryptographicException("Unexpected catalog signer count.");
        cms.CheckSignature(false);var signer=cms.SignerInfos[0].Certificate??throw new CryptographicException("Missing catalog signer.");
        if(!signer.Subject.Contains("Microsoft Windows",StringComparison.Ordinal)||!signer.Issuer.Contains("Microsoft",StringComparison.Ordinal))throw new CryptographicException("Microsoft Windows production signature is required.");
        // User-installed roots must not authorize an elevated kernel package.
        using var chain=new X509Chain(true);chain.ChainPolicy.RevocationMode=X509RevocationMode.Online;
        chain.ChainPolicy.RevocationFlag=X509RevocationFlag.ExcludeRoot;
        chain.ChainPolicy.UrlRetrievalTimeout=TimeSpan.FromSeconds(15);
        if(!chain.Build(signer)||!chain.ChainElements[^1].Certificate.Subject.Contains("Microsoft",StringComparison.Ordinal))throw new CryptographicException("Catalog signature is not trusted.");
    }
    private static Win32Exception Error()=>new(Marshal.GetLastWin32Error());
    [StructLayout(LayoutKind.Sequential)]internal struct DeviceInfo {public uint Size;public Guid Class;public uint Instance;public IntPtr Reserved;public static DeviceInfo New()=>new(){Size=(uint)Marshal.SizeOf<DeviceInfo>()};}
    private sealed class Devices : IDisposable
    {
        internal IntPtr Handle {get;}
        internal Devices(){Handle=SetupDiGetClassDevs(in Media,null,IntPtr.Zero,0);if(Handle==new IntPtr(-1))throw Error();}
        internal List<DeviceInfo> Find()
        {
            var result=new List<DeviceInfo>();
            for(uint i=0;;i++)
            {
                var info=DeviceInfo.New();if(!SetupDiEnumDeviceInfo(Handle,i,ref info)){if(Marshal.GetLastWin32Error()==259)break;throw Error();}
                var bytes=new byte[4096];if(!SetupDiGetDeviceRegistryProperty(Handle,ref info,1,out _,bytes,(uint)bytes.Length,out _))continue;
                if(Encoding.Unicode.GetString(bytes).Split('\0',StringSplitOptions.RemoveEmptyEntries).Any(id=>id.Equals(Hardware,StringComparison.OrdinalIgnoreCase)))result.Add(info);
            }
            return result;
        }
        internal DeviceInfo Create()
        {
            var info=DeviceInfo.New();if(!SetupDiCreateDeviceInfo(Handle,"Veylo Mikrofon",in Media,"Veylo virtual capture",IntPtr.Zero,1,ref info))throw Error();
            byte[] id=Encoding.Unicode.GetBytes(Hardware+"\0\0");
            if(!SetupDiSetDeviceRegistryProperty(Handle,ref info,1,id,(uint)id.Length)||!SetupDiCallClassInstaller(0x19,Handle,ref info))throw Error();return info;
        }
        internal bool Remove(DeviceInfo info){if(!DiUninstallDevice(IntPtr.Zero,Handle,ref info,0,out bool reboot))throw Error();return reboot;}
        internal string? InfName(DeviceInfo info)
        {
            byte[] buffer=new byte[4096];if(!SetupDiGetDeviceRegistryProperty(Handle,ref info,9,out _,buffer,(uint)buffer.Length,out _))return null;
            string key=Encoding.Unicode.GetString(buffer).TrimEnd('\0');
            using var registry=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Class\"+key);
            string? name=registry?.GetValue("InfPath") as string;
            return name is not null&&System.Text.RegularExpressions.Regex.IsMatch(name,@"\Aoem[0-9]+\.inf\z",System.Text.RegularExpressions.RegexOptions.IgnoreCase)?name:null;
        }
        public void Dispose()=>SetupDiDestroyDeviceInfoList(Handle);
    }
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)]private static extern IntPtr SetupDiGetClassDevs(in Guid guid,string? enumerator,IntPtr hwnd,uint flags);
    [DllImport("setupapi.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiEnumDeviceInfo(IntPtr set,uint index,ref DeviceInfo info);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiCreateDeviceInfo(IntPtr set,string name,in Guid guid,string description,IntPtr hwnd,uint flags,ref DeviceInfo info);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiGetDeviceRegistryProperty(IntPtr set,ref DeviceInfo info,uint property,out uint type,byte[] buffer,uint capacity,out uint required);
    [DllImport("setupapi.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiSetDeviceRegistryProperty(IntPtr set,ref DeviceInfo info,uint property,byte[] buffer,uint size);
    [DllImport("setupapi.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiCallClassInstaller(uint function,IntPtr set,ref DeviceInfo info);
    [DllImport("setupapi.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);
    [DllImport("newdev.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool UpdateDriverForPlugAndPlayDevices(IntPtr hwnd,string hardware,string inf,uint flags,[MarshalAs(UnmanagedType.Bool)]out bool reboot);
    [DllImport("newdev.dll",CharSet=CharSet.Unicode,SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool DiUninstallDriver(IntPtr hwnd,string inf,uint flags,[MarshalAs(UnmanagedType.Bool)]out bool reboot);
    [DllImport("newdev.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool DiRollbackDriver(IntPtr hwnd,IntPtr set,ref DeviceInfo info,uint flags,[MarshalAs(UnmanagedType.Bool)]out bool reboot);
    [DllImport("newdev.dll",SetLastError=true)][return:MarshalAs(UnmanagedType.Bool)]private static extern bool DiUninstallDevice(IntPtr hwnd,IntPtr set,ref DeviceInfo info,uint flags,[MarshalAs(UnmanagedType.Bool)]out bool reboot);
}
