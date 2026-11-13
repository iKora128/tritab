#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>

CF_IMPLICIT_BRIDGING_ENABLED

// MultitouchSupport.framework の非公開構造体（OpenMultitouchSupport の OpenMTInternal.h と同じレイアウト、96 bytes）
typedef struct {
    float x, y;
} MTBPoint;

typedef struct {
    MTBPoint position;
    MTBPoint velocity;
} MTBVector;

typedef struct {
    int frame;
    double timestamp;
    int pathIndex;
    int state;          // 0:NotTracking 1:StartInRange 2:HoverInRange 3:MakeTouch 4:Touching 5:BreakTouch 6:LingerInRange 7:OutOfRange
    int fingerID;
    int handID;
    MTBVector normalized; // 0..1、原点は左下
    float zTotal;
    int field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTBVector absolute;   // mm
    int field14;
    int field15;
    float zDensity;
} MTBTouch;

typedef void *MTBDeviceRef;
typedef void (*MTBFrameCallback)(MTBDeviceRef device, const MTBTouch *touches, int count, double timestamp, int frame);

/// フレームワークを読み込む。失敗したら false。
bool MTBLoad(void);
/// 接続中のマルチタッチデバイス一覧（内蔵 + Magic Trackpad）。
CFArrayRef MTBCreateDeviceList(void) CF_RETURNS_RETAINED;
void MTBRegister(MTBDeviceRef device, MTBFrameCallback callback);
void MTBUnregister(MTBDeviceRef device, MTBFrameCallback callback);
void MTBStart(MTBDeviceRef device);
void MTBStop(MTBDeviceRef device);

CF_IMPLICIT_BRIDGING_DISABLED
