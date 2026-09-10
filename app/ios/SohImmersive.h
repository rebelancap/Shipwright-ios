// SohImmersive.h — visionOS stereoscopic "3D screen" mode (CompositorServices).
// Ported from the proven vkQuake-ios implementation (its VKQImmersive.m, itself
// descended from quake3e-ios D-019). See Shipwright-ios D-030.
#pragma once

#import <CompositorServices/CompositorServices.h>
#import <Foundation/Foundation.h>

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
// R1 depth handoff (spec D2): the same eye's DEPTH texture (Depth32Float,
// forward-Z as Fast3D renders it). NULL until the pair has been published.
void* Soh3D_GetEyeDepthMTLTexture(int eye);

// Shell reconcile when the system (Crown) dismisses the space out from under us.
void Soh3D_Immersive_Ended(void);

// --- VR mode (VR-spec D1/D2/D10, round R0) --------------------------------
// A SECOND immersive space (`SohVR`, plus two contract-probe siblings) with its
// own compositor loop. The shipped `Soh3D` space and its configuration are
// NEVER touched (spec D1: widening a space's immersion-style set broke
// present on the sibling port).

// The VR frame loop. Same dedicated-thread contract as Soh3D_Immersive_Run.
void SohVR_Immersive_Run(cp_layer_renderer_t layer_renderer);

extern volatile int gSohVRStop;
extern volatile int gSohVRRunning;

// R17 part B item 2(c): non-zero while EITHER immersive frame loop is live. The
// Swift CompositorLayer closure is invoked once per space activation and spawned
// a thread unconditionally; SohVR_Immersive_Run then set gSohVRStop = 0 and
// gSohVRRunning = 1 unconditionally on top of whatever was already running, so
// two loops could share one layerRenderer with neither able to see the other.
// The closure asks this first now, and refuses.
int SohVR_AnyLoopRunning(void);

// Which immersive space id the shell wants opened: 0 = "SohVR" (style set
// {mixed, full}, the shipping candidate), 1 = "SohVRTestA" (constant mixed),
// 2 = "SohVRTestB" (constant full). R0a compares all three against
// cp_drawable_encode_present.
int SohVR_SpaceVariant(void);
// 0 = mixed, 1 = full — the live selection for the SohVR variant only.
int SohVR_StyleIsFull(void);
// Non-zero while the shell is in VR mode (the Swift side picks the space id).
int SohVR_IsActive(void);

// Console-bridge command family (spec D10). `args` excludes the leading
// "vr" token. Returns one flat key=value reply line (or several, newline
// separated, for the bare `vr` dump).
NSString* SohVR_HandleCommand(NSArray<NSString*>* args);

// Enter/leave VR (mirrors Soh_Enter3D's sequencing; SohHostViewController.m).
void Soh_EnterVR(bool on);

// --- R1 -----------------------------------------------------------------------
// The active mode, as one tri-state (spec D1): 0 flat / 1 panel3D / 2 vr.
// This is the ONE authority the ornament, the console and the exit paths all
// read; `Soh_Get3DMode()` stays the engine's offscreen flag, which is set for
// BOTH immersive modes and therefore cannot distinguish them.
int Soh_GetMode(void);

// Manual recenter (spec D6, VR-DONOR-MAP §4f). Deliberately a NO-OP-style
// recenter: it zeroes the artificial yaw and re-seats the roomscale origin on
// the current head TRANSLATION, and captures nothing at all into steering —
// the donor's recorded "walking sideways" scar is exactly a captured steering
// offset rotating movement away from the look direction.
void SohVR_Recenter(void);

// Live VR tunables from the SwiftUI settings sheet (mirrors Soh3D_SetPanel).
// R8 item 4: EXPERIMENT ONLY -- the world scale is hardcoded at 34 units/m
// and nothing persists or pushes it. `vr set scale` is the only caller.
void SohVR_SetWorldScale(float unitsPerMetre);
// R8 item 5: the ONE height knob -- a signed trim in metres from the
// CALIBRATED state (eyes at Link's eye height), which is 0.0.
void SohVR_SetHeightTrim(float metres);
// R8 item 5: re-run that calibration. VR entry, every first-person
// re-entry, the manual recenter and the settings button all land here.
void SohVR_RecalibrateHeight(void);
// R9 part A item 2: which hand holds the sword. 0 = right (default), 1 = left.
// The SINGLE truth every consumer reads -- the drawn hands and their mirror,
// the physical blade, the parametric shield, the item wheel and the item
// trigger reservation all derive from gSohVRLeftHanded and nothing else.
void SohVR_SetLeftHanded(int on);
void SohVR_SetFlatWorldBackdrop(int on);
float SohVR_GetWorldScale(void);

// --- R2a ----------------------------------------------------------------------
// How VR treats a PRE-RENDERED (image-backed) room — Link's house, the Temple
// of Time, most interiors. 0 = panel (default: the room is a flat-screen
// context on the world-locked panel, showing the pre-rendered art as authored),
// 1 = flat (the backdrop is drawn per eye and is therefore glued to the head),
// 2 = 3d (SoH's own "Disable 2D Pre-Rendered Scenes" enhancement, which needs a
// 3D-backdrop MOD in Documents/mods — without one you get the bare placeholder
// mesh, which is the user's all-green Link's house on 1.0.1.1).
void SohVR_SetRoomMode(int mode);
int SohVR_GetRoomMode(void);
// Re-run the enhancement override for a room-mode change taken mid-session
// (SohHostViewController.m; main thread, no-op outside VR).
void SohVR_ReapplyRoomMode(void);

// R6 (spec D9): drop every recorded hand-matrix pointer. Called at both
// ends of a VR session -- the table holds raw graph-pool addresses that
// mean nothing once the session that recorded them is over.
void SohVR_ClearHandMtxTable(void);
// Eye render scale: multiplies the eye framebuffer derived from the drawable's
// own per-eye viewport (0.25 .. 2.0, default 1.0, on top of the long-edge
// budget). `vr set eyescale` / `vr set eyebudget` are the bridge equivalents.
void SohVR_SetEyeScale(float s);
float SohVR_GetEyeScale(void);

// --- R2b ----------------------------------------------------------------------
// FIRST PERSON is the only VR view (the user, 2026-09-03: third person removed —
// the 3D panel mode is the third-person experience). What remains tunable is
// the comfort surface around it.
//
// The HUD PLANE (spec D7): OoT's interface is TEXRECT output, identical
// pixels in both eyes, which under the headset's asymmetric frusta is two
// different world directions — it doubles. Rendered once into its own
// framebuffer and placed as a flat plane at a real distance, it fuses.
// `hudPlane = 0` puts it back on the world list, doubled, as the red control.
void SohVR_SetHudPlane(int on);
int SohVR_GetHudPlane(void);
void SohVR_SetHudWidth(float metres); // 0.2 .. 6, default 2.0; height is 4:3
// R8 item 7: the HUD's HEIGHT above eye level, metres, signed. With Size
// these are the only two HUD settings; the distance is fixed at 2.0 m.
void SohVR_SetHudUp(float metres);
float SohVR_GetHudWidth(void);
// R7 verdict 2 (the user, 2026-09-04): the per-hand grip->hand calibration. The
// offset is in CENTIMETRES in the controller's own frame (z negative = forward,
// away from you); the rotation is in DEGREES, applied Ry * Rp * Rr about the
// controller's own axes. hand: 0 = left, 1 = right.
// R7 verdict 5 / R8 item 8: the BACKFLIP/ROLL camera. Default ON. The VR view
// somersaults with Link through a lock-on backflip (backward) and through his
// forward roll (forward, over the roll animation's own duration). One toggle
// covers both, because they are one behaviour. Off keeps the head level.
void SohVR_SetFlipCam(int on);
int SohVR_GetFlipCam(void);
// R11 verdict 2: the shipped per-CONFIGURATION calibration defaults, so the
// settings sheet does not repeat them. config 0 = right-handed (sword right),
// 1 = left-handed; hand 0 = the LEFT controller; idx 0..2 = the stored offset in
// cm (x across, y up, z the NEGATION of the slider's "Forward"), 3..5 = yaw,
// pitch, roll in degrees.
float SohVR_HandCalDefault(int config, int hand, int idx);
void SohVR_SetHandOffset(int hand, float xCm, float yCm, float zCm);
void SohVR_SetHandRotation(int hand, float yawDeg, float pitchDeg, float rollDeg);
// --- R12 item 4: THE HELD-ITEM CORRECTION -----------------------------------
// Per PLAYER_MODELTYPE_* (0..15, which names the hand+item mesh and therefore
// also which of Link's hands it is) and per configuration (0 = sword right).
// idx 0..2 = yaw, pitch, roll in degrees; 3..5 = an offset in GAME UNITS.
// See the block beside gSohVRItemRotDeg in SohIosShell.m for why this is keyed
// by the mesh rather than by the item action.
#define SOHVR_ITEMCAL_N 16
float SohVR_ItemCalDefault(int config, int model, int idx);
void SohVR_SetItemCal(int config, int model, int idx, float v);
// The model type each VR hand is drawing right now (-1 = none), so the settings
// sheet can name what is in the hand while it is being dialled. 0 = left
// controller.
int SohVR_HeldModel(int hand);
// A stable short name for a model type, for the console and the settings sheet.
const char* SohVR_ItemCalName(int model);
// A human-facing label for the settings sheet ("Bow / Slingshot").
const char* SohVR_ItemCalLabel(int model);
// --- R14 item 2 / R17 item 4: THE AIM TRIMS ---------------------------------
// Yaw and pitch trims on the composed aim direction. R14 keyed them by mesh
// slot; R17 adds ONE row past the slots for the SLINGSHOT, because the bow and
// the slingshot are one mesh (Q-VR30) and the user's numbers for them differ.
// The row is chosen inside Player_VrAimHeld by heldItemAction and published as
// gSohVRAimTrimRow. idx 0 = yaw, 1 = pitch, degrees.
//
// R17 item 5: the SETTINGS SECTION IS GONE -- the user, on 1.0.1.21: "you can
// remove all calibration settings now, we have them dialed." The numbers are
// frozen in kSohVRAimTrim in SohIosShell.m and pushed by its constructor;
// `vr set aimyaw` / `aimpitch` remain as the engineering door.
#define SOHVR_AIMTRIM_SLINGSHOT SOHVR_ITEMCAL_N
#define SOHVR_AIMTRIM_N (SOHVR_ITEMCAL_N + 1)
float SohVR_AimTrim(int config, int model, int idx);
void SohVR_SetAimTrim(int config, int model, int idx, float v);
void SohVR_SetAimReticle(int on); // R15: the aim crosshair option (KEPT)
// Which row a console dial writes: the row the aim last READ, else an aimable
// item in a hand, else the bow/slingshot slot.
int SohVR_AimTrimModel(void);
// A stable short name for a trim row -- the mesh names plus "slingshot".
const char* SohVR_AimTrimName(int row);
// The live read-out: -1 no bow drawn yet this run, 1 the last nocked frame
// aimed from the HAND, 0 it fell back to vanilla. And one count per released
// projectile, by path (vanilla != 0 selects the vanilla counter).
int SohVR_AimPath(void);
int SohVR_AimShots(int vanilla);
// TURNING (spec D6, DONOR-MAP §4c). ONE knob, ONE primitive, two styles:
// 0 degrees = SMOOTH (the default, and the leftmost stop of the settings
// slider); any other value is the snap angle in degrees. Both pivot on the LIVE
// head so the player stays standing where they are, and neither touches the pad
// — overlay 0039 rev3 owns the right stick at the one merged snapshot.
void SohVR_SetTurnDegrees(float deg); // 0 = smooth, else 15..90
float SohVR_GetTurnDegrees(void);
void SohVR_SetSmoothTurnSpeed(float degPerSec); // 30..360, default 120 (donor)
float SohVR_GetSmoothTurnSpeed(void);
// LINK'S BODY (spec D4, DONOR-MAP §3 "Link's body"). hideBody = the donor's
// gVrHideBody, default 1: every limb except the two hands is hidden, because a
// full body in first person reads as wrong and looking down or behind you shows
// the inside of a torso. bodyFollowsHead = the donor's gVrBodyFollowsHead,
// default 1: Link's body faces where you look, so you can never see your own
// back. R8 item 9: lockOnFraming (the donor's gVrLegaiaLockOn) is REMOVED --
// it rotated the player's view for them, and R7 verdict 5 showed what the
// option cost even while it shipped off. R8 item 6: hideBody is no longer a
// setting either. It stays hardcoded at 1, because the alternative is the
// camera inside Link's body while he moves, and that is the eye anchoring on
// the actor ROOT rather than on the animated head bone -- a deliberate
// anti-nausea choice, not something a toggle can fix.
void SohVR_SetHideBody(int on);
int SohVR_GetHideBody(void);
void SohVR_SetBodyFollowsHead(int on);
int SohVR_GetBodyFollowsHead(void);
// Eye-height trim in GAME UNITS on top of Player_GetHeight (the donor's
// gVrHeadHeightOffset, default -9: 44-9 = 35 units as a child, which is 1.00 m
// at the spec's 35 units/m, and 59 = 1.69 m as an adult).
float SohVR_GetEyeHeightOffset(void);
// Eye render budget: the long-edge clamp on the drawable-derived eye extent.
// Default 4096 (measured on device: 13.4 Mpix/eye held 60 fps).
void SohVR_SetEyeBudget(float px);
float SohVR_GetEyeBudget(void);

#ifdef __cplusplus
}
#endif
