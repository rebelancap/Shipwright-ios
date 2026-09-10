// SohVision-Bridging-Header.h — ObjC/C surface exposed to SohVisionApp.swift.
#pragma once

#import "SohImmersive.h"
#import "SohHostViewController.h"

#ifdef __cplusplus
extern "C"
#endif
void Soh3D_SetStereoParams(float sep, float conv);
#ifdef __cplusplus
extern "C"
#endif
void SohIos_ToggleMenuKey(void);
#ifdef __cplusplus
extern "C"
#endif
void SohIos_SetAudioAnchorStatus(int s);
#ifdef __cplusplus
extern "C"
#endif
void SohIos_SetVrTransition(int on);
// R17 part B item 2(a): the immersive path's line into Documents/vr-mem.log.
// Swift's own NSLogs in this path are invisible once the headset is off.
#ifdef __cplusplus
extern "C"
#endif
void SohIos_VrNote(const char* what, const char* detail);
