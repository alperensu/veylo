#include "bridge.h"
#include <wdmsec.h>
#include "pcm_ring.h"
#include "capture_diagnostics.h"
namespace {
PDEVICE_OBJECT controlDevice=nullptr;
PDEVICE_OBJECT adapterDevice=nullptr;
PDRIVER_OBJECT bridgeDriver=nullptr;
struct ControlExtension {ULONG signature;};
constexpr ULONG controlSignature=0x53455343;
PDRIVER_DISPATCH previous[IRP_MJ_MAXIMUM_FUNCTION+1]{};
KSPIN_LOCK lock;
ses_driver::PcmRing ring{};
ses_driver::CaptureDiagnostics diagnostics{};
PFILE_OBJECT owner=nullptr;
BOOLEAN online=FALSE;
uint64_t sourceGeneration=1;
bool sourceExpired=false;
void advanceGeneration(){++sourceGeneration;if(!sourceGeneration)sourceGeneration=1;}
constexpr GUID controlClass={0x7cef8f0e,0x8352,0x4b91,{0xa7,0x1d,0x8d,0x3b,0x1b,0xa4,0xdd,0xfe}};
uint64_t millis(){return KeQueryInterruptTime()/10000;}
// Called only under the bridge lock. Timeout invalidates retained private PCM
// even if no stream pull or subsequent producer request has happened yet.
void expireSource(){if(owner&&ring.attached&&!sourceExpired&&millis()-ring.last_ms>SES_DRIVER_TIMEOUT_MS){ring.discard();sourceExpired=true;advanceGeneration();}}
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
    expireSource();
    switch(stack->MajorFunction){
    case IRP_MJ_CREATE:result=(device==controlDevice&&online)?STATUS_SUCCESS:STATUS_DEVICE_NOT_READY;break;
    case IRP_MJ_CLEANUP:
    case IRP_MJ_CLOSE:if(device==controlDevice&&owner==stack->FileObject){ring.disconnect();owner=nullptr;advanceGeneration();sourceExpired=false;}result=STATUS_SUCCESS;break;
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
            diagnostics.reset();
            advanceGeneration();sourceExpired=false;
            owner=stack->FileObject;*static_cast<SesDriverStatus*>(data)=ring.status();information=sizeof(SesDriverStatus);result=STATUS_SUCCESS;
        }else if(code==SES_IOCTL_WRITE){
            if(in!=sizeof(SesDriverPacket)||out!=0||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(!owner||owner!=stack->FileObject){result=STATUS_ACCESS_DENIED;break;}
            const uint64_t tick_hns=KeQueryInterruptTime();
            const bool pushed=ring.push(*static_cast<SesDriverPacket*>(data),tick_hns/10000);
            if(pushed){sourceExpired=false;diagnostics.successfulWrite(ring.attached,tick_hns);}
            result=pushed?STATUS_SUCCESS:STATUS_INVALID_PARAMETER;
        }else if(code==SES_IOCTL_STATUS){
            if(in!=0||out!=sizeof(SesDriverStatus)||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(!owner||owner!=stack->FileObject){result=STATUS_ACCESS_DENIED;break;}
            *static_cast<SesDriverStatus*>(data)=ring.status();information=sizeof(SesDriverStatus);result=STATUS_SUCCESS;
        }else if(code==SES_IOCTL_DIAGNOSTICS){
            if(in!=0||out!=sizeof(SesDriverDiagnostics)||!data){result=STATUS_INVALID_BUFFER_SIZE;break;}
            if(!owner||owner!=stack->FileObject||!ring.attached){result=STATUS_ACCESS_DENIED;break;}
            *static_cast<SesDriverDiagnostics*>(data)=diagnostics.snapshot();information=sizeof(SesDriverDiagnostics);result=STATUS_SUCCESS;
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
    if(controlDevice){online=FALSE;ring.disconnect();owner=nullptr;advanceGeneration();sourceExpired=false;KeReleaseSpinLock(&lock,irql);return STATUS_SUCCESS;}
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
void SesBridgeOnline(PDEVICE_OBJECT adapter,BOOLEAN value){KIRQL irql;KeAcquireSpinLock(&lock,&irql);if(adapter==adapterDevice){online=value;ring.disconnect();owner=nullptr;advanceGeneration();sourceExpired=false;}KeReleaseSpinLock(&lock,irql);}
void SesBridgeRemove(PDEVICE_OBJECT adapter){
    PDEVICE_OBJECT deleted=nullptr;KIRQL irql;KeAcquireSpinLock(&lock,&irql);
    if(adapter==adapterDevice){online=FALSE;ring.disconnect();owner=nullptr;advanceGeneration();sourceExpired=false;deleted=controlDevice;controlDevice=nullptr;adapterDevice=nullptr;}
    KeReleaseSpinLock(&lock,irql);
    // IoDeleteDevice marks an open CDO delete-pending; existing references keep
    // it alive until cleanup/close. Neither operation runs under the spinlock.
    if(deleted){UNICODE_STRING link;RtlInitUnicodeString(&link,L"\\DosDevices\\SesMicrophone");IoDeleteSymbolicLink(&link);IoDeleteDevice(deleted);}
}
void SesBridgeShutdown(){if(adapterDevice)SesBridgeRemove(adapterDevice);}
uint64_t SesBridgeGeneration(){KIRQL irql;KeAcquireSpinLock(&lock,&irql);expireSource();const uint64_t generation=sourceGeneration;KeReleaseSpinLock(&lock,irql);return generation;}
bool SesBridgePublish(uint64_t generation,void* destination,const void* source,ULONG bytes){
    if(!destination||!source||!bytes||bytes>19200)return false;
    KIRQL irql;KeAcquireSpinLock(&lock,&irql);expireSource();
    const bool valid=generation&&generation==sourceGeneration;
    if(valid)RtlCopyMemory(destination,source,bytes);
    KeReleaseSpinLock(&lock,irql);return valid;
}
void SesBridgeCapture(void* buffer,ULONG bytes,ULONG bits,uint64_t generation){
    if(!buffer||!(bits==16||bits==32))return;
    // Never hold a spinlock for more than one 10ms block. Caller owns the DMA buffer.
    auto* output=static_cast<UCHAR*>(buffer);ULONG frames=bytes/(bits/8);
    if(!frames)return;
    KIRQL irql;KeAcquireSpinLock(&lock,&irql);
    const uint64_t token=diagnostics.beginCapture(ring.attached,frames,ring.queued(),KeQueryInterruptTime());
    KeReleaseSpinLock(&lock,irql);
    while(frames){
        const ULONG chunk=frames>480?480:frames;KeAcquireSpinLock(&lock,&irql);
        expireSource();
        const auto before=ring.status();const bool primed_before=ring.primed;
        const uint64_t tick_hns=KeQueryInterruptTime();
        if(generation&&generation!=sourceGeneration)RtlZeroMemory(output,chunk*(bits/8));
        else ring.pull(output,chunk,bits,tick_hns/10000);
        diagnostics.pulled(token,ring.attached,primed_before,chunk,frames,tick_hns,before,ring.status());
        if(frames==chunk)diagnostics.endCapture(token,ring.attached,ring.queued());
        KeReleaseSpinLock(&lock,irql);output+=chunk*(bits/8);frames-=chunk;
    }
}
