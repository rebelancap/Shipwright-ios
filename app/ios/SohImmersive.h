// SohImmersive.h — visionOS stereoscopic "3D screen" mode (CompositorServices).
// Ported from the proven vkQuake-ios implementation (its VKQImmersive.m, itself
// descended from quake3e-ios D-019). See Shipwright-ios D-030.
#pragma once

#import <CompositorServices/CompositorServices.h>

#ifdef __cplusplus
extern "C" {
#endif

// The frame loop. Runs on a DEDICATED thread (main thread would block the
// engine's display-link pump). Returns when stopped or the layer invalidates.
void Soh3D_Immersive_Run(cp_layer_renderer_t layer_renderer);

// Stop/running handshake: set stop, then wait for running==0 BEFORE dismissing
// the immersive space (the loop must never touch a layerRenderer SwiftUI is
// tearing down).
extern volatile int gSoh3DStop;
extern volatile int gSoh3DRunning;

// Panel placement + tuning (live; called from settings and enter sequencing).
void Soh3D_SetPanel(float dist, float halfW, float halfH);
void Soh3D_SetHeight(float h);
void Soh3D_SetDim(float dim); // 0..1 UI scale; perceptual curve applied inside
void Soh3D_Recenter(void);    // re-capture the head anchor next tracked frame

// Engine bridge (Fast3D overlay; NULL/0 until the eye framebuffers exist —
// the loop shows a built-in test pattern so the compositor path is testable
// before the engine side lands).
void* Soh3D_GetEyeMTLTexture(int eye); // 1=left, 2=right; NULL = not ready
int Soh3D_GetEyeFrames(int eye);       // completed renders per eye (liveness)

// Shell reconcile when the system (Crown) dismisses the space out from under us.
void Soh3D_Immersive_Ended(void);

#ifdef __cplusplus
}
#endif
