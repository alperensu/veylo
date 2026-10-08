#pragma once
#include <ntddk.h>
NTSTATUS SesBridgeInitialize(PDRIVER_OBJECT driver);
void SesBridgeShutdown();
void SesBridgeOnline(BOOLEAN online);
void SesBridgeCapture(void* buffer,ULONG bytes,ULONG bits);
