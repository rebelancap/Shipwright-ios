// SohSense.h — PSVR2 Sense controllers on visionOS: per-hand 6DoF poses,
// filtered linear AND angular velocity, and the six-input button taxonomy.
//
// This is Q-VR10's default hand source (VR-spec, STATUS.md), and it is the
// thing DONOR-MAP §8 is built on: the donor's whole motion-combat design leans
// on the runtime supplying a filtered linear and angular velocity per hand per
// sample, free of artificial locomotion.
//
// PROVENANCE. The discovery/authorization/load/provider ORDER is
// sm64coopdx-ios's shipped A10 recipe by way of SpaghettiKart-ios's
// `app/ios/SohSense.m`, ported rather than reinvented. Every deviation from
// that order cost one of those projects a device round, and the two scars worth
// naming here because they look like hardware faults:
//
//   1. WITHOUT the `GCSupportedGameControllers` = [{ProfileName:
//      "SpatialGamepad"}] Info.plist declaration, the OS hands the app a
//      COMPATIBILITY presentation in which the pair arrives as ONE aggregated
//      MFi gamepad. An aggregate virtual gamepad is not a trackable accessory,
//      so `ar_accessory_load_from_device` fails with error 1200 — which reads
//      exactly like "this hardware cannot be tracked" and is not.
//   2. `ar_accessory_load_from_device` takes a `GCDevice`, so it must run for
//      EVERY controller and must NOT sit behind the spatial-category gate. That
//      gate is the right one for "who drives the pad" and the wrong one for
//      "do poses exist"; put there, it means the pose question is never asked.
//
// WHAT IS OURS. The donor map (§8, "Verdict for PSVR2 Sense on Vision Pro")
// records velocity provenance as one of the two real risks: "vr_physics.cpp has
// a finite-difference fallback for LINEAR only, and both springs, passthrough
// and the visual lag consume angular, so we'd need to add quaternion
// differencing". Reading the visionOS 26 SDK rather than assuming, that risk is
// SMALLER than the map expected: `ar_accessory_anchor_get_angular_velocity`
// exists alongside `..._get_velocity`, both in rad/s and m/s in the ACCESSORY's
// LOCAL frame. So this file:
//
//   - prefers the runtime's own velocities, rotated into the ARKit origin frame
//     by the anchor's own rotation;
//   - DERIVES both anyway — linear by finite difference, angular by quaternion
//     differencing (`2 * vec(dq) / dt` for the small-angle part of
//     `q_now (x) conj(q_prev)`, hemisphere-corrected) — because the derived
//     path is what runs under injection in the simulator, and because having
//     both lets `vr hands` report them side by side as a live cross-check the
//     first headset session can read in one line;
//   - filters whichever is in force with a one-euro filter (velocity is the
//     input to a 5 m/s threshold, and unfiltered derived velocity over a
//     variable poll interval is noise at exactly that scale).
//
// SIMULATOR. There is no spatial hardware in the simulator: nothing adopts,
// nothing loads, the provider is never built, and the poll early-returns.
// `vr hands` says so rather than failing. Everything ABOVE the poses — the
// filter, the velocity derivation, the physics step, the swing detector, the
// pad merge — is fully exercised there through injection (`vr hand ...`), which
// is what makes the swing thresholds assertable without a headset.
#pragma once

#import <ARKit/ARKit.h>
#import <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { SOHSENSE_LEFT = 0, SOHSENSE_RIGHT = 1, SOHSENSE_HANDS = 2 };

// The donor's six-input taxonomy (DONOR-MAP §8 `padmgr.c`), which it records as
// mapping cleanly onto Sense. One vocabulary shared by the hardware read, the
// injection path and the dump, so a headless assert means what a headset means.
enum {
    SOHSENSE_BTN_PRIMARY = 1 << 0,   // Cross / Square      (donor PRIMARY)
    SOHSENSE_BTN_SECONDARY = 1 << 1, // Circle / Triangle   (donor SECONDARY)
    SOHSENSE_BTN_TRIGGER = 1 << 2,   // L2 / R2             (donor TRIGGER)
    SOHSENSE_BTN_GRIP = 1 << 3,      // L1 / R1             (donor GRIP)
    SOHSENSE_BTN_THUMBCLICK = 1 << 4,// thumbstick click    (donor THUMBCLICK)
    SOHSENSE_BTN_MENU = 1 << 5,      // Menu / Create       (donor MENU)
};

// --- lifecycle ---------------------------------------------------------------
void SohSense_Start(void); // discovery on
void SohSense_Stop(void);  // release everything, discovery off
// Once per VR frame, on the compositor thread, AFTER the head pose for this
// frame is known: polls anchors, reads buttons, derives and filters velocity.
void SohSense_Update(double presTime, simd_float4x4 originFromHead);

// R10 verdict 5: the same read, WITHOUT the tracking half. Buttons and sticks
// come from GameController and need no ARKit session, no head pose and no
// anchors -- so outside VR (the flat window, the 3D panel) this is the whole of
// what the Sense pair has to offer, and there is no reason for it to be
// unreachable there. Idempotently starts discovery if it is not already on.
// Safe to call from the game thread.
void SohSense_UpdateFlat(void);

// 1 while a Sense controller is connected or a hand pose is live (an injected
// hand counts — the harness must look exactly like hardware to everything
// downstream).
int SohSense_Active(void);
int SohSense_IsSpatialController(void* gcController);

// R9 part B: the predicate overlay 0052 calls from LUS to keep a spatial
// controller OUT of the SDL gamepad enumeration. `name` is
// SDL_JoystickNameForIndex(i), which on this platform is GCController.vendorName
// verbatim -- so the match is exact against the set the Sense registration fills
// at adoption, with a conservative substring fallback ("Sense", "PlayStation
// VR2") for the ordering where no connect notification has landed yet.
// the user, 1.0.1.12: "The right joystick is STILL sometimes triggering C
// buttons!" -- because SDL made each Sense unit a second, anonymous gamepad
// whose right stick IS the C-pad in SoH's default mapping.
int SohSense_IsSpatialControllerName(const char* name);
void SohSense_NoteSdlSpatialSkip(void);
int SohSense_SdlSpatialSkips(void);
int SohSense_SpatialNameCount(void);

// R9 part A: poses are published in the accessory's GRIP coordinate space
// (anchor x anchorFromGrip) when the runtime supplies one -- the origin is
// where the controller is HELD, not where its model's origin sits, so a wrist
// roll turns the hand in place instead of orbiting it. `vr set gripspace 0`
// falls back to the raw anchor.
// --- poses (ARKit ORIGIN frame — the same frame as the head pose the VR loop
// queries, so there is no conversion anywhere between them) -------------------
int SohSense_HandPose(int hand, simd_float4x4* outOriginFromHand);
// Pose + velocities in one read, so the physics step cannot straddle two polls.
// `outVel` m/s and `outAngVel` rad/s are both in the ORIGIN frame.
int SohSense_HandMotion(int hand, simd_float4x4* outOriginFromHand, simd_float3* outVel, simd_float3* outAngVel);
// R15: the accessory's AIM location (anchor x anchorFromAim), ORIGIN frame.
// `outSrc`: 0 = the runtime gave the identity (anchor is the aim), 1 = a real
// aim transform, 3 = injected. Returns 0 until the runtime has answered.
int SohSense_HandAimPose(int hand, simd_float4x4* outOriginFromAim, int* outSrc);
void SohSense_InjectAim(int hand, float x, float y, float z, float qx, float qy, float qz, float qw);
unsigned int SohSense_HandButtons(int hand);
void SohSense_HandStick(int hand, float* outX, float* outY);

// --- tunables (`vr set` keys; the filter constants live here too) ------------
int SohSense_SetTunable(const char* key, float value); // 1 = key known
float SohSense_GetTunable(const char* key);

// --- injection (the simulator harness; see the header note) ------------------
void SohSense_InjectHand(int hand, float x, float y, float z, float qx, float qy, float qz, float qw);
void SohSense_InjectHandEuler(int hand, float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg);
// R9 part A: the accessory's anchor->grip translation, which the simulator has
// no hardware to supply. Injecting it is what makes the grip composition (and
// therefore the roll-orbit assertion) exercisable off a headset.
void SohSense_InjectGrip(int hand, float x, float y, float z);
void SohSense_InjectVelocity(int hand, float vx, float vy, float vz);
void SohSense_InjectAngVelocity(int hand, float wx, float wy, float wz);
void SohSense_InjectButton(int hand, const char* name, int down);
void SohSense_InjectStick(int hand, float x, float y);
void SohSense_InjectClear(void);
void SohSense_InjectDoff(void); // "both controllers went away"

// --- haptics (VR R5) ---------------------------------------------------------
// One transient pulse on one hand. `intensity` and `sharpness` are CoreHaptics'
// own 0..1 parameters; `durationS` is clamped to [0.005, 0.5] s.
//
// The donor pulses on tier changes, shield blocks and cut drag (DONOR-MAP 8);
// ours fires on the three events a player can attribute to a cause -- a sword
// hit, a shield block, and the blade stopping against a wall -- because a pulse
// you cannot attribute reads as a controller fault.
//
// SILENT NO-OP when the controller has no haptics engine, which is every
// simulator run: `SohSense_HapticCount()` is what the suite asserts on instead,
// and it counts REQUESTS, not felt pulses. That distinction is the honest one
// and it is the reason the counter exists.
void SohSense_Haptic(int hand, float intensity, float sharpness, float durationS);
unsigned int SohSense_HapticCount(void);

// --- dump --------------------------------------------------------------------
const char* SohSense_Dump(void);

#ifdef __cplusplus
}
#endif
