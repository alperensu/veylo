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
    private static readonly Guid Media=new("4d36e96c-e325-11ce-bfc1-08002be10318");
    private static int Main(string[] args)
    {
        string action=args.Length==1?args[0]:"status";
        if(action is not ("status" or "install" or "remove" or "rollback")){Console.Error.WriteLine("status | install | remove | rollback");return 2;}
        try
        {
            if(action=="status"){using var devices=new Devices();Console.WriteLine(devices.Find().Count>0?"installed":"missing");return 0;}
            using var identity=WindowsIdentity.GetCurrent();
            if(!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator))
            {
                using var elevated=Process.Start(new ProcessStartInfo(Environment.ProcessPath!){UseShellExecute=true,Verb="runas",Arguments=action})??throw new IOException("Cannot start installer.");
                elevated.WaitForExit();return elevated.ExitCode;
            }
            using var list=new Devices();var own=list.Find();bool reboot=false;
            if(action=="install")
            {
                string stage=StagePackage();
                bool created=own.Count==0;DeviceInfo info=created?list.Create():own[0];
                try{if(!UpdateDriverForPlugAndPlayDevices(IntPtr.Zero,Hardware,Path.Combine(stage,"SesMicrophone.inf"),1,out reboot))throw Error();}
                catch{if(created)list.Remove(info);throw;}
            }
            else if(action=="remove")
            {
                // Package identity comes from the exact SES PnP device, never a user argument.
                foreach(var info in own)
                {
                    string? inf=list.InfName(info);
                    reboot|=list.Remove(info);
                    if(inf is not null)
                    {
                        string path=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),"INF",inf);
                        if(!DiUninstallDriver(IntPtr.Zero,path,0,out bool needs))throw Error();reboot|=needs;
                    }
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
    private static string StagePackage()
    {
        string package=Path.Combine(AppContext.BaseDirectory,"driver");
        using var expected=typeof(Program).Assembly.GetManifestResourceStream("SES.Expected.inf")!;using var memory=new MemoryStream();expected.CopyTo(memory);
        var files=new Dictionary<string,byte[]>();
        foreach(string name in new[]{"SesMicrophone.inf","SesMicrophone.sys","SesMicrophone.cat"})
        {
            string path=Path.Combine(package,name);var info=new FileInfo(path);
            if(!info.Exists||info.Length==0||info.Length>16*1024*1024||(info.Attributes&FileAttributes.ReparsePoint)!=0)throw new InvalidDataException("Complete signed Veylo driver package is required.");
            using var input=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);byte[] bytes=new byte[info.Length];input.ReadExactly(bytes);files[name]=bytes;
        }
        if(!CryptographicOperations.FixedTimeEquals(SHA256.HashData(memory.ToArray()),SHA256.HashData(files["SesMicrophone.inf"])))throw new InvalidDataException("Unexpected driver INF; only the Veylo package can be managed.");
        string stage=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"Veylo Driver Packages",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);foreach(var file in files)File.WriteAllBytes(Path.Combine(stage,file.Key),file.Value);
        VerifyMicrosoftCatalog(Path.Combine(stage,"SesMicrophone.cat"));
        // Windows UpdateDriverForPlugAndPlayDevices verifies catalog membership and kernel
        // signing policy again. Never disable those OS checks or import test certificates.
        return stage;
    }
    internal static void VerifyMicrosoftCatalog(string path)
    {
        var cms=new SignedCms();cms.Decode(File.ReadAllBytes(path));
        if(cms.SignerInfos.Count!=1)throw new CryptographicException("Unexpected catalog signer count.");
        cms.CheckSignature(false);var signer=cms.SignerInfos[0].Certificate??throw new CryptographicException("Missing catalog signer.");
        if(!signer.Subject.Contains("Microsoft Windows",StringComparison.Ordinal)||!signer.Issuer.Contains("Microsoft",StringComparison.Ordinal))throw new CryptographicException("Microsoft Windows production signature is required.");
        using var chain=new X509Chain();chain.ChainPolicy.RevocationMode=X509RevocationMode.Online;
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
            return name is not null&&System.Text.RegularExpressions.Regex.IsMatch(name,@"^oem[0-9]+\.inf$",System.Text.RegularExpressions.RegexOptions.IgnoreCase)?name:null;
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
