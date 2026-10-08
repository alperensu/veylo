using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Ses.DriverSetup;
// Windows calculates the SIP/catalog hash (a PE hash is not a raw file SHA).
// Read-only; no catalog registration, certificate import or Driver Store changes.
internal static class CatalogMembership
{
    private static readonly Guid DriverSubsystem=new("f750e6c3-38ee-11d1-85e5-00c04fc295ee");
    private static readonly Guid VerifyAction=new("00aac56b-cd44-11d0-8cc2-00c04fc295ee");
    internal static void Verify(string catalogPath,string memberPath,FileStream member)
    {
        if(!CryptCATAdminAcquireContext2(out IntPtr admin,in DriverSubsystem,"SHA256",IntPtr.Zero,0))
            throw new CryptographicException("Cannot initialize Windows catalog verification.");
        IntPtr catalogInfo=IntPtr.Zero,hashPointer=IntPtr.Zero;
        try
        {
            uint length=0;member.Position=0;
            if(!CryptCATAdminCalcHashFromFileHandle2(admin,member.SafeFileHandle.DangerousGetHandle(),ref length,null,0)||length!=32)
                throw new CryptographicException("Cannot calculate SHA-256 catalog member hash.");
            byte[] hash=new byte[length];member.Position=0;
            if(!CryptCATAdminCalcHashFromFileHandle2(admin,member.SafeFileHandle.DangerousGetHandle(),ref length,hash,0)||length!=hash.Length)
                throw new CryptographicException("Cannot calculate catalog member hash.");
            hashPointer=Marshal.AllocHGlobal(hash.Length);Marshal.Copy(hash,0,hashPointer,hash.Length);
            var info=new CatalogInfo{Size=(uint)Marshal.SizeOf<CatalogInfo>(),CatalogPath=catalogPath,
                MemberTag=Convert.ToHexString(hash),MemberPath=memberPath,MemberHandle=member.SafeFileHandle.DangerousGetHandle(),
                Hash=hashPointer,HashLength=length,Admin=admin};
            catalogInfo=Marshal.AllocHGlobal(Marshal.SizeOf<CatalogInfo>());Marshal.StructureToPtr(info,catalogInfo,false);
            var data=new TrustData{Size=(uint)Marshal.SizeOf<TrustData>(),UiChoice=2,UnionChoice=2,Catalog=catalogInfo,
                StateAction=1,ProviderFlags=0x1000|0x2000,UiContext=1};
            try
            {
                int result=WinVerifyTrust(new IntPtr(-1),in VerifyAction,ref data);
                if(result!=0)throw new CryptographicException($"Driver catalog membership verification failed (0x{result:X8}).");
            }
            finally{data.StateAction=2;WinVerifyTrust(new IntPtr(-1),in VerifyAction,ref data);}
        }
        finally
        {
            if(catalogInfo!=IntPtr.Zero){Marshal.DestroyStructure<CatalogInfo>(catalogInfo);Marshal.FreeHGlobal(catalogInfo);}
            if(hashPointer!=IntPtr.Zero)Marshal.FreeHGlobal(hashPointer);
            CryptCATAdminReleaseContext(admin,0);
            GC.KeepAlive(member);
        }
    }
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]internal struct CatalogInfo
    {
        public uint Size,Version;
        [MarshalAs(UnmanagedType.LPWStr)]public string? CatalogPath;
        [MarshalAs(UnmanagedType.LPWStr)]public string? MemberTag;
        [MarshalAs(UnmanagedType.LPWStr)]public string? MemberPath;
        public IntPtr MemberHandle,Hash;public uint HashLength;public IntPtr Context,Admin;
    }
    [StructLayout(LayoutKind.Sequential)]internal struct TrustData
    {
        public uint Size;public IntPtr Policy,Client;public uint UiChoice,Revocation,UnionChoice;
        public IntPtr Catalog;public uint StateAction;public IntPtr State,Url;public uint ProviderFlags,UiContext;
        public IntPtr SignatureSettings;
    }
    [DllImport("wintrust.dll",CharSet=CharSet.Unicode,ExactSpelling=true,SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]private static extern bool CryptCATAdminAcquireContext2(out IntPtr context,in Guid subsystem,string algorithm,IntPtr policy,uint flags);
    [DllImport("wintrust.dll",ExactSpelling=true,SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]private static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr context,IntPtr file,ref uint length,[Out]byte[]? hash,uint flags);
    [DllImport("wintrust.dll",ExactSpelling=true)]
    [return:MarshalAs(UnmanagedType.Bool)]private static extern bool CryptCATAdminReleaseContext(IntPtr context,uint flags);
    [DllImport("wintrust.dll",ExactSpelling=true)]private static extern int WinVerifyTrust(IntPtr hwnd,in Guid action,ref TrustData data);
}
