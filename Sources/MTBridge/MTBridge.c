#include "MTBridge.h"
#include <dlfcn.h>

static void *handle = NULL;
static CFMutableArrayRef (*pCreateList)(void) = NULL;
static void (*pRegister)(MTBDeviceRef, MTBFrameCallback) = NULL;
static void (*pUnregister)(MTBDeviceRef, MTBFrameCallback) = NULL;
static void (*pStart)(MTBDeviceRef, int) = NULL;
static void (*pStop)(MTBDeviceRef) = NULL;

bool MTBLoad(void) {
    if (handle) return true;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return false;
    pCreateList = dlsym(h, "MTDeviceCreateList");
    pRegister   = dlsym(h, "MTRegisterContactFrameCallback");
    pUnregister = dlsym(h, "MTUnregisterContactFrameCallback");
    pStart      = dlsym(h, "MTDeviceStart");
    pStop       = dlsym(h, "MTDeviceStop");
    if (!pCreateList || !pRegister || !pUnregister || !pStart || !pStop) {
        dlclose(h);
        return false;
    }
    handle = h;
    return true;
}

CFArrayRef MTBCreateDeviceList(void) {
    if (!handle) return NULL;
    return pCreateList();
}

void MTBRegister(MTBDeviceRef device, MTBFrameCallback callback) {
    if (handle) pRegister(device, callback);
}

void MTBUnregister(MTBDeviceRef device, MTBFrameCallback callback) {
    if (handle) pUnregister(device, callback);
}

void MTBStart(MTBDeviceRef device) {
    if (handle) pStart(device, 0);
}

void MTBStop(MTBDeviceRef device) {
    if (handle) pStop(device);
}
