#pragma once
#include <ntddk.h>
#include "ses_driver_protocol.h"
NTSTATUS SesBridgeInitialize(PDRIVER_OBJECT driver);
NTSTATUS SesBridgeStart(PDEVICE_OBJECT adapter);
void SesBridgeShutdown();
void SesBridgeOnline(PDEVICE_OBJECT adapter,BOOLEAN online);
void SesBridgeRemove(PDEVICE_OBJECT adapter);
uint64_t SesBridgeGeneration();
bool SesBridgePublish(uint64_t generation,void* destination,const void* source,ULONG bytes);
void SesBridgeCapture(void* buffer,ULONG bytes,ULONG bits,uint64_t generation=0);
