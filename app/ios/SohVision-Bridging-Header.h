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
