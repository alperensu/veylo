#include "bridge.h"
#include <wdmsec.h>
#include "pcm_ring.h"
namespace {
PDEVICE_OBJECT controlDevice=nullptr;
PDEVICE_OBJECT adapterDevice=nullptr;
PDRIVER_OBJECT bridgeDriver=nullptr;
struct ControlExtension {ULONG signature;};
constexpr ULONG controlSignature=0x53455343;
PDRIVER_DISPATCH previous[IRP_MJ_MAXIMUM_FUNCTION+1]{};
KSPIN_LOCK lock;
ses_driver::PcmRing ring{};
PFILE_OBJECT owner=nullptr;
BOOLEAN online=FALSE;
constexpr GUID controlClass={0x7cef8f0e,0x8352,0x4b91,{0xa7,0x1d,0x8d,0x3b,0x1b,0xa4,0xdd,0xfe}};
uint64_t millis(){return KeQueryInterruptTime()/10000;}
NTSTATUS complete(PIRP irp,NTSTATUS status,ULONG_PTR information=0){irp->IoStatus.Status=status;irp->IoStatus.Information=information;IoCompleteRequest(irp,IO_NO_INCREMENT);return status;}
_Dispatch_type_(IRP_MJ_CREATE)
_Dispatch_type_(IRP_MJ_CLEANUP)
_Dispatch_type_(IRP_MJ_CLOSE)
_Dispatch_type_(IRP_MJ_DEVICE_CONTROL)
DRIVER_DISPATCH dispatch;
NTSTATUS dispatch(PDEVICE_OBJECT device,PIRP irp){
    auto* stack=IoGetCurrentIrpStackLocation(irp);
    // Deleted CDOs remain alive while old handles/IRPs refer to them. Recognize
    // them by their own type/extension, never send them through PortCls.
    if(device->DeviceType!=SES_DRIVER_DEVICE_TYPE)return previous[stack->MajorFunction](device,irp);
    if(!device->DeviceExtension||static_cast<ControlExtension*>(device->DeviceExtension)->signature!=controlSignature)
        return complete(irp,STATUS_INVALID_DEVICE_REQUEST);
    NTSTATUS result=STATUS_INVALID_DEVICE_REQUEST;ULONG_PTR information=0;
    KIRQL irql;KeAcquireSpinLock(&lock,&irql);
    switch(stack->MajorFunction){
    case IRP_MJ_CREATE:result=(device==controlDevice&&online)?STATUS_SUCCESS:STATUS_DEVICE_NOT_READY;break;
    case IRP_MJ_CLEANUP:
    case IRP_MJ_CLOSE:if(device==controlDevice&&owner==stack->FileObject){ring.disconnect();owner=nullptr;}result=STATUS_SUCCESS;break;
    case IRP_MJ_DEVICE_CONTROL:{
        const ULONG code=stack->Parameters.DeviceIoControl.IoControlCode;
        const ULONG in=stack->Parameters.DeviceIoControl.InputBufferLength,out=stack->Parameters.DeviceIoControl.OutputBufferLength;
        void* data=irp->AssociatedIrp.SystemBuffer;
        if(device!=controlDevice||!online){result=STATUS_DEVICE_NOT_READY;break;}
        if(code==SES_IOCTL_CONNECT){
            if(in!=sizeof(SesDriverHello)||out!=sizeof(SesDriverStatus)||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(owner&&owner!=stack->FileObject){result=STATUS_SHARING_VIOLATION;break;}
            const auto hello=*static_cast<SesDriverHello*>(data);
            if(!ring.connect(hello,millis())){result=STATUS_REVISION_MISMATCH;break;}
            owner=stack->FileObject;*static_cast<SesDriverStatus*>(data)=ring.status();information=sizeof(SesDriverStatus);result=STATUS_SUCCESS;
        }else if(code==SES_IOCTL_WRITE){
            if(in!=sizeof(SesDriverPacket)||out!=0||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(!owner||owner!=stack->FileObject){result=STATUS_ACCESS_DENIED;break;}
            result=ring.push(*static_cast<SesDriverPacket*>(data),millis())?STATUS_SUCCESS:STATUS_INVALID_PARAMETER;
        }else if(code==SES_IOCTL_STATUS){
            if(in!=0||out!=sizeof(SesDriverStatus)||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(!owner||owner!=stack->FileObject){result=STATUS_ACCESS_DENIED;break;}
            *static_cast<SesDriverStatus*>(data)=ring.status();information=sizeof(SesDriverStatus);result=STATUS_SUCCESS;
        }
        break;
    }
    default:break;
    }
    KeReleaseSpinLock(&lock,irql);return complete(irp,result,information);
}
}
NTSTATUS SesBridgeInitialize(PDRIVER_OBJECT driver){
    KeInitializeSpinLock(&lock);bridgeDriver=driver;
    const UCHAR majors[]={IRP_MJ_CREATE,IRP_MJ_CLEANUP,IRP_MJ_CLOSE,IRP_MJ_DEVICE_CONTROL};
    for(UCHAR major: majors){
        // WDM PortCls dispatch interposition for our own private control device.
        #pragma warning(suppress:28175)
        previous[major]=driver->MajorFunction[major];
        #pragma warning(suppress:28175)
        driver->MajorFunction[major]=dispatch;
    }
    return STATUS_SUCCESS;
}
NTSTATUS SesBridgeStart(PDEVICE_OBJECT adapter){
    // PnP serializes START/STOP/REMOVE for one FDO. A second FDO must fail
    // before its capture filters are installed, because the ring is singleton.
    KIRQL irql;KeAcquireSpinLock(&lock,&irql);
    if(adapterDevice&&adapterDevice!=adapter){KeReleaseSpinLock(&lock,irql);return STATUS_DEVICE_BUSY;}
    if(controlDevice){online=FALSE;ring.disconnect();owner=nullptr;KeReleaseSpinLock(&lock,irql);return STATUS_SUCCESS;}
    adapterDevice=adapter;KeReleaseSpinLock(&lock,irql);
    UNICODE_STRING name,link,security;
    RtlInitUnicodeString(&name,L"\\Device\\SesMicrophone");RtlInitUnicodeString(&link,L"\\DosDevices\\SesMicrophone");
    // Interactive users can produce audio without elevation; no network/service users.
    RtlInitUnicodeString(&security,L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)");
    PDEVICE_OBJECT created=nullptr;
    NTSTATUS status=IoCreateDeviceSecure(bridgeDriver,sizeof(ControlExtension),&name,SES_DRIVER_DEVICE_TYPE,FILE_DEVICE_SECURE_OPEN,FALSE,&security,&controlClass,&created);
    if(NT_SUCCESS(status)){
        static_cast<ControlExtension*>(created->DeviceExtension)->signature=controlSignature;
        status=IoCreateSymbolicLink(&link,&name);
        if(!NT_SUCCESS(status))IoDeleteDevice(created);
    }
    KeAcquireSpinLock(&lock,&irql);
    if(NT_SUCCESS(status))controlDevice=created;else adapterDevice=nullptr;
    KeReleaseSpinLock(&lock,irql);
    if(NT_SUCCESS(status)){created->Flags|=DO_BUFFERED_IO;created->Flags&=~DO_DEVICE_INITIALIZING;}
    return status;
}
void SesBridgeOnline(PDEVICE_OBJECT adapter,BOOLEAN value){KIRQL irql;KeAcquireSpinLock(&lock,&irql);if(adapter==adapterDevice){online=value;ring.disconnect();owner=nullptr;}KeReleaseSpinLock(&lock,irql);}
void SesBridgeRemove(PDEVICE_OBJECT adapter){
    PDEVICE_OBJECT deleted=nullptr;KIRQL irql;KeAcquireSpinLock(&lock,&irql);
    if(adapter==adapterDevice){online=FALSE;ring.disconnect();owner=nullptr;deleted=controlDevice;controlDevice=nullptr;adapterDevice=nullptr;}
    KeReleaseSpinLock(&lock,irql);
    // IoDeleteDevice marks an open CDO delete-pending; existing references keep
    // it alive until cleanup/close. Neither operation runs under the spinlock.
    if(deleted){UNICODE_STRING link;RtlInitUnicodeString(&link,L"\\DosDevices\\SesMicrophone");IoDeleteSymbolicLink(&link);IoDeleteDevice(deleted);}
}
void SesBridgeShutdown(){if(adapterDevice)SesBridgeRemove(adapterDevice);}
void SesBridgeCapture(void* buffer,ULONG bytes,ULONG bits){
    if(!buffer||!(bits==16||bits==32))return;
    // Never hold a spinlock for more than one 10ms block. Caller owns the DMA buffer.
    auto* output=static_cast<UCHAR*>(buffer);ULONG frames=bytes/(bits/8);
    while(frames){ULONG chunk=frames>480?480:frames;KIRQL irql;KeAcquireSpinLock(&lock,&irql);ring.pull(output,chunk,bits,millis());KeReleaseSpinLock(&lock,irql);output+=chunk*(bits/8);frames-=chunk;}
}
