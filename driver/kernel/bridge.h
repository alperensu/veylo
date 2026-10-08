#pragma once
#include <ntddk.h>
NTSTATUS SesBridgeInitialize(PDRIVER_OBJECT driver);
NTSTATUS SesBridgeStart(PDEVICE_OBJECT adapter);
void SesBridgeShutdown();
void SesBridgeOnline(PDEVICE_OBJECT adapter,BOOLEAN online);
void SesBridgeRemove(PDEVICE_OBJECT adapter);
void SesBridgeCapture(void* buffer,ULONG bytes,ULONG bits);
