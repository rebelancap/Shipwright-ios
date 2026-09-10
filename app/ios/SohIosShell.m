// SohIosShell — grafts the iOS app shell onto SDL's UIWindow.
// v1: ensure landscape (insurance — the app is already landscape via the plist
// + SDL orientation hint; this nudges the scene if it ever starts portrait).
// The on-screen touch-control overlay is added in a later revision. Compiled
// into the soh target (ARC on). LUS calls SohIos_OnWindowCreated after
// SDL_CreateWindow.
//
// NOTE: on the iOS Simulator the device *bezel window* may display the app
// rotated (a cosmetic simulator quirk); `xcrun simctl io <udid> screenshot`
// captures the true landscape framebuffer and is the verification source.
#import <GameController/GameController.h>
#include <dlfcn.h> // R17 part B: dladdr, to name a terminating C++ exception
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
UIView* SohIos_FindMetalViewIn(UIView* v);
UIView* SohIos_FindMetalView(UIWindow* w);
void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene);
void SohIos_ForceViewChainAdopt(void);
static UIWindow* SohIos_GameWindowWithMetal(UIView** outMv);
#if TARGET_OS_VISION
extern volatile float gSohIosVisionLongEdge;
// R10 verdict 5: the Sense pair's flat-mode pump reads through this. Only the
// visionOS target compiles SohSense.m.
#import "SohSense.h"
#endif
// Written by gfx_metal's command-buffer completed handler (overlay 0028).
volatile float gSohIosGpuMs = 0;
// Cached on the main thread each poll; the bridge reads these (dispatch_sync
// from the bridge thread deadlocks — the game loop owns the main thread).
static volatile float gSohIosDrawableW = 0, gSohIosDrawableH = 0, gSohIosContentsScale = 0;

// D-030 stereo (visionOS): engine-visible 3D state. Defined HERE (this file is
// compiled on iPhone too) so the Fast3D overlay's strong externs always
// resolve; on iPhone the mode simply never leaves 0. The host VC (visionOS
// target only) flips the mode; the LUS eye passes publish the textures.
volatile int gSoh3DMode = 0;
// R2b: slot 2 is the HUD plane (spec D7) — see gSoh3DEyeDepthTexture.
void* volatile gSoh3DEyeTexture[3] = { NULL, NULL, NULL };
volatile int gSoh3DEyeFrames[2] = { 0, 0 };
volatile int gSoh3DEyeW = 0, gSoh3DEyeH = 0; // 0 = engine default (3840x2160)
volatile float gSoh3DCamDist = 0;            // 0032: camera-to-focus, per frame
volatile float gSoh3DCamP00 = 1.0f;          // 0032 v2: cot(fovx/2)
volatile float gSoh3DCamRight[3] = { 1, 0, 0 };
volatile float gSoh3DCamFwd[3] = { 0, 0, -1 };
volatile float gSoh3DCamEye[3] = { 0, 0, 0 };
volatile float gSoh3DDbgConv = 0, gSoh3DDbgSep = 0; // live stereo telemetry
volatile int gSoh3DPaused = 0;                       // 0032 v3: Kaleido open
volatile int gSoh3DAiming = 0;                       // 0032 v4: first-person/aim cam
volatile int gSoh3DInPlay = 0;                       // 0032 v5: gameplay view active
volatile int gSoh3DDbgMenuVis = 0, gSoh3DDbgMenuBuilds = 0; // 3D menu telemetry
volatile int gSoh3DDbgMenuVtx = 0, gSoh3DDbgMenuDraws = 0;  // draw-data + guard-pass
volatile int gSohAudioAnchorStatus = 0;              // spatial anchor: 1 ok / 2 threw
volatile int gSoh3DDbg2DW = 0, gSoh3DDbg2DH = 0;     // engine 2D dims (fill bug)
volatile int gSoh3DDbgCurW = 0, gSoh3DDbgCurH = 0;   // interpreter mCurDimensions (crop diag)

// VR-spec D1/D2 (round R0): VR mode state. Defined HERE for the same reason
// as the gSoh3D family above — SohIosShell.m is compiled on iPhone too, so the
// Fast3D overlay's strong externs always resolve and the mode simply never
// leaves 0 there. gSohVREyeVP holds the shell-composed per-eye A.V.P matrix in
// Fast3D's ROW-VECTOR order (row i, col j at [i*4+j]); overlay 0031 rev12
// substitutes it for the game's combined view*projection at the MP sites.
volatile int gSohVRMode = 0;
volatile int gSohVREyeVPValid = 0;
// R1: DOUBLE-BUFFERED [slot][eye][16]. The compositor thread writes the slot
// the engine is not reading and only then publishes gSohVRPoseSeq; the engine
// latches that seq (and therefore the slot) ONCE per two-eye pair. Without the
// double buffer a live pose tears across the two interpreter walks.
volatile float gSohVREyeVP[2][2][16] = { { { 0 } }, { { 0 } } };
// R19 part B: the per-eye TANGENTS of the compositor's own frustum, in the
// order L, R, B, T, exactly as sohvr_contract carries them. The game side needs
// them for one reason: a HEAD-LOCKED WORLD QUAD (overlay 0055 rev2's lens mask)
// has to know how wide the eye's field actually is to reproduce vanilla's
// proportion of it, and NDC (0,0) is not the gaze axis on this device -- the
// frusta are asymmetric (measured: tanL -1.7321, tanR 1.0 on the left eye), so
// a screen-space rect centred on the field is off-axis in opposite directions
// per eye. That is exactly why the user saw TWO circles. Not double-buffered: it
// is a property of the display, and it changes only when the compositor hands
// us a different view (which sohvr_contract's tan_changes counter already
// watches).
volatile float gSohVREyeTan[2][4] = { { -1.0f, 1.0f, -1.0f, 1.0f }, { -1.0f, 1.0f, -1.0f, 1.0f } };
volatile unsigned int gSohVRPoseSeq = 0;   // shell -> engine: pose generation
volatile unsigned int gSohVREyeSeqDone = 0; // engine -> shell: pair rendered
volatile int gSohVRPairSlot = 0;            // latched by 0031 for the pair
volatile int gSohVRPairFlat = 0;            // latched by 0031 for the pair
// R2a (trap D35): the tag the engine stamps on BOTH eye textures of a pair, so
// the compositor can tell a coherent stereo frame from two eyes rendered for
// two different head poses. Latched with the slot by 0031 rev14 and carried
// into each eye's GPU completion handler.
volatile unsigned int gSohVRPairTag = 0;
volatile unsigned int gSoh3DEyeTag[3] = { 0, 0, 0 };
// R2a: how VR treats a pre-rendered (image-backed) room. 0 panel / 1 flat /
// 2 3d — see SohImmersive.h. Read by overlay 0039 rev2 (the flat-screen latch)
// and overlay 0040 rev2 (the 3DSceneRender enhancement gate). Defined here for
// the same reason as the rest of the family: SohIosShell.m is compiled on
// iPhone too, so the overlay's strong externs always resolve and the mode
// simply never leaves 0 there.
volatile int gSohVRRoomMode = 0;
volatile int gSohVRRoomImage = 0; // diagnostics: the live room-shape test
// R16 part B: the OTHER arm of the same latch — a fixed-camera region of a town
// scene (overlay 0039 rev9). Published beside the room test so `vr room` says
// which arm made the frame a panel; debounced on the game side.
volatile int gSohVRRoomFixedCam = 0;

// VR camera unification (spec D5, overlay 0037). The engine exports the
// GAME camera's own basis (Anchor*) BEFORE it overwrites the view; the shell
// seats VR's A matrix on that and pushes the composed head pose back through
// Cam*. Anchoring on the written-back view instead would chase our own HMD
// offset in a feedback loop — the donor records the same trap.
volatile int gSohVRAnchorValid = 0;
volatile float gSohVRAnchorEye[3] = { 0, 0, 0 };
volatile float gSohVRAnchorFwd[3] = { 0, 0, -1 };
volatile int gSohVRCamValid = 0;
volatile float gSohVRCamEye[3] = { 0, 0, 0 };
volatile float gSohVRCamFwd[3] = { 0, 0, -1 };
volatile float gSohVRCamUp[3] = { 0, 1, 0 };
volatile float gSohVRCamFovy = 100.0f;

// Flat-screen context (spec D3, overlay 0039): latched at the tick boundary
// before the DL is built; gSohVRFlatRaw is the live value, diagnostics only.
volatile int gSohVRFlatLatch = 0;
volatile int gSohVRFlatRaw = 0;

// Sim-rate correctness (spec D8, overlay 0040): the MEASURED headset
// refresh, which GetInterpolationFPS() divides by OoT's native 20 Hz.
volatile int gSohVRRefreshHz = 0;

// R1 depth handoff (spec D2 / D-044): the eye framebuffer's depth texture,
// published beside its colour texture by 0031 rev13.
// R2b: THREE slots — 0 and 1 are the eyes, 2 is the HUD plane (spec D7),
// published through exactly the same GPU-completion machinery so it can never
// be sampled mid-frame either.
void* volatile gSoh3DEyeDepthTexture[3] = { NULL, NULL, NULL };

// --- VR R2b -------------------------------------------------------------------
// FIRST PERSON (spec D4, overlay 0041). The anchor is a GAME quantity —
// actor root plus eye height, sampled at the tick boundary — so the engine
// publishes it and the shell seats VR's A matrix on it. gSohVRFpActive is the
// authority the steering table (overlay 0042) and the limb cull read; it is
// raised only inside VR, only in a non-flat frame, and only when the far-camera
// guard has not withdrawn the anchor.
volatile int gSohVRFpActive = 0;
volatile int gSohVRFpFar = 0;      // the 1200-unit director's-camera fallback
volatile int gSohVRFpEntered = 0;  // rising-edge counter: recenter on entry
// R16 part B: first person coming BACK after this block suspended it (the flat
// latch — a pause, a panel room — or the far-camera fallback). Counted apart
// from a genuine entry because rev1 counted them together, and the shell zeroed
// the artificial yaw on that counter: every unpause turned the wearer to face
// the game's -Z. Neither counter touches the yaw now.
volatile int gSohVRFpResumed = 0;
volatile float gSohVRFpAnchor[3] = { 0, 0, 0 };
volatile float gSohVRFpEyeHeight = 0.0f; // STANDING height, for world-scale work
volatile int gSohVRFpBodyYaw = 0;        // Link's shape.rot.y, binang
// Donor-tuned constants, live so the headset can sweep them without a build.
volatile float gSohVRHeadHeightOffset = -9.0f; // donor gVrHeadHeightOffset
volatile float gSohVRHeadOffsetFwd = 6.0f;     // donor gVrHeadOffsetForward
volatile float gSohVRFpFallbackDist = 1200.0f; // donor gVrFpFallbackDist

// STEERING (spec D6, overlay 0042): the head yaw as a GAME binang, published
// by the shell as atan2(fwd.x, fwd.z) of the horizontally-projected head
// forward. Game yaw 0 faces +Z and movement is sin->x cos->z, so this IS the
// game convention with no conversion — the donor records an Euler extraction
// with fudge constants that skewed steering ~15 degrees when pitched.
volatile int gSohVRHeadingValid = 0;
volatile int gSohVRHeadingYaw = 0;

// --- VR R3 --------------------------------------------------------------------
// TURNING (spec D6, DONOR-MAP §4c). R2b ran a snap-turn edge detector on the
// GAME thread and handed the shell a request counter; that second latch over the
// same pad snapshot is what wedged the user's controller on 1.0.1.3, and a 20 Hz
// tick has no honest dt for smooth turning anyway. R3: overlay 0041 rev2
// publishes the right stick as a LEVEL and the shell owns the one edge detector
// and the one integrator, on the loop thread, pivoting on the LIVE head.
volatile float gSohVRTurnAxis = 0.0f;

// BODY + DIRECT MOVEMENT (spec D4, overlay 0042 rev2, DONOR-MAP §3 "Link's
// body" + §4b). Donor defaults, verbatim: gVrHideBody 1 (every limb except the
// hands is hidden — a full body in first person "mostly reads as wrong", and
// looking down or behind you shows the inside of a torso), gVrBodyFollowsHead 1
// (Link's body faces where you look, so you can never see your own back), and
// gVrLegaiaLockOn 0 (lock-on framing rotates the player's view for them: the
// classic sickness trigger, so it ships off — spec scope, DONOR-MAP §4d).
volatile int gSohVRHideBody = 1;
volatile int gSohVRBodyFollowsHead = 1;
/* R8 item 9: gSohVRLockOn is GONE. "Turn the world toward a Z-target" was
 * Legaiaflame's lock-on FRAMING -- the comfort option that rotates the player's
 * view for them -- and R7 verdict 5 already showed what it cost: the facing
 * pin's correctness exclusion had been gated on it, so vanilla Z-targeting
 * could not strafe, hop or flip while it shipped off. the user's R8 ruling is to
 * remove the option outright rather than keep a setting nobody should turn on.
 * Player_VrZTargetActive -- vanilla's own lock-on, which owes nothing to any
 * CVar -- is untouched and is what the strafe/hop/backflip all ride. */

/* R8 item 8: THE FORWARD ROLL, published beside gSohVRHopKind. The backflip
 * camera follows an authored somersault BACKWARD; Link's forward roll
 * (Player_Action_Roll) is the same move in the opposite sense and the user asked
 * for the camera to follow it too. Two values because the camera needs both
 * halves: whether the roll is running, and how long the roll's own animation
 * says it lasts, so the view's revolution ends when the roll does instead of
 * on a constant somebody guessed. gSohVRRollSeconds is written once, at
 * Player_SetupRoll, from the animation's real end frame and play speed. */
volatile int gSohVRRollActive = 0;
volatile float gSohVRRollSeconds = 0.0f;
// Diagnostics for `vr fp`: proof on device that the facing pin and the
// kinematic override actually ran, rather than inferring it from feel.
volatile int gSohVRPinnedYaw = 0;
volatile int gSohVRDirectTicks = 0;
volatile int gSohVRKinematicTicks = 0;
// The pad the GAME sees this tick, and the C bits the right stick had set
// (overlay 0039 rev3). A turn that leaves pad_c_masked non-zero while pad_cur's
// C bits stay clear is the 1.0.1.3 wedge, asserted rather than felt.
volatile int gSohVRPadCur = 0;
volatile int gSohVRPadCMasked = 0;

// AUDIO LIVENESS (overlay 0044, VR R3). 1.0.1.3 shipped silent on the Vision
// Pro with no crash and no log line, and nothing in the round's diff touched
// audio: SoH's producer guard skips whenever the backend queue is full, and a
// device that has STOPPED DRAINING is indistinguishable from a full queue. These
// counters are what `vr audio` reads, so the next session proves audio in one
// line instead of listening for it. beats = the audio thread ran at all.
volatile unsigned long long gSohAudioBeats = 0;
volatile unsigned long long gSohAudioProduced = 0;
volatile unsigned long long gSohAudioSkipped = 0;
volatile unsigned long long gSohAudioQueueFails = 0;
volatile unsigned long long gSohAudioQueueBytes = 0;
volatile unsigned long long gSohAudioRecoveries = 0;
volatile int gSohAudioBuffered = 0;
volatile int gSohAudioDesired = 0;

// --- R14: THE SILENT LAUNCH ------------------------------------------------
//
// the user, on 1.0.1.17: "Sometimes I launch and there's no audio. I have to
// force quit and then there's audio. Not often, every once in a while."
//
// 0044's watchdog cannot see this failure, and the reason is arithmetic. It
// fires when the queue STOPS FALLING -- samples_left + 1584 > 2480, i.e. more
// than ~896 frames sitting in the backend for a whole second. If the device
// never OPENED (SDL_OpenAudioDevice failed, which on this platform means
// AVAudioSession activation failed), SDL_GetQueuedAudioSize(0) returns 0
// forever: samples_left is pinned at ZERO, the stall counter resets on every
// tick, produce_and_play runs at full rate, and every SDL_QueueAudio call fails
// into a device id of 0. Perfectly silent, perfectly invisible to a watchdog
// that only knows how to recognise a FULL queue -- and cured by a relaunch,
// because the next activation usually succeeds. That is the user's sentence, in
// full.
//
// A second latch made it worse than transient: Audio::InitAudioPlayer responds
// to a failed Init() by calling SetCurrentAudioBackend(NUL), which WRITES
// "null" into the config and saves it. One unlucky activation could therefore
// make an install permanently silent. Overlay 0053 stops that on iOS.
//
// So R14 adds the three things 0044 has no way to do:
//   * the session is PREPARED (category/mode/active) before SDL is allowed to
//     open a device, and the open is retried rather than accepted;
//   * a LAUNCH WATCHDOG that measures the only thing that actually proves
//     audio is leaving the process -- bytes accepted by the device -- and
//     reopens the device when none have been for ~3 s after the first frame;
//   * every one of those events is COUNTED and written into vr-mem.log, so a
//     later pull says whether it fired instead of the user having to notice.
volatile int gSohAudioDeviceId = 0;         // SDL_AudioDeviceID, 0 = not open
volatile int gSohAudioBackend = -1;         // Ship::AudioBackend as published by 0053
volatile unsigned long long gSohAudioOpenTries = 0;
volatile unsigned long long gSohAudioOpenFails = 0;
volatile unsigned long long gSohAudioReopens = 0;      // full close+open cycles
volatile unsigned long long gSohAudioThreadFaults = 0; // exceptions caught in OTRAudio_Thread
volatile unsigned long long gSohAudioSessionFails = 0; // AVAudioSession activation failures
volatile int gSohAudioReopenReq = 0;        // serviced by the audio thread
volatile int gSohAudioWatchdogRestarts = 0;
volatile int gSohAudioWatchdogState = 0;    // 0 waiting, 1 healthy, 2 unhealthy, 3 gave up

// --- R17 part B: THE WATCHDOG'S OWN FALSE POSITIVE, AND THE FAULT IT MISSED --
//
// vr-mem.log, 1.0.1.21, FOUR launches out of four:
//
//   90995.969 AUDIO watchdog restarted the device directly (audio thread not
//             beating) dev=2 beats=586 bytes=441280 fails=0 reopens=0 restarts=1
//   90996.705 AUDIO device reopened dev=2 beats=587 bytes=441280 fails=141292
//             reopens=1 restarts=1
//
// The heartbeat above it is t=90991.955, so that is t+4.01 s into EVERY launch,
// with the device OPEN (dev=2), no queue call ever having failed (fails=0), and
// the audio thread beating again 0.7 s later (586 -> 587). It is a pure false
// positive, and its cause is one line of R14's own: `lastBeats` was sampled
// immediately before the loop read `beats`, so the first iteration compared a
// value with itself and `deadThread` was unconditionally true. The consequence
// is not cosmetic: the direct call closes and reopens the device from the
// WATCHDOG thread while OTRAudio_Thread is inside SDL_QueueAudio -- the exact
// race the request path exists to prevent -- 0.25 s before the mode=vr flip
// races AVAudioSession against the spatial re-anchor. 141,292 queue failures
// (19,700 spdlog lines in 80 ms) is what that reopen produced.
//
// So R17 part B: the window comes FIRST, a dead thread must be dead across TWO
// consecutive windows with the failure counter unchanged, the beat count is
// re-read immediately before any direct call, a restart is deferred while an
// immersive transition is in flight, and the fault nobody was testing for --
// a queue pinned FULL while the recovery fires to no effect -- is named.
volatile int gSohAudioSaturations = 0;   // "unit not draining" episodes acted on
volatile int gSohAudioWatchdogSkips = 0; // decisions deferred (transition in flight)
// 1 while a visionOS immersive space is opening or dismissing. Set by Swift
// around openImmersiveSpace/dismissImmersiveSpace; the audio watchdog refuses to
// close a device inside that window because the session is being re-anchored.
volatile int gSohVRTransition = 0;
// R17 part B item 2: the VR entry watchdog's counters, printed by `vr room`.
volatile int gSohVREntryStalls = 0;
volatile int gSohVREntryHeals = 0;

// HUD PLANE (spec D7, overlays 0043 + 0031 rev15). gSohVROverlayDL is the
// overlay display list the game hands over in VR gameplay; gSohVRHudPlane is
// the shell's A/B (0 puts the HUD back on the world list, i.e. 1.0.1.2's
// doubled behaviour, which is the red control for the fix).
volatile int gSohVRHudPlane = 1;
void* volatile gSohVROverlayDL = NULL;
volatile int gSohVRHudW = 1600, gSohVRHudH = 1200; // 4:3 — see 0031 rev15
volatile int gSohVRHudFrames = 0;
// R7 verdict 9: the live scene id, published by overlay 0039's per-tick block
// so the crash record and the heartbeat can say WHERE the app was. -1 until the
// first gameplay tick (title screen, file select, or a non-VR build).
volatile int gSohVRSceneNum = -1;
// R7 verdict 8: the skybox's per-eye A.V.P -- head ROTATION only, seated at the
// game camera, scaled out to effective infinity. See SohImmersive.m's
// composition site for why the sky pulsated without it.
// R11 verdict 1: the sky pose's translation is now ZERO (see SohImmersive.m).
volatile float gSohVRSkyVP[2][2][16];
// R11 verdict 1: the MODEL translation overlay 0031 drops for a skybox draw --
// `play->view.eye` as Fast3D interpolated it for THIS host frame -- and how many
// skybox draws it has dropped it from. Published so `vr sky` can print the
// residual the construction refuses to carry instead of arguing about it.
volatile float gSohVRSkyMDrop[3] = { 0.0f, 0.0f, 0.0f };
volatile unsigned int gSohVRSkyDrops = 0;
volatile float gSohVRSkyMP[16];
// R8 part B: THE RIGHT-GRIP C-CHORD IS RETIRED. R7 made the right stick the
// C-pad while the right grip was held, because on a Sense pair the C items had
// nothing else to live on. The item wheel now owns that grip and covers them
// properly, and the user's ruling on the stick is flat: "we still have the right
// joystick sometimes acting like c buttons" -- it turns, and does nothing else.
// The global stays defined at a constant 0 so the dump keeps its shape and any
// stale reader sees "no chord" rather than a link error.
volatile int gSohVRGripChord = 0;
// R7 verdict 4: how many times overlay 0042 rev5 refused the authored attack
// state machine because motion combat covers the weapon, the live button-stab
// window in game ticks, and how many stabs have been asked for.
volatile int gSohVRAuthoredSuppressed = 0;
volatile int gSohVRStabTicks = 0;
volatile int gSohVRStabs = 0;
// R8 part B: the Z-TARGET OVERHEAD CHOP -- A while Z-targeting, which rev5's
// withdrawal of func_8083BB20 retired along with every other authored attack.
// Same shape as the stab: overlay 0042 rev7 opens a window and counts it down,
// the shell drives the pose envelope off the counter, overlay 0048 rev4 damages
// through it at the jump-slash tier.
volatile int gSohVRChopTicks = 0;
volatile int gSohVRChops = 0;
// R19 item 1: THE MEGATON HAMMER'S CHOP. the user, wearing 1.0.1.23: "The Megaton
// hammer works with either trigger and I see the wind/swish animation, but the
// hammer doesn't do the hitting-the-ground swing animation. It stays in my arm,
// upright."
//
// Same shape as the stab and the chop above, and for the same reason: R18 gave
// the hammer back vanilla's AUTHORED swing, and an authored swing moves the ARM
// while the arm in VR is the controller (overlay 0042's limb pin), so the mesh
// never went anywhere. Overlay 0042 rev20 bumps this once per hammer swing
// STARTED, at func_80837948 -- the game's one melee-animation site, which both
// the trigger path and the hand-swing path pass through -- and the shell drives
// its own hammer envelope off it.
//
// gSohVRHammerHits counts vanilla's ground hit (func_80842A28: the quake, the
// rumble, NA_SE_IT_HAMMER_HIT) and nothing about that effect is reimplemented:
// vanilla builds the collider quad and the ground line test through the L_HAND
// limb matrix, which in VR is the controller, so both follow the envelope for
// free. The two counters rising TOGETHER is the whole claim.
volatile int gSohVRHammers = 0;
volatile int gSohVRHammerHits = 0;
// R20 item 1c: GAME UNITS the hammer's ground line test is extended BEYOND the
// tip, in VR with motion hands and holding the hammer, and nowhere else.
//
// R19 dropped the grip 40 cm through the strike so the head reached the floor.
// R20 takes that back to zero -- the user: "like you're holding it, only the
// hammer end swings down" -- and the head therefore finishes wherever the
// wearer's hand is, which at a comfortable waist-height chop is 20-40 cm above
// the ground. Vanilla's func_80842DF4 line-tests from 10 units behind the
// weapon's BASE to its TIP and no further, so that chop would swing through
// nothing and no quake, rumble or shockwave would fire. 15 units is 0.44 m at
// the shipped world scale (34 units/m). `vr set hammerprobe 0..40`; 0 restores
// vanilla's reach exactly.
volatile float gSohVRHammerProbe = 15.0f;
// R8 part B: 1 while Link is in the shield stance (vanilla's own flag, or R
// held with a shield the physical-shield predicate says is on the arm). The
// shell lowers the EYE by a fraction of standing eye height while it is set --
// "you are crouching as well, so the perspective should go down a little".
volatile int gSohVRCrouch = 0;
// --- R9 part B -------------------------------------------------------------
// How many ticks the VR shield stance refused to let the kinematic override
// move Link. the user, on 1.0.1.12: "the left grip shield crouch lowers your
// height but now you can move around, which you're not supposed to."
volatile int gSohVRShieldStops = 0;
// The harness override for the stance predicate: -1 follows the game, 0/1 force.
// Owning a shield, having it on the arm and standing somewhere it can be raised
// are all things a simulator cannot promise; "he stops walking, and only then"
// is a property of the code regardless.
volatile int gSohVRShieldStanceForce = -1;
// How many times overlay 0042 rev8 went through vanilla's own meleeWeaponState
// setter (func_80833A20) rather than writing the field -- i.e. how many swing
// sounds and yells were played. Audio is not observable in the simulator; the
// SETTER PATH is, and that is what the suite asserts.
volatile int gSohVRSwingSfx = 0;
// How many times VANILLA's Z-target jump slash ran under motion combat.
//
// R9 part B REFUSED it (Player_ActionHandler_10 reaches func_8083BA90 directly
// and never consults func_8083BB20, so every Z+A press ran the authored jump
// slash alongside the chop: two attacks, one of them invisible on a pinned
// hand and audible because func_8083BA90 yells).
//
// R10 verdict 4 lets it run again, for its BODY: the user, on 1.0.1.13, *"the
// jump attack when Z-targeting, the camera should reflect a JUMP attack -- some
// vertical movement of the camera. It should match vanilla."* The eye is
// anchored on the actor root, so the only way it leaps is if Link does, and the
// only thing that makes Link leap is vanilla's own action. What R9 was right
// about -- one attack, one sound -- is kept by other means: the authored sword
// animation is invisible (the hand limb is pinned), its melee quads are refused
// by z_player_lib.c while covered, and the yell is counted here so the shell's
// chop path does not play a second one.
volatile int gSohVRJumpSlashVanilla = 0;
// How many times the chop path played its OWN yell because vanilla's action did
// not run (a side-hop, a floor vanilla refuses to jump from, no melee weapon).
// One press yields exactly one of these two counters, never both and never
// neither -- which is the assertion, since audio itself is unobservable here.
volatile int gSohVRChopYells = 0;
// Link's own speed, position and melee animation index, published every tick so
// "the shield stopped him" and "no vanilla jump slash ran" are numbers.
volatile float gSohVRLinkVel = 0.0f;
volatile float gSohVRLinkPos[3] = { 0.0f, 0.0f, 0.0f };
volatile int gSohVRMeleeAnim = 0;
// The ocarina profile: what overlay 0047 rev4 is actually using, and the
// harness override (-1 follows the game, 0/1 force). The ocarina profile is
// otherwise unreachable from a simulator suite -- it needs an ocarina, a song
// and a textbox -- and it is now the ONLY place a stick may become a C button.
volatile int gSohVROcarinaOut = 0;
volatile int gSohVROcarinaForce = -1;
// R7 verdict 4: how many stab cross-section quads overlay 0048 rev3 registered.
volatile int gSohVRStabQuads = 0;
// R7 verdict 4: 1 while motion combat covers the held weapon. Read by
// z_player_lib.c, which cannot see z_player.c's file-static predicate, to keep
// VANILLA's fattened melee AT quads from coming back to life alongside the
// physical blade now that meleeWeaponState is mirrored from the swing tier.
volatile int gSohVRMotionCovered = 0;
volatile int gSohVRVanillaQuadsSkipped = 0;
// R7 review: how many times motion coverage fell away and overlay 0042 rev6
// handed meleeWeaponState back to vanilla in a known-zero state. Without that
// edge the field stuck at 1 or -1 for the rest of the session.
volatile int gSohVRCoverDrops = 0;
// R7 verdict 5: 1 while VANILLA lock-on is engaged -- which is when the facing
// pin stands down so strafe, side-hop and backflip work as they do flat.
volatile int gSohVRZTarget = 0;
// R7 verdict 5: which lock-on hop Link is in the middle of -- -1 none, 0
// forward, 1 left, 2 BACKFLIP, 3 right. Drives the shell's flip camera.
volatile int gSohVRHopKind = -1;
// R6: how many times the HUD display-list pointer CHANGED between the
// gate that admitted it and the interpreter call that ran it (overlay
// 0031 rev17). That race, lost, hands Fast::Interpreter::Run a NULL
// display list and it faults on the first command word -- R5's rapid
// enter/exit SIGSEGV. It exists so "we fixed it" is a number in
// `vr room` rather than an argument.
volatile int gSohVRHudDLRaces = 0;

// Diagnostics: the active camera's `setting` (overlay 0037 rev2). z_room.c
// draws a pre-rendered background ONLY under CAM_SET_PREREND_FIXED, so this is
// what tells `vr room` whether the green-floored placeholder mesh is showing
// because the fixed camera was disabled.
volatile int gSohVRCamSetting = -1;

// --- R4: MOTION HANDS + MOTION COMBAT (VR-DONOR-MAP 3 + 8) -------------------
// The two hand matrices, in GAME units, row-vector order (out[i*4+j] =
// m.columns[i][j] -- OoT's own MtxF convention and gSohVREyeVP's). Published
// into the slot the engine is NOT reading and made visible by the SAME
// gSohVRPoseSeq bump as the eye pair, so a frame's two eyes and two hands are
// always one instant of one pose.
volatile int gSohVRHandValid[2] = { 0, 0 };
volatile float gSohVRHandMat[2][2][16];

// Donor gVrMotionHands, default 1: the hand limbs are pinned to the controller
// poses and the shoulders and forearms are hidden, because a floating hand
// attached to an arm that is not there is worse than no arm at all. When no
// Sense pair is connected the limb override falls back to R3's ANIMATED hand
// positions on its own -- gSohVRHandValid is the whole test -- so this stays 1
// and the settings sheet says why the hands are not tracking.
volatile int gSohVRMotionHands = 1;
// Donor gVrLeftHanded 0: the player's RIGHT controller drives the SWORD hand,
// which is Link's LEFT hand model (Link is left-handed). Mirroring per hand,
// donor gVrHandMirrorSword / gVrHandMirrorShield, both default 1: the
// reflection that flips a mesh's handedness also mirrors held items' face
// designs -- the sword survives that, the shield's crest reads upside-down --
// so it is toggleable per hand rather than globally.
volatile int gSohVRLeftHanded = 0;
volatile int gSohVRHandMirrorSword = 1;
volatile int gSohVRHandMirrorShield = 1;

// The swing detector's output (SohVrPhys.c, headset rate) as the 20 Hz game
// side reads it. gSohVRSwingSeq bumps ONCE per rising edge into HOT; the game
// compares it against its own last-seen value, which is what makes "one swing,
// one attack" survive a 90/120 Hz producer feeding a 20 Hz consumer.
volatile unsigned int gSohVRSwingSeq[2] = { 0, 0 };
volatile float gSohVRSwingSpeed[2] = { 0.0f, 0.0f }; // m/s at the edge
volatile float gSohVRSwingMid[2] = { 0.0f, 0.0f };   // live blade-midpoint speed
volatile float gSohVRSwingHand[2] = { 0.0f, 0.0f };  // live raw hand speed
volatile int gSohVRSwingJump[2] = { 0, 0 };          // that edge cleared 8 m/s
volatile int gSohVRSwingTier[2] = { 0, 0 };          // 0 idle / 1 armed / 2 hot

// The six-input taxonomy (DONOR-MAP 8 `padmgr.c`), merged into the ONE pad
// snapshot by overlay 0047 at the same tick boundary overlay 0039 owns.
volatile int gSohVRSenseActive = 0;
volatile unsigned int gSohVRSenseBtn[2] = { 0, 0 };
volatile float gSohVRSenseStickX[2] = { 0.0f, 0.0f };
volatile float gSohVRSenseStickY[2] = { 0.0f, 0.0f };
// R10 verdict 5: 1 while the merge is running OUTSIDE VR -- the flat window or
// the 3D panel, where the pair is an ordinary N64 pad with the right stick on
// the C buttons. Published by the pump below and read by overlay 0047, which is
// where the profile actually differs.
volatile int gSohVRSenseFlat = 0;

// The item TRIGGER reservation (DONOR-MAP 8, HANDOFF-ITEM-TRIGGER.md). When
// the hand holding an item has a trigger, that trigger mirrors the item's OWN
// N64 button as raw pad STATE rather than a press -- press nocks the bow, hold
// keeps it drawn, release looses, and every vanilla rule (ammo, magic, bottles,
// aim-and-throw) applies with nothing re-implemented. Non-zero here means that
// hand's trigger is spoken for and the generic binding table must not also
// claim it. Published by the game side (overlay 0045), read by overlay 0047.
volatile unsigned short gSohVRItemTriggerMask[2] = { 0, 0 };

// R18 item 2 (overlay 0042 rev19 -> 0047 rev7): and whether BOTH triggers drive
// it. the user, on 1.0.1.22: "it's counterintuitive to use the RIGHT trigger when
// the slingshot is in the LEFT hand." Narrower than the mask above on purpose --
// the mask is every non-sword C item (a bottle, a mask, the ocarina), while this
// is only the items whose ACTION is a trigger pull (Player_VrTriggerItem: the
// bows, slingshot, hookshot, longshot, boomerang, Megaton hammer, Deku stick).
// While it is set, both triggers mirror the mask as raw state and NEITHER is Z
// or B, so Z-targeting is unavailable while such an item is out -- the user's call.
volatile int gSohVRItemTriggerBoth = 0;

// R18 item 1: how many times the equip press was denied vanilla's
// VB_USE_HELD_ITEM_AFTER_CHANGE free use. "As soon as you select the boomerang
// it throws once, every time" was that free use meeting R16's direct throw; a
// bow select spent an arrow the same way. Rising here with
// gSohVRBoomDirectThrows standing still is the fix working.
volatile unsigned int gSohVREquipNoUse = 0;

// --- R12 item 4: THE HELD ITEM'S OWN SEAT IN THE HAND ------------------------
//
// the user, on 1.0.1.15: the slingshot is about 90 degrees off and aimed
// sideways; the ocarina is held upright with its mouthpiece pointing away. He
// asked whether the correction has to be per item, and the answer is yes -- per
// item AND per configuration.
//
// WHY. Vanilla does not attach an item to a generic hand: the hand and the item
// it holds are ONE display list (`gPlayerLeftHandDLists` / the right-hand set),
// chosen by `leftHandType` / `rightHandType`, and each one was modelled with
// the fist in whatever pose that item wants. On a screen that is invisible,
// because the arm's authored animation puts the fist where the mesh expects.
// In VR the hand limb is pinned to the controller by ONE calibration, and that
// calibration was dialled against the SWORD's fist. Every other mesh inherits
// the sword's seat and comes out turned by the difference between its own
// authored fist and the sword's.
//
// So the key is the MODEL TYPE, which is exactly the thing that names the mesh
// -- and it names the hand with it (`PLAYER_MODELTYPE_LH_*` is Link's left
// hand, the sword hand; `..._RH_*` is his right, the off hand), which is why
// there is no separate hand-role axis: the role is implied by the index. The
// axis that does vary independently is the CONFIGURATION, because overlay 0042
// applies its mesh mirror only in right-handed play, and a reflection changes
// the sign of two of the three angles.
//
// The correction is applied to the LIMB (there is nothing else to apply it to
// -- the item is not a separate draw), after the pin and after the mirror, so
// it moves Link's hand as well as the thing in it. That is the right outcome
// and not a compromise: the wearer's own hands are hidden, and what he is
// looking at is the item.
//
// Indices: [PLAYER_MODELTYPE_*][config] where config 0 = sword on the RIGHT.
// Values: yaw, pitch, roll in degrees, then x, y, z offset in GAME UNITS at
// Link's scale (the pin has already folded actor.scale in, so these are the
// same units the rest of z_player_lib.c uses). Defaults live in SohImmersive.m
// beside the hand calibration for the same reason that one does.
// SOHVR_ITEMCAL_N is PLAYER_MODELTYPE_MAX minus the sheath/waist tail; the
// canonical definition is in SohImmersive.h, which this file does not import.
#ifndef SOHVR_ITEMCAL_N
#define SOHVR_ITEMCAL_N 16
#endif
// R17 item 4: the aim trims need ONE MORE ROW than there are mesh slots,
// because the bow and the slingshot share slot 11/12 (Q-VR30) and the user's
// numbers for them differ. The canonical definition is in SohImmersive.h.
#ifndef SOHVR_AIMTRIM_N
#define SOHVR_AIMTRIM_SLINGSHOT SOHVR_ITEMCAL_N
#define SOHVR_AIMTRIM_N (SOHVR_ITEMCAL_N + 1)
#endif
volatile int gSohVRItemCal = 1;
volatile float gSohVRItemRotDeg[SOHVR_ITEMCAL_N][2][3];
volatile float gSohVRItemOffU[SOHVR_ITEMCAL_N][2][3];
// Published BY the pin, per VR hand (0 = left controller): the model type that
// hand is currently drawing, or -1. This is what lets the settings sheet name
// the item the user is holding while he dials it, and what lets the suite assert
// that equipping the slingshot actually reached the hand.
volatile int gSohVRHeldModel[2] = { -1, -1 };

// --- R13 (Q-VR28): THE AIM, AND WHY IT WAS NEVER THE MIRROR -----------------
//
// the user, on 1.0.1.16: "I can fire now, but it shoots way up HIGH and to the
// RIGHT (sword on right) / HIGH and to the LEFT (sword on left). It needs to
// follow where my aiming is -- the middle of the slingshot band, wherever it's
// pointed."
//
// R12 predicted the cause would be the mesh MIRROR: a rotation Euler-extracted
// from a reflected matrix is not the rotation of the un-reflected frame, and
// the sword hand carries a reflection in right-handed play only. THAT
// PREDICTION IS WRONG, and the arithmetic that retires it is worth keeping:
//
//   * `Matrix_MtxFToYXZRotS` computes yaw = atan2(mf->xz, mf->zz) and
//     pitch = atan2(-mf->yz, hypot(mf->xz, mf->zz)) -- i.e. from the matrix's
//     THIRD COLUMN and nothing else.
//   * `Actor_SetProjectileSpeed` flies the actor along
//     (sin y cos x, -sin x, cos y cos x), which IS that third column.
//   * A reflection applied as `Matrix_Scale(-1, 1, 1)` negates column ZERO.
//
// So vanilla's aim extraction is reflection-safe by construction; only the ROLL
// it also writes (atan2(mf->yx, mf->yy)) is corrupted, and roll is the arrow's
// cosmetic spin. Verified host-side to 5.6e-16 over 2000 random poses, mirrored
// and not (scripts/vr-aim-check.py).
//
// THE ACTUAL CAUSE is the fixed authored correction that sits between the limb
// matrix and the extraction. In `Player_PostLimbDrawGameplay`'s L_HAND branch
// vanilla applies `Matrix_RotateZYX(0x69E8, -0x5708, 0x458E)` before reading the
// column, and that rotation carries the arrow's axis to
//
//     (0.413, 0.787, 0.459) in the L_HAND limb frame
//     == 42 degrees to the RIGHT of and 52 degrees ABOVE the limb's own +Z.
//
// It is authored for the ANIMATED bow-draw pose, where the limb sits in one
// known orientation. In VR the limb matrix IS the controller, so those two
// numbers land on the controller's own frame: "high, and to the right". And the
// mirror explains the flip between configurations after all -- not through the
// extraction, but because the fixed correction MIXES 0.413 of column ZERO into
// the composed third column, and the mirror negates column zero in right-handed
// play only. High and to the RIGHT becomes high and to the LEFT.
//
// THE FIX. When a hand is pinned and an aimable item is in it, the projectile's
// direction is the item's own forward axis carried through the pinned,
// calibrated hand pose -- taken as a VECTOR through the matrix columns, never
// Euler-decomposed -- and vanilla's fixed correction is not applied at all.
//
// The axis is per item and console-tunable, because a sign error here must be
// correctable from the user's headset without a rebuild:
//
//     vr aim                        -- the direction in force, and the hand's
//                                      own forward, so they can be compared
//     vr set aimaxis <item> x y z   -- one row of the axis table
//     vr set aimpitch <deg>         -- a trim, added to the computed pitch
//     vr set aimyaw <deg>           -- the same, horizontally
//     vr set aimframe 0|1           -- 0 = the calibrated HAND pose (shipped),
//                                      1 = the ITEM-corrected pose
//     vr set aimspawn <units>       -- push the spawn point along the aim
//     vr set aim 0|1                -- off = vanilla's own arithmetic
//
// THE DEFAULT AXIS IS (1, 0, 0), and that is not arbitrary: the sword's blade
// runs along the L_HAND limb's +X (`D_80126080 = {5000, 400, 0}` is a point
// 5000 units up the blade), and the hand calibration is dialled against the
// SWORD's fist. Limb +X is therefore, by construction, the direction the
// wearer's controller points. The 400 in that vector is a 4.6-degree lift which
// is deliberately NOT modelled -- `vr set aimpitch` exists for exactly that.
//
// aimframe SHIPS 0, and the assumption is stated rather than hidden: the item
// correction (pitch -90, roll +45 on the slingshot) is a COSMETIC pose that
// makes the item sit in the fist the way vanilla draws it, and vanilla's own
// aim is not along the item mesh either. Aiming along the calibrated hand is
// "where my aiming is". If the user reports the nut leaving the band sideways,
// `vr set aimframe 1` is the one-command A/B.
#ifndef SOHVR_AIMFRAME_N
#define SOHVR_AIMFRAME_N 2
#endif
// --- R14: WHY R13 CHANGED NOTHING, AND WHAT THE TRIMS ARE NOW ---------------
//
// the user, on 1.0.1.17: "With the slingshot in my LEFT hand it still goes way UP
// and to the LEFT. I see no change." He is exactly right, and the cause is
// LIMB DRAW ORDER, not arithmetic.
//
// rev14 published each hand's aim basis from the PIN, which runs inside that
// hand's own OverrideLimbDraw, and cleared both bases at limb 1 of every draw.
// The bow and the slingshot live in Link's R_HAND (PLAYER_LIMB_R_HAND == 0x13)
// and their NOCKED SEED is positioned from the L_HAND branch of
// Player_PostLimbDrawGameplay (PLAYER_LIMB_L_HAND == 0x10). SkelAnime walks
// limbs in index order, so post(L_HAND) runs THREE limbs BEFORE
// override(R_HAND) publishes the basis the aim needs. gSohVRAimValid[off hand]
// was therefore ZERO at the one site that aims a bow, every frame, in BOTH
// configurations -- Player_VrAimHeld returned 0 and vanilla's own 42/52 degree
// correction ran exactly as before. "I see no change" is the literal truth.
//
// rev15 publishes BOTH hands' bases once, at limb 1, from gSohVRHandMat -- the
// same matrix the pin installs -- which owes nothing to the limb walk because
// the pin REPLACES the limb matrix outright rather than composing onto it. The
// draw order can never desynchronise it again.
//
// AND THE DEFAULT AXIS WAS ONLY RIGHT FOR ONE HAND. (1, 0, 0) is the direction
// a calibrated controller points *in the SWORD hand's frame*, because that is
// the fist the calibration was dialled against. The bow is in the OTHER hand,
// whose calibration differs by as much as 90 degrees of yaw, so the same local
// axis there is not the pointing direction at all. gSohVRAimHandFix carries
// C_hand^-1 * C_sword (published by the shell, identity for the sword hand), so
// the axis table stays expressed in the one frame it was reasoned about in.
// `vr set aimhandfix 0` turns it off for an A/B.
//
// THE TRIMS ARE PER ITEM AND PER CONFIGURATION NOW, because the settings sheet
// has sliders for them (R14 item 2) and a single pair of numbers could not tell
// the slingshot from the hookshot. One writer, one table: `vr set aimyaw` and
// the slider write the same row.
// R15 (VR): THE AIM IS THE CONTROLLER'S OWN AIM RAY NOW. the user, on 1.0.1.18,
// with the hook finally running ("24 hand / 0 vanilla"): "keeps going straight
// into the ground off to the side... I need a pitch that goes much higher."
// Both R13 and R14 derived the direction from the hand MESH calibration --
// twenty-four numbers dialled so a sword sits in a fist and a shield sits on a
// forearm -- and a frame dialled for how a mesh LOOKS is not a pointing
// direction; the hand fix only carried one wrong axis into the other hand.
// The Sense controller publishes a dedicated AIM location through ARKit
// (ar_accessory_location_name_aim), the runtime's own answer to "where is
// this thing pointing". The shell reads it beside the grip, seats it through
// the same transform as the hand, and publishes a unit direction and an origin
// per hand in game space: gSohVRAimRayDir / gSohVRAimRayOrg. Frame 2 is that
// ray and ships as the default; frames 0 and 1 are the R13/R14 bases and stay
// as the fallback for a hand the runtime has not answered for, and as the
// A/B. `vr set aimray x y z` is the axis in the aim location's own frame
// (-Z forward, the RealityKit convention) if the runtime's turns out to
// differ.
volatile int gSohVRAim = 1;       // master switch; 0 = vanilla's own arithmetic
volatile int gSohVRAimFrame = 2;  // 0 = calibrated hand pose, 1 = item-corrected, 2 = the controller's aim ray
volatile int gSohVRAimRayValid[2] = { 0, 0 };
volatile float gSohVRAimRayDir[2][3] = { { 0, 0, 1 }, { 0, 0, 1 } };
volatile float gSohVRAimRayOrg[2][3];
volatile float gSohVRAimRayAxis[3] = { 0, 0, -1 };
// R15: the aim crosshair (the user: "a little crosshair x of where it will go
// ... an option for users"). Vanilla's hookshot reticle, drawn at the point
// the aim ray meets the collision mesh, whenever a bow/slingshot is in hand.
// Range in the limb's model units: 100000 = 1000 game units.
volatile int gSohVRAimReticle = 1;
volatile float gSohVRAimReticleRange = 100000.0f;
// R17 item 2: "make the crosshair half the size." A MULTIPLIER on vanilla's
// own distance term (which already grows the mark with depth to hold a
// constant size on screen), so 0.5 is half the size at every distance and
// nothing about the constant-size property changes. `vr set aimreticlescale`.
volatile float gSohVRAimReticleScale = 0.5f;
// R16 item 2: the boomerang throws on the PULL. Overlay 0047 mirrors the Sense
// trigger's STATE onto the item's C button, so vanilla saw a held button and
// entered its hold-to-aim -- first person, the camera-zoom chirp, the HUD fade
// and a throw that waited for the release. With a controller aim ray there is
// nothing the hold buys. 0 restores vanilla's hold (`vr set boomdirect 0`).
volatile int gSohVRBoomDirect = 1;
volatile unsigned int gSohVRBoomDirectThrows = 0;
// R16 item 4: THE WORLD TURNS WITH LINK when the GAME turns him. The facing pin
// in overlay 0042 stands down in the choreographed states (ladder, ledge, hang)
// and nothing followed the 0x8000 snap a ladder descent writes, so the user
// climbed down facing away from the ladder. The game side is ONE writer: a
// signed s16 delta plus a sequence number, the pattern gSohVRFpEntered and
// gSohVRBladeHitSeq already use. The shell eases its own world yaw by the
// delta; `vr set ladderfollow 0` turns it off.
volatile int gSohVRBodyYawSnapDelta = 0;
volatile int gSohVRBodyYawSnapSeq = 0;
volatile int gSohVRAimHandFixOn = 1;
volatile float gSohVRAimSpawnU = 0.0f;
// [model][config][0 = yaw, 1 = pitch], degrees. Applied to the WORLD direction
// after it is composed, which is what makes "aims up" and "aims left" mean what
// they say on a slider.
volatile float gSohVRAimTrimDeg[SOHVR_AIMTRIM_N][2][2];
// R17 item 4: the row Player_VrAimHeld last READ, which is the mesh slot for
// everything except the slingshot (row SOHVR_AIMTRIM_SLINGSHOT). `vr set
// aimyaw` writes this row, so a console dial and the game can never disagree
// about which of the two numbers inside slot 11 is being moved.
volatile int gSohVRAimTrimRow = -1;
// R17 item 4: THE FROZEN AIM TRIMS. R14 shipped these as sliders and R15b as a
// Swift default (-15 pitch); the user dialled the rest on 1.0.1.21 and the
// section is gone, so the numbers live here -- the same move R14 made for the
// hand calibration, and for the same reason: a settings row deleted without
// moving what it DID is a constant that quietly stops being applied.
//
// [row][config][yaw, pitch]. config 0 = sword hand RIGHT. the user's numbers:
//
//   * BOW (rows 11/12): sword hand RIGHT -- the bow is in his LEFT hand --
//     yaw +25, pitch -15. Sword hand LEFT: yaw 0, pitch -15. The asymmetry is
//     his measurement, not a derivation, and it is the whole reason row 16
//     exists.
//   * SLINGSHOT (row 16): yaw 0, pitch -15, both configurations.
//   * HOOKSHOT (15) and BOOMERANG (6): R15b's shipped trim, unchanged.
//
// Every other row is the same 0 / -15 so a slot that becomes aimable later
// starts from the pitch that is right for the controller ray rather than from
// zero. Nothing reads them today.
static const float kSohVRAimTrim[SOHVR_AIMTRIM_N][2][2] = {
    /* 0  lh_open   */ { { 0, -15 }, { 0, -15 } },
    /* 1  lh_closed */ { { 0, -15 }, { 0, -15 } },
    /* 2  sword     */ { { 0, -15 }, { 0, -15 } },
    /* 3  sword2    */ { { 0, -15 }, { 0, -15 } },
    /* 4  bgs       */ { { 0, -15 }, { 0, -15 } },
    /* 5  hammer    */ { { 0, -15 }, { 0, -15 } },
    /* 6  boomerang */ { { 0, -15 }, { 0, -15 } },
    /* 7  bottle    */ { { 0, -15 }, { 0, -15 } },
    /* 8  rh_open   */ { { 0, -15 }, { 0, -15 } },
    /* 9  rh_closed */ { { 0, -15 }, { 0, -15 } },
    /* 10 shield    */ { { 0, -15 }, { 0, -15 } },
    /* 11 bow       */ { { 25, -15 }, { 0, -15 } },
    /* 12 bow2      */ { { 25, -15 }, { 0, -15 } },
    /* 13 ocarina   */ { { 0, -15 }, { 0, -15 } },
    /* 14 oot       */ { { 0, -15 }, { 0, -15 } },
    /* 15 hookshot  */ { { 0, -15 }, { 0, -15 } },
    /* 16 slingshot */ { { 0, -15 }, { 0, -15 } },
};

// A constructor for the same reason sohvr_itemCalInit is one: the reader is the
// game thread inside Player_VrAimHeld, where there is no safe point to notice
// that a table has not been filled in yet, and a zeroed row would be a silently
// untrimmed aim rather than a loud failure.
__attribute__((constructor)) static void sohvr_aimTrimInit(void) {
    for (int m = 0; m < SOHVR_AIMTRIM_N; m++) {
        for (int c = 0; c < 2; c++) {
            for (int i = 0; i < 2; i++) {
                gSohVRAimTrimDeg[m][c][i] = kSohVRAimTrim[m][c][i];
            }
        }
    }
}
// Published by the shell: the rotation that carries a vector expressed in the
// SWORD hand's calibrated frame into hand h's own frame. Row-major 3x3;
// identity for the sword hand by construction.
volatile float gSohVRAimHandFix[2][9] = {
    { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
};
// R14: does the projectile that just left take the hand path or vanilla's?
// gSohVRAimPath is the LAST nocked-seed frame's answer (1 = hand, 0 = vanilla);
// the two counters are incremented once per RELEASED projectile, which is what
// the settings read-out row shows so the user can see at a glance whether the
// hook is even active.
volatile int gSohVRAimPath = -1;
volatile unsigned gSohVRAimShots = 0;
volatile unsigned gSohVRAimVanillaShots = 0;
// The per-item forward axis, in whichever frame gSohVRAimFrame selects.
volatile float gSohVRAimAxis[SOHVR_ITEMCAL_N][3] = {
    { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 },
    { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 }, { 1, 0, 0 },
};
// Published BY the pin, per VR hand (0 = left controller): the calibrated hand
// pose in WORLD space, as columns, un-reflected -- [hand][frame][0..2] = the
// image of local +X, [3..5] of +Y, [6..8] of +Z -- plus its origin. frame 0 is
// the hand itself; frame 1 has the held-item correction folded in.
volatile int gSohVRAimValid[2] = { 0, 0 };
volatile float gSohVRAimBasis[2][SOHVR_AIMFRAME_N][9];
volatile float gSohVRAimOrigin[2][3];
// Published BY the aim, for `vr aim`: the direction the projectile is being
// given, the hand's own forward for comparison, and what produced them.
volatile float gSohVRAimDirW[3];
volatile float gSohVRAimFwdW[3];
volatile float gSohVRAimPosW[3];
volatile int gSohVRAimModel = -1;
volatile int gSohVRAimHandUsed = -1;
volatile int gSohVRAimSite = 0; // 1 = L_HAND nock, 2 = R_HAND held, 3 = boomerang
volatile unsigned gSohVRAimHits = 0;

// --- R12 item 6 (Q-VR26): A TEST-ONLY WAY TO PUT A SWORD BACK ON B ----------
//
// Q-VR26 has blocked two rounds of assertions: the suite reaches S21.5 with
// `covered` = 0 more often than not, and every claim in that section is gated
// on a melee weapon being IN HAND. The reason is not a VR bug at all -- it is
// that `gSaveContext.equips.buttonItems[0]` is not a sword by the time the
// suite gets there, and B equips whatever is ON B, so neither the wheel's UP
// flick nor any number of B presses can bring the sword back. (The likely
// culprit is S8's binding sweep, which presses START three times and pushes
// sticks and buttons through whatever screen that opens.)
//
// So the harness gets a way to say "put a sword on B", which is a thing a
// wearer does with the pause menu and a thing a simulator cannot. Precedent:
// gSohVROcarinaForce, which exists for exactly this reason -- the ocarina
// profile needs an ocarina, a song and a textbox, none of which a suite can
// arrange. One-shot: the game side clears it the tick it acts on it, and it
// ships 0, so nothing in a wearer's session can reach it.
volatile int gSohVRForceSword = 0;
volatile int gSohVRForcedSwords = 0;

// --- R6: THE ALYX ITEM COMPASS (overlay 0051, donor VrItemSelect.cpp) ------
// Hold the selector input, a compass of item icons appears anchored where
// your hand was, FLICK the hand toward one, RELEASE to take it. Valve's
// Half-Life: Alyx weapon menu almost verbatim -- chosen there over holsters
// precisely because it never misses and never drops anything.
//
// The trigger-mirrors-the-item's-button half (gSohVRItemTriggerMask, R4)
// stays exactly as it was: it is the FALLBACK, and it is what fires the item
// the compass equips.
volatile int gSohVRItemSel = 1;         // the feature
volatile int gSohVRItemSelHandCfg = 0;  // 0 = sword hand holds the compass, 1 = off hand
// R8 part B: the RIGHT GRIP (SOHSENSE_BTN_GRIP = 1 << 3), moved off the
// thumbclick at the user's instruction -- "if you press the right joystick down,
// you get a weapon wheel of your C button items. that's great! only let's move
// it to the RIGHT GRIP. then pressing the right thumbstick down just does the
// first person perspective (C UP)." The grip carries no N64 bit of its own in
// overlay 0047 rev3, so the wheel is the only thing it can mean.
volatile unsigned int gSohVRItemSelBtn = 8;
volatile float gSohVRItemSelDistCm = 5.0f;   // donor gVrItemSelDistance: flick distance, cm
// game -> shell. The shell suppresses that hand's stick while the compass is
// open (a thumb resting on a clicked stick must not also turn the player) and
// fires a haptic tick on every highlight change -- the Alyx confirmation tick.
volatile int gSohVRItemSelOpen = 0;
volatile int gSohVRItemSelHand = 0;
volatile int gSohVRItemSelSector = 0; // 0 centre, 1 up, 2 down, 3 left, 4 right
volatile unsigned int gSohVRItemSelTickSeq = 0;
volatile int gSohVRItemSelOpens = 0;
volatile int gSohVRItemSelPicks = 0;
volatile int gSohVRItemSelDraws = 0;
// Why the compass did not open, without a debugger: `calls` is the tick
// hook firing at all, `avail` is the availability predicate's answer, and
// `btn_seen` is the button word the GAME side read this tick. Between them
// the three failures that look identical from a headset -- the feature is
// off, the game says no, the controller said nothing -- are one line apart.
volatile int gSohVRItemSelCalls = 0;
volatile int gSohVRItemSelAvail = 0;
volatile unsigned int gSohVRItemSelBtnSeen = 0;
// R18 part C (D-070): the wheel draws the GAME'S OWN 3D "get item" models
// instead of the donor's flat 32x32 gItemIcons quads -- the user, on 1.0.1.22:
// "can our weapon wheel be improved? They look like 2D models -- could we use
// 3D models that look better?" `wheel3d` 0 puts every slot back on the icon
// quad, which is also what a slot with no get-item model falls back to.
//
// `wheelscale` multiplies the model size. The base is DERIVED, not guessed:
// overlay 0051 measures a typical get-item model at 65 raw units (every
// objects/object_gi_* Vtx resource in the extracted archive spans 45..80) and
// scales it to ~0.62 of the gap between two adjacent slots, which comes out at
// about 0.061 -- a quarter of the shop's Actor_SetScale(0.25f), because our
// ring is a quarter of a shop pedestal's spacing. Nobody has WORN that number
// yet, so it gets a dial: clamped 0.02 .. 4.0 on the game side.
volatile int gSohVRWheel3D = 1;
volatile float gSohVRWheelScale = 1.0f;
// R19 part B (D-073): the SELECTED slot's marker. the user, on 1.0.1.23: "the
// highlight is a big yellow square -- not pretty. A subtle border around the
// object, or a subtle highlight of the object itself." It was an untextured
// G_CC_PRIMITIVE quad about 8.6 units across, i.e. most of the gap between two
// slots. 1 = a thin gold RING border (gameplay_keep's own gLensFlareRingTex,
// which is a 64x64 annulus), 2 = a soft round glow (gUnknownCircle6Tex),
// 0 = no marker at all, leaving only the scale breath.
//
// R20 (D-075): THE DEFAULT IS 0. the user wore R19's ring on 1.0.1.24 -- "remove
// the orange circle that surrounds your selection; just make the size or zoom
// of the object you're selecting a little bigger. That's enough UI feedback for
// the user along with the haptics that are already there." So the marker is off
// and the selected model's breath grows to 1.35 +/- 0.05 (SohVrSel_SelScale,
// overlay 0051). Every line of the ring and glow path survives behind this
// dial: `vr set wheelhalo 1` is the one-command A/B back to R19.
volatile int gSohVRWheelHalo = 0;
// Evidence without a headset: models actually EMITTED. `draws` climbing while
// `models` stays at 0 is the wheel on screen with every slot on the 2D arm.
volatile int gSohVRItemSelModels = 0;

// --- R18 part B: THE LENS OF TRUTH IN VR (overlay 0055, D-071) ---------------
// the user, on 1.0.1.22: "I select it; it should show the same red interface with
// a circle like vanilla." The mask itself was never missing -- it is drawn per
// eye, in the world list, by Actor_DrawLensOverlay -- but two things made it not
// read as vanilla's lens: its circle was an oval with clipped sides (overlay
// 0031 rev20's aspect fix, D-071), and vanilla's tint peaks at alpha 74/255,
// which over a ~1900 px eye is very nearly nothing in a headset.
//
// `lenstint` is the multiplier on that alpha, realised as repeated passes of
// the same rect (1 - (1-a)^n), so the CENTRE of the circle stays exactly clear
// by construction: the mask is 0 there, and 0 stays 0 however many times it is
// drawn. Default 2.2 (about 53 % opacity at the rim against vanilla's 29 %).
// `lensscale` sizes the circle: 1.0 keeps vanilla's own proportion of the field
// (its constants, re-derived, not a magic number), and a headset's field is far
// wider than a TV's, so this is the dial that decides whether the lens reads as
// a lens or as a tinted world. Nobody has worn either number.
// `lenszfar` is item (c): vanilla's depth pass writes prim depth 0 (the NEAR
// plane) with Z_UPD over the whole masked field, which 0031 rev13 then hands to
// the compositor as this eye's depth -- so the compositor reprojects the
// periphery as if it were centimetres from the face. 1 (default) re-writes that
// same region to the FAR plane AFTER the invisible-actor pass has used it, so
// the actor clipping still works and the compositor gets a sane field; 0 is
// vanilla's behaviour exactly.
// --- R19 part B (D-073): THE MASK IS A WORLD QUAD, NOT A SCREEN RECT ---------
// the user, on 1.0.1.23: "I see doubled red circles in my eyes; it should be ONE
// oval open space surrounded by red." A screen-space texrect is drawn at the
// same PIXELS in both eyes, so it carries zero disparity and fuses at infinity
// -- and worse, this device's per-eye frusta are asymmetric, so the centre of
// the field is several degrees off the gaze axis in OPPOSITE directions per
// eye. Two circles, exactly as described. `lensworld` 1 (default) draws the
// same mask as a head-locked quad in the WORLD at `lensdist` metres, so both
// eyes see the SAME world point and the circle fuses where the wearer's eyes
// converge. `vr set lensworld 0` is the instant A/B back to the screen rect.
volatile int gSohVRLensWorld = 1;
volatile float gSohVRLensDist = 1.5f;
volatile float gSohVRLensTint = 2.2f;
volatile float gSohVRLensScale = 1.0f;
volatile int gSohVRLensZFar = 1;
// Evidence without a headset: rects EMITTED and the pass count of the last
// tinted draw. `draws` climbing with the lens on is the overlay running.
volatile int gSohVRLensDraws = 0;
volatile int gSohVRLensPasses = 0;
// The live world scale, game units per metre. The compass's flick distance is
// specified in CENTIMETRES OF REAL HAND TRAVEL (it is a gesture, not a level
// measurement), so the game side needs the same number the seat uses.
volatile float gSohVRWorldScale = 34.0f;

// Diagnostic: the N64 bits overlay 0047 OR'd into the pad this tick. It exists
// because of a real interaction with overlay 0039: 0039 masks the C bits the
// RIGHT STICK produced, by BIT, at the later merged snapshot -- so a
// Sense-produced C-left and a simultaneous stick-left are indistinguishable
// there and the Sense bit would be cleared with the stick's. Publishing what we
// OR'd makes that collision visible in `vr hands` instead of silent.
volatile int gSohVRSensePadBits = 0;

// --- R5: THE PHYSICAL BLADE (VR-DONOR-MAP 8, the gVrPhysVisualMesh=0 path) --
//
// R4's honest headline gap was that damage landed along Link's AUTHORED sword
// arc rather than where the hand was. R5 closes it: the game harvests its own
// collision mesh around the blade and publishes it here; the shell converts to
// tracking metres and runs the contact solver at HEADSET rate; the blade line
// the solver produces comes back and becomes OoT's own swept AT quad.

// Master switch. 1 = the physical blade. 0 = R4's behaviour verbatim (a swing
// sets sUseHeldItem and Link's authored attack runs), kept because some players
// will prefer the authored animation, and because it is the fallback the moment
// the shell reports no hands.
volatile int gSohVRBladeDamage = 1;

// game -> shell: the harvested collision polys, GAME units, world space.
// Written at draw, read every compositor frame (the geometry is static in game
// space, so re-converting it per frame through the CURRENT seat is what keeps
// it correct while Link moves between ticks).
volatile int gSohVRMeshCount = 0;
volatile float gSohVRMeshTri[32][9];
volatile int gSohVRMeshId[32];
// R6: the harvest is no longer triangles alone. gSohVRMeshShape says how to
// read the nine floats above -- 0 TRI (three verts), 1 CAPSULE (two axis
// endpoints in a/b), 2 SPHERE (centre in a) -- and gSohVRMeshRadius carries
// the radius, in GAME UNITS like everything else here. Dynapoly probe hits are
// triangles; an enemy's AC cylinder is a capsule; each JntSph element is a
// sphere. Same array, same seq, same count: one publication, so a reader can
// never catch the shapes and the verts from different frames.
volatile int gSohVRMeshShape[32];
volatile float gSohVRMeshRadius[32];
volatile unsigned int gSohVRMeshSeq = 0;

// shell -> game: the blade line the SIM pose implies -- base, tip, and the
// SAME two from the previous solver step. Those four points ARE the swept
// damage quad's corners, in the vanilla vertex order. Published into the pair
// slot under the pose seq, like everything else a frame reads.
volatile int gSohVRBladeValid[2] = { 0, 0 };
volatile float gSohVRBladeLine[2][2][12];

// shell -> game: the contact ring. The shell writes entry (seq & 7) and THEN
// bumps the seq; the game consumes forward from its own last-seen value and
// clamps to eight behind. A contact eight events old is not damage anyone is
// waiting for.
volatile unsigned int gSohVRContactSeq = 0;
volatile float gSohVRContactPos[8][3];
volatile float gSohVRContactNrm[8][3];
volatile float gSohVRContactImpact[8];
volatile int gSohVRContactHand[8];
// R6: the prim id the contact was against, (kind << 12) | detail -- WALL
// carries the surface's own sfx material, HARD the collider's colType,
// FLESH nothing. It is what turns a contact into the right NOISE.
volatile int gSohVRContactId[8];

// game -> shell: a damage quad LANDED. The shell drops the swing tier
// HOT -> ARMED on the change, which is the donor's entire "one strike per
// swing" mechanism -- to strike again the blade must re-cross the hit speed,
// which is what a second swing is.
volatile unsigned int gSohVRBladeHitSeq[2] = { 0, 0 };

// Diagnostics for `vr blade`. Separating these is what makes a failure
// readable in one line from a headset: tris 0 means the harvest found nothing
// (wrong scene, blade nowhere near geometry); quads 0 with tris nonzero means
// the swing never went HOT or no melee weapon is held; hits 0 with quads
// climbing means the quads are registering and missing.
volatile int gSohVRBladeQuads = 0;
volatile int gSohVRBladeHits = 0;
volatile int gSohVRBladeTris = 0;
// R6: how the published prim set breaks down. `tris` is the total; these
// two say how many of them came from the dynapoly probe fan and from actor
// colliders. A blade that passes through a door with dyna=0 is a probe
// problem; the same with dyna=1 is a solver problem, and that is the whole
// reason they are separate numbers.
volatile int gSohVRBladeDyna = 0;
volatile int gSohVRBladeBodies = 0;
volatile int gSohVRBladeStrikes = 0;
volatile int gSohVRBladeContacts = 0; // solver contacts published

// --- R5: HANDS AT HEADSET RATE (overlay 0050) -------------------------------
// R4's hands were pinned at DL-BUILD time, which is once per 20 Hz game tick,
// and LUS then interpolated between two ticks' matrices for the frames in
// between. The eyes were already at compositor rate; the hands were not.
//
// 0042 now tags the Mtx allocations that belong to each hand and publishes the
// matrix it built them against; overlay 0050's interpreter hook re-seats them
// onto THIS pair's live pose with D = inverse(record) * live, ahead of the
// interpolation replacement map. Both eyes of a pair read the same slot, so the
// R2a invariant (everything presented in a pair carries one pose) holds.
//
// gSohVRHandLive is the red control: `vr set handlive 0` restores R4's 20 Hz
// interpolated hands, live, which is the only honest way to A/B this in a
// headset.
volatile int gSohVRHandLive = 1;
volatile int gSohVRHandMtxTag = 0; // 0 = none, hand + 1, set only during the pin
void* volatile gSohVRHandMtxPtr[2][4];
volatile int gSohVRHandMtxCount[2] = { 0, 0 };
volatile float gSohVRHandRecMat[2][16];
volatile int gSohVRHandRecValid[2] = { 0, 0 };
// Diagnostic: matrices actually re-seated. Zero with hands visibly tracking
// means the registration never happened (0042 not rebuilt, or the tag cleared
// too early) and the hands are silently back at 20 Hz -- which is exactly the
// failure that looks like nothing at all.
volatile int gSohVRHandLiveHits = 0;
// Diagnostic: how many times the interpreter SEARCHED the table. R5 ran
// that search on every GfxSpMatrix in every mode -- 2D and 3D-panel
// included -- because its only gate was gSohVRHandLive, which defaults
// to 1 and is never cleared. Overlay 0050 rev2 gates on VR first person;
// this must read 0 outside VR.
volatile int gSohVRHandLiveSearch = 0;

// R6 (spec D9 -- EVERY EXIT RESTORES). The table above holds RAW
// POINTERS into the graph pool, recorded during one VR session's limb
// draw. R5 only ever cleared it inside the limb override itself, so a
// session that ended anywhere else left stale addresses standing; the
// arena reuses them, and the next session's pointer-identity search can
// then match an unrelated display-list matrix and re-seat it onto a hand
// delta. Cheap to prevent, invisible to diagnose: clear the whole table
// at both ends of every session.
// The loop thread's REQUEST. Set at VR exit; the game thread clears the table
// itself, in overlay 0039's per-frame latch block. See that patch and
// SohVR_ClearHandMtxTable below for why the loop thread must not do it.
volatile int gSohVRHandMtxClearReq = 0;

// ENTRY ONLY, and the distinction is load-bearing. This writes the table
// directly, which is safe exactly once: at VR entry, before gSohVRFpActive has
// been raised, no limb draw is registering anything and the game thread has no
// interest in these words. At EXIT the game thread is still drawing, so the
// same write would be a second owner -- gSohVRHandMtxClearReq is what the exit
// path uses instead.
void SohVR_ClearHandMtxTable(void) {
    gSohVRHandMtxTag = 0;
    for (int h = 0; h < 2; h++) {
        gSohVRHandMtxCount[h] = 0; /* count FIRST: a concurrent reader
                                    * that catches this mid-clear sees an
                                    * empty table, never a live count over
                                    * cleared pointers. */
        gSohVRHandRecValid[h] = 0;
        for (int i = 0; i < 4; i++) {
            gSohVRHandMtxPtr[h][i] = NULL;
        }
        for (int i = 0; i < 16; i++) {
            gSohVRHandRecMat[h][i] = 0.0f;
        }
    }
}

// --- R5: THE PARAMETRIC PHYSICAL SHIELD (overlay 0049) ----------------------
// 1 = the shield rides the off-hand controller full time, with the donor's
// parametric trapezoid quad, and R never enters a stance. 0 = R4's behaviour:
// the vanilla square quad in its vanilla place, raised with R.
//
// THE DONOR HAS NO RAISE GESTURE and neither do we. "Hold it up and you block"
// is emergent: the quad IS the visible shield at your hand, so an attack that
// misses it misses it, and the 65-degree facing cone (overlay 0046) rejects a
// shield that is not pointing at the attacker. Inventing a discrete raise test
// would be new design, not a port.
volatile int gSohVRShieldPhysical = 1;

// The nine sliders, in the donor's own order and at its shipped defaults
// (VrShield.cpp:114-123). Widths and height are FULL dimensions in game units
// (the game side halves them into the x100 model space); shifts are game units;
// pitch/yaw/roll are degrees. NONE of these has been seen in a headset by
// anyone in this program -- they are PCVR numbers tuned against a different
// controller in a different hand, and the -90 roll is the one most likely to be
// wrong for a Sense unit.
volatile float gSohVRShieldQuad[9] = {
    21.2f, // width top
    11.9f, // width bottom
    18.0f, // height
    -1.1f, // shift across  (in the collider's OWN tilted frame)
    -0.8f, // shift up      (likewise)
    -2.5f, // shift out     (likewise)
    -4.0f, // pitch, deg
    0.0f,  // yaw, deg
    -90.0f // roll, deg
};

// Diagnostics for `vr shield`. `held` is the game side's own held predicate as
// of its last tick -- the one number that separates "the shield is not physical"
// from "the shield is physical and the attack simply missed the quad", which
// from a headset look identical.
volatile int gSohVRShieldHeld = 0;
volatile int gSohVRShieldVetoes = 0;
volatile int gSohVRShieldBlocks = 0;

// The physical shield's facing cone, degrees (donor gVrPhysShieldFacingDeg,
// default 65; >= 179 disables). Overlay 0046 vetoes a hit on Link's shield quad
// whose attacker sits outside this cone about the quad's own outward normal.
volatile float gSohVRShieldFacingDeg = 65.0f;

// Diagnostic: swings the GAME SIDE actually acted on. The shell's
// gSohVRSwingSeq counts detected edges; this counts the ones that became an
// attack. A gap between them is the melee-only gate doing its job (a swing with
// the bow out) or the 20 Hz consumer never running -- and telling those two
// apart from a headset needs both numbers, not one.
volatile int gSohVRSwingsTaken = 0;

// Diagnostic: how many hand LIMBS the override actually pinned. Two per frame
// while both hands track. Zero with a live pose published is the one failure
// that looks exactly like "the hands do not work" from a headset and has a
// completely different cause (the override never selected, or hideBody off).
volatile int gSohVRHandPins = 0;

// Diagnostics for the melee gate. A swing that does not become an attack is
// otherwise indistinguishable from a swing that was never detected, and these
// two numbers separate them in one line: what is in Link's hand right now, and
// what pressing B would use.
volatile int gSohVRHeldAction = -1;
volatile int gSohVRBItem = -1;

// The interface handshake. The donor's game side refuses to run when its
// compiled-against VR_PHYS_INTERFACE_VERSION does not match what LUS reports,
// because its two halves live in separate repos that can drift; ours live in
// one repo but on either side of the pristine-vendor seam, which drifts the
// same way when a patch is regenerated and the shell is not rebuilt. 0 until
// the VR loop starts -- absence is a mismatch too.
volatile int gSohVRPhysVersion = 0;
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import "SohIosShell.h"

#include <arpa/inet.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - Instrumentation helpers

// Thermal state for the perf probe (overlay 0008): 0 nominal, 1 fair,
// 2 serious, 3 critical (NSProcessInfoThermalState).
int SohIos_ThermalState(void) {
    return (int)NSProcessInfo.processInfo.thermalState;
}

// Menu visibility, exported by overlay 0013 (OTRGlobals.cpp) — drives the
// touch overlay's auto-hide.
extern int SohIos_IsMenuOpen(void);

// Backgrounded flag, read by the Metal backend (overlay 0016) to stop
// rendering while suspended: nextDrawable in the background is the classic
// cause of post-resume slowdowns and watchdog kills. volatile is enough —
// one writer (main thread), reader tolerates staleness of a frame.
static volatile int gSohIosBackgrounded = 0;
void SohIos_SetBackgrounded(int backgrounded) {
    if (gSohIosBackgrounded != backgrounded) {
        NSLog(@"[SohIosShell] backgrounded=%d", backgrounded);
    }
    gSohIosBackgrounded = backgrounded;
}
int SohIos_IsBackgrounded(void) {
    return gSohIosBackgrounded;
}

// Park tick for overlay 0016. On iOS the game loop RUNS ON THE MAIN
// THREAD (SDL_main), so a sleeping park loop would block the run loop and
// deadlock: the very notifications/timers that clear the backgrounded
// flag are delivered by that run loop (root cause of the black-screen-
// with-audio resume, reproduced on sim 2026-07-12). Instead, service the
// run loop while parked — lifecycle events keep flowing and the flag
// clears the moment the scene foregrounds.
void SohIos_ParkTick(void) {
    if (NSThread.isMainThread) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    } else {
        struct timespec nap = { 0, 50 * 1000 * 1000 };
        nanosleep(&nap, NULL);
    }
}

// Device feedback 2026-07-12: resume sometimes came back to a black screen
// with audio and dead input — the signature of the 0016 park never
// releasing because the scene delegate's foreground callbacks didn't fire.
// Three independent clears now: scene-delegate methods, scene
// notifications (always post), and a 1 s main-thread reconciler — timers
// are frozen while suspended and resume with the run loop, so even if
// every callback path fails, the flag clears within a second of the app
// actually being active again.
static void SohIos_InstallBackgroundReconciler(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidEnterBackground");
                                                    SohIos_SetBackgrounded(1);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillEnterForegroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneWillEnterForeground");
                                                    SohIos_SetBackgrounded(0);
                                                }];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* n) {
                                                    NSLog(@"[SohIosShell] notif SceneDidActivate");
                                                    SohIos_SetBackgrounded(0);
#if TARGET_OS_VISION
                                                    // A resize-stress scene reconnect delivers a NEW scene; the
                                                    // 0026 main-guard stops the engine re-boot, but the existing
                                                    // SDL window must move onto the new scene or it stays black.
                                                    if ([n.object isKindOfClass:UIWindowScene.class]) {
                                                        UIWindowScene* scene = (UIWindowScene*)n.object;
                                                        for (UIWindow* w in UIApplication.sharedApplication.windows) {
                                                            if (w.isKeyWindow && w.windowScene != scene) {
                                                                NSLog(@"[SohIosShell] re-attaching SDL window to reconnected scene");
                                                                w.windowScene = scene;
                                                                SohIos_GlueWindowToScene(w, scene);
                                                            }
                                                        }
                                                    }
#endif
                                                }];
#if TARGET_OS_VISION
    // D-030: the game loop owns the main thread and SDL's event pump spins the
    // runloop with ~zero timeout, which never reaches the point where the GCD
    // MAIN QUEUE drains — dispatch_async(main) blocks and every SwiftUI
    // main-actor job (ornament button actions, onChange -> openImmersiveSpace)
    // starve forever (the historical bridge dispatch_sync deadlock, same
    // mechanism). Timers DO fire from the pump, so a 60 Hz timer runs the
    // runloop for 0.5 ms in default mode — long enough to hit beforeWaiting
    // and service the main queue. ~0.5 ms of the frame budget, visionOS-only.
    // Belt and suspenders: run the loop briefly (services sources/timers) AND
    // invoke libdispatch's main-queue drain entry directly — SDL's 2 µs pump
    // spins never reach the runloop's own drain point (empirical: the
    // historical bridge dispatch_sync deadlock), and this is the canonical
    // game-engine escape hatch for exactly this loop shape. Main thread +
    // runloop-callout context only (both true in a timer callback).
    extern void _dispatch_main_queue_callback_4CF(void* msg);
    extern volatile int gSoh3DDrainTicks;
    NSTimer* gcdDrain = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                               repeats:YES
                                                 block:^(NSTimer* t) {
                                                     gSoh3DDrainTicks++;
                                                     CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0005, false);
                                                     _dispatch_main_queue_callback_4CF(NULL);
                                                 }];
    [NSRunLoop.mainRunLoop addTimer:gcdDrain forMode:NSRunLoopCommonModes];
#endif
    NSTimer* reconciler = [NSTimer timerWithTimeInterval:1.0
                                                 repeats:YES
                                                   block:^(NSTimer* t) {
                                                       static int ticks = 0;
                                                       if (gSohIosBackgrounded && (++ticks % 5 == 0)) {
                                                           NSLog(@"[SohIosShell] reconciler: flag=1 appState=%ld",
                                                                 (long)UIApplication.sharedApplication.applicationState);
                                                       }
                                                       if (gSohIosBackgrounded &&
                                                           UIApplication.sharedApplication.applicationState !=
                                                               UIApplicationStateBackground) {
                                                           NSLog(@"[SohIosShell] background flag reconciled (missed foreground callback)");
                                                           SohIos_SetBackgrounded(0);
                                                       }
                                                   }];
    // NSRunLoopCommonModes: SDL's run-loop servicing can starve the default
    // mode; common modes ride every turn (suspected reason the first
    // reconciler never fired).
    [NSRunLoop.mainRunLoop addTimer:reconciler forMode:NSRunLoopCommonModes];
    NSLog(@"[SohIosShell] background reconciler installed");
}

// LUS console-variable flush (extern "C", API_EXPORT). iOS swipe-kill is
// SIGKILL — desktop SoH's write-on-quit never runs, so CVar/enhancement/bind
// changes made in the menu would be lost. Flush on resign-active (fires
// before background and before any kill). In-game .sav files are already
// written synchronously by SaveManager at save time; this covers config.
extern void CVarSave(void);
extern int32_t CVarGetInteger(const char* name, int32_t defaultValue);
extern void CVarSetInteger(const char* name, int32_t value);
extern float CVarGetFloat(const char* name, float defaultValue);
extern void CVarSetFloat(const char* name, float value);
extern void CVarClearBlock(const char* name);

// Game pause state, exported by overlay 0013 — drives the ≡ button policy
// when a physical controller is active.
extern int SohIos_IsGamePaused(void);

// Title/intro/file-select context (overlay 0013) — the ≡ button stays
// visible there so users can tune settings at the start.
extern int SohIos_IsTitleOrDemo(void);

// Menu touch-scroll queue (overlay 0013/0018): mouse-free scrolling.
extern void SohIos_QueueMenuScroll(float x, float dy);

// Rolling 1s fps from the perf probe (overlay 0008 rev4) for the HUD.
extern void SohIos_HudStats(float* fps);

// Active BGM/fanfare sequence ids (overlay 0013) — wrong-music diagnostics.
extern uint32_t SohIos_ActiveSeqIds(void);

// Any ImGui popup open (overlay 0013): overlay yields all input to it.
extern int SohIos_IsPopupOpen(void);

// First-run fidelity defaults for this device (user feedback 2026-07-10):
// pace to the display's refresh (120 on ProMotion) and render at 200%
// internal resolution. Versioned so later builds can seed more without
// clobbering user changes; only ever runs when the marker is absent.
static void SohIos_SeedDefaultsOnce(void) {
    // MIGRATION (unconditional, runs before any menu draw): gSohIos.MaxFps
    // changed from index semantics (0=60, 1=120) to literal fps values.
    // SoH's combobox does comboMap.at(storedValue) — a legacy 0/1 in the
    // {60,90,120} map throws std::out_of_range = instant abort on menu open
    // (Vision Pro regression, 2026-07-14).
    {
        int mf = CVarGetInteger("gSohIos.MaxFps", 120);
        if (mf <= 1) {
            CVarSetInteger("gSohIos.MaxFps", mf == 0 ? 60 : 120);
        }
    }
    int version = CVarGetInteger("gSohIos.DefaultsVersion", 0);
    if (version >= 4) {
        return;
    }
    if (version < 1) {
        CVarSetInteger("gSettings.MatchRefreshRate", 1);
    }
    // v2: gInternalResolution back to 1.0 — measured on sim (2026-07-12):
    // the multiplier is only consumed by Fast3dGui's ImGui game-window
    // path, which the iOS present pipeline doesn't use, so the v1 "200%"
    // seed was a no-op — and if the path ever activates, >1.0 would
    // actually DOWNGRADE from native (it multiplies ImGui points, not
    // drawable pixels). The game already renders at native drawable res;
    // true SSAA on iOS is a D7 perf-ladder work item.
    if (version < 2) {
        CVarSetFloat("gInternalResolution", 1.0f);
    }
    // v4: decal z-fighting mode "no vanishing paths" — the dirt-path
    // "line swallowing the path" artifact (task #39, user screenshot) is the
    // decal depth-bias failing at high render heights; upstream ships a
    // height-scaled mode for exactly this. Benefits iPhone equally.
    if (version < 4) {
        CVarSetInteger("gSettings.ZFightingMode", 2);
    }
#if TARGET_OS_VISION
    // v3: ceiling defaults, soak-verified on the M5 Vision Pro (2026-07-16):
    // 4K pack / 100% render scale / 120 fps held 117-119 fps for 22 minutes,
    // thermal never past "fair", gpu_ms p95 < 5 — see MEASUREMENTS.md.
    if (version < 3) {
        CVarSetInteger("gSohIos.MaxFps", 120);
        CVarSetInteger("gSohIos.VisionLongEdge", 3840);
    }
#endif
    CVarSetInteger("gSohIos.DefaultsVersion", 4);
    CVarSave();
    NSLog(@"[SohIosShell] defaults seeded v4 (ZFightingMode=2 no-vanishing-paths)");
}

void SohIos_FlushConfig(const char* why) {
    CVarSave(); // ~13 KB JSON; cheap, safe to repeat
    NSLog(@"[SohIosShell] config flushed (%s)", why ? why : "?");
}

static void SohIos_InstallConfigPersist(void) {
    static BOOL installed = NO;
    if (installed) {
        return;
    }
    installed = YES;
    // Under a scene session UIKit posts UISceneWillDeactivate, NOT the app-
    // level UIApplicationWillResignActive (same scene-vs-app-delegate split
    // that broke URL delivery). Observe both notification names so the flush
    // fires whichever lifecycle the runtime uses; the scene delegate below
    // also calls SohIos_FlushConfig directly as a third path.
    void (^flush)(NSNotification*) = ^(NSNotification* note) {
        SohIos_FlushConfig("notif");
        // R8 part C: say goodbye in the same breath as the settings write. A
        // heartbeat file with no exit marker is how the NEXT launch knows the
        // last one was killed rather than closed -- and a swipe-kill is a
        // SIGKILL too, so this is the last code that runs either way.
        extern void SohIos_MarkCleanExit(const char* why);
        SohIos_MarkCleanExit("resign");
    };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
}

// --- Crash and last-breath capture (VR R7 verdict 9) -------------------------
//
// THE EVIDENCE THIS EXISTS FOR. the user's app died mid-play in the headset on
// 2026-09-04 and left NOTHING: `Documents/crash.txt` was still July's SIGABRT,
// and `idevicecrashreport` on the paired device produced no .ips of any kind
// for soh and no JetsamEvent naming it. An exit that leaves neither an in-app
// signal record nor a system report is not a signal crash at all — the live
// candidates are a CompositorServices abort path, an uncaught ObjC or C++
// exception on a non-main thread, or the immersive scene being invalidated and
// the process exiting "cleanly" on its way out.
//
// So the capture is widened on five fronts, and every one of them answers a
// different way of dying:
//
//   1. Signals, on EVERY thread, with an ALTERNATE STACK. The old handler had
//      no sigaltstack, so a stack-overflow SIGSEGV — the one a deep interpreter
//      recursion produces — could not run a handler at all. It also missed
//      SIGTRAP (a Swift/ObjC runtime trap) and SIGSYS.
//   2. `std::terminate` (C++) and `NSSetUncaughtExceptionHandler` (ObjC). An
//      uncaught throw calls abort() only AFTER the terminate handler, and the
//      ObjC one runs before any abort at all — both leave a NAMED reason,
//      which a bare SIGABRT backtrace does not.
//   3. Metal command-buffer errors, reported by the render loop.
//   4. Compositor-layer invalidation, with its reason string.
//   5. A HEARTBEAT. The failure mode above leaves no record BY DEFINITION, so
//      the answer cannot be a better death notice — it has to be a running
//      one. `Documents/vr-heartbeat.txt` is rewritten every 5 s with the frame
//      counter, the mode, the scene, and available memory; whatever the app
//      does on the way out, that file is its last known state. It is written
//      with O_TRUNC + a single write and fsync'd, so it is never half a record.
//
// MEMORY is the prime suspect and is therefore measured, not assumed:
// `os_proc_available_memory()` is logged at VR entry and in every heartbeat,
// and appended to `Documents/vr-mem.log` so a downward slope is visible after
// the fact. Two 4096-square colour+depth eye targets plus the HUD framebuffer
// plus a 4K texture pack's cache is a real jetsam budget.

// The build stamp, cached as C string at arm time: the signal handler must not
// touch Foundation, and Info.plist is where the CMake-injected version lives
// (there is no compile-time SOH_IOS_VERSION macro in this translation unit).
static char sSohBuildStamp[128];
static char sSohCrashPath[1024];
static char sSohHeartPath[1024];
static char sSohMemPath[1024];
static char sSohCrashNote[256]; // set by the non-signal reporters, read by them
static volatile int sSohCrashWritten = 0;

static void SohIos_CrashPaths(void) {
    if (sSohCrashPath[0] != '\0') {
        return;
    }
    const char* home = getenv("HOME");
    if (home == NULL) {
        home = "/tmp";
    }
    snprintf(sSohCrashPath, sizeof(sSohCrashPath), "%s/Documents/crash.txt", home);
    snprintf(sSohHeartPath, sizeof(sSohHeartPath), "%s/Documents/vr-heartbeat.txt", home);
    snprintf(sSohMemPath, sizeof(sSohMemPath), "%s/Documents/vr-mem.log", home);
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    snprintf(sSohBuildStamp, sizeof(sSohBuildStamp), "%s (%s)",
             [info[@"CFBundleShortVersionString"] ?: @"?" UTF8String],
             [info[@"CFBundleVersion"] ?: @"?" UTF8String]);
}

// --- R8 part C: the numbers a jetsam is actually made of ---------------------
//
// The 2026-09-05 deaths were memory kills, not crashes: rpages x 16 KB = 4.90 GB
// resident, no signal, no handler, nothing to catch. So the instrumentation goes
// first and the fixes follow it. Six fields, each answering one hypothesis:
//
//   phys_mb      task_info(TASK_VM_INFO).phys_footprint -- the number JETSAM
//                itself uses. avail_mem_mb is a derived difference, and it
//                returns 0 outright in the simulator, which is exactly where
//                this had to be reproducible.
//   mtl_mb       MTLDevice currentAllocatedSize. Splits GPU from CPU in one
//                field: plateauing while phys_mb climbs proves the leak is CPU.
//   texcache     Fast3D's GPU texture cache, bytes and entries (overlay 0020).
//   rescache     LUS's ResourceManager cache, bytes and entries (overlay 0045).
//                THIS is the decisive counter -- monotonic growth here with no
//                fall is the unbounded strong-pointer map, and it is the one
//                that survives leaving VR.
//   pendmips     sSohIosPendingMips.size(), which must be 0 between frames.
//                Any steady non-zero value is the 0031 drain leak, outright.
//   trims        how many times the governor fired and what it freed.
//
// Every one of these is a plain C symbol out of libultraship (overlay 0045), so
// they are declared here rather than dragging a C++ header into the shell.
extern void SohIos_TexCacheStats(unsigned long long* outBytes, unsigned long long* outCount);
extern void SohIos_ResCacheStats(unsigned long long* outBytes, unsigned long long* outCount);
extern unsigned long long SohIos_MetalAllocatedBytes(void);
extern unsigned long long SohIos_PendingMipsCount(void);
extern unsigned long long SohIos_MipOrphans(void);
extern volatile int gSohIosMemTrimReq;
extern volatile int gSohIosMemTrims;
extern volatile int gSohIosMemTrimFreedMB;
extern volatile int gSohIosMemTrimEvicted;

long SohIos_PhysFootprintMB(void) {
    // MANDATORY, and not a nicety: os_proc_available_memory() returns 0 in the
    // simulator (no per-process limit), so the slope this whole round is about
    // is invisible there without task_info. task_info works everywhere.
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (long)(info.phys_footprint / (1024 * 1024));
}

// One line, one format, three readers: the heartbeat file, vr-mem.log, and the
// console's `vr mem`. A second format would drift from the first.
int SohIos_MemFields(char* buf, size_t cap) {
    unsigned long long texBytes = 0, texCount = 0, resBytes = 0, resCount = 0;
    SohIos_TexCacheStats(&texBytes, &texCount);
    SohIos_ResCacheStats(&resBytes, &resCount);
    // The engine's own device first; if it has not been registered yet (the
    // renderer has not initialised) fall back to the system default, which on
    // Apple platforms is the same object. Reporting 0 for both is the honest
    // answer and is what the visionOS SIMULATOR does -- its Metal layer does
    // not account currentAllocatedSize. On the headset it is a real number,
    // which is the only place the GPU/CPU split actually has to be read.
    unsigned long long mtlBytes = SohIos_MetalAllocatedBytes();
    if (mtlBytes == 0) {
        static id<MTLDevice> sSohIosFallbackDevice;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sSohIosFallbackDevice = MTLCreateSystemDefaultDevice(); });
        mtlBytes = sSohIosFallbackDevice != nil ? (unsigned long long)sSohIosFallbackDevice.currentAllocatedSize : 0;
    }
    return snprintf(buf, cap,
                    "phys_mb=%ld mtl_mb=%llu texcache_mb=%llu texcache_n=%llu "
                    "rescache_mb=%llu rescache_n=%llu pendmips_n=%llu mip_orphans=%llu "
                    "trims=%d trim_freed_mb=%d trim_evicted=%d",
                    SohIos_PhysFootprintMB(), mtlBytes / (1024ull * 1024ull),
                    texBytes / (1024ull * 1024ull), texCount, resBytes / (1024ull * 1024ull), resCount,
                    SohIos_PendingMipsCount(), SohIos_MipOrphans(), (int)gSohIosMemTrims,
                    (int)gSohIosMemTrimFreedMB, (int)gSohIosMemTrimEvicted);
}

long SohIos_AvailableMemoryMB(void) {
    // os_proc_available_memory returns 0 when the process has no memory limit
    // (the simulator, and some debugger attachments). 0 is reported honestly
    // rather than papered over as "plenty".
    return (long)(os_proc_available_memory() / (1024 * 1024));
}

// R8 part C: crash.txt is APPEND-ONLY now, with a cap.
//
// It used to be O_TRUNC, and that is how the file the user sent back was still
// July's SIGABRT while five memory kills had happened since: a truncating
// writer keeps only the LAST record, and a jetsam writes no record at all, so
// the file simply never changed. History is what makes a dated file useful, so
// records accumulate; past 256 KB the file starts over with a line that says so,
// exactly as vr-mem.log already does, because this file is in Documents and the
// user sees it in Files.
static int SohIos_OpenCrashAppend(void) {
    SohIos_CrashPaths();
    struct stat st;
    if (stat(sSohCrashPath, &st) == 0 && st.st_size > (off_t)(256 * 1024)) {
        int tfd = open(sSohCrashPath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (tfd >= 0) {
            dprintf(tfd, "--- crash.txt rolled at 256 KB (%s) ---\n", sSohBuildStamp);
            close(tfd);
        }
    }
    return open(sSohCrashPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
}

// THE ONE THING A SIGKILL LEAVES BEHIND. A memory kill cannot be caught -- no
// handler runs, no backtrace exists -- so the only evidence a jetsam can
// possibly produce is the fact that the PREVIOUS run never said goodbye. The
// heartbeat file is rewritten every 5 s and a clean shutdown appends an exit
// marker to it; so at launch, a heartbeat file with no marker means the last run
// ended without exiting, and its last line carries the mode, the scene and the
// memory at the moment before it disappeared. That gets appended to crash.txt,
// which is the dated file the user actually looks at.
static void SohIos_RecordPreviousRun(void) {
    SohIos_CrashPaths();
    int fd = open(sSohHeartPath, O_RDONLY);
    if (fd < 0) {
        return; // first ever launch, or the user cleared Documents
    }
    char prev[1024];
    ssize_t got = read(fd, prev, sizeof(prev) - 1);
    close(fd);
    if (got <= 0) {
        return;
    }
    prev[got] = '\0';
    if (strstr(prev, "exit=clean") != NULL) {
        return; // the last run said goodbye; nothing to report
    }
    // Strip the trailing newline so the record reads as one line.
    for (ssize_t i = got - 1; i >= 0 && (prev[i] == '\n' || prev[i] == '\r'); i--) {
        prev[i] = '\0';
    }
    long availMb = -1;
    const char* avail = strstr(prev, "avail_mem_mb=");
    if (avail != NULL) {
        availMb = strtol(avail + 13, NULL, 10);
    }
    long physMb = -1;
    const char* phys = strstr(prev, "phys_mb=");
    if (phys != NULL) {
        physMb = strtol(phys + 8, NULL, 10);
    }
    int cfd = SohIos_OpenCrashAppend();
    if (cfd < 0) {
        return;
    }
    dprintf(cfd, "=== previous run ended without exit ===\n");
    dprintf(cfd, "detected_by=%s build=%s\n", "vr-heartbeat.txt with no exit marker", sSohBuildStamp);
    dprintf(cfd, "last_heartbeat=%s\n", prev);
    // The verdict, spelled out, because the whole point is that the user should
    // not have to know what a jetsam is to read this file.
    if ((availMb >= 0 && availMb < 400) || (physMb > 3000)) {
        dprintf(cfd, "likely=MEMORY KILL (jetsam). The system reclaimed the app; no crash "
                     "handler can run for this. avail_mem_mb=%ld phys_mb=%ld\n",
                availMb, physMb);
    } else {
        dprintf(cfd, "likely=unknown. Memory was not low at the last heartbeat "
                     "(avail_mem_mb=%ld phys_mb=%ld), so this was a hang, a watchdog "
                     "kill, or a swipe-close.\n",
                availMb, physMb);
    }
    dprintf(cfd, "\n");
    fsync(cfd);
    close(cfd);
    NSLog(@"[soh] previous run ended without an exit marker; recorded in crash.txt (avail=%ld phys=%ld)",
          availMb, physMb);
}

// The other half: say goodbye. Appended to the heartbeat file so the next launch
// can tell a clean shutdown from a kill.
void SohIos_MarkCleanExit(const char* why) {
    SohIos_CrashPaths();
    int fd = open(sSohHeartPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "exit=clean why=%s t=%.3f\n", why ? why : "?", CACurrentMediaTime());
        fsync(fd);
        close(fd);
    }
}

// Async-signal-safe enough for a handler: no malloc, no NSLog, no stdio.
// dprintf is not formally async-signal-safe either, but it is what the shipped
// predecessor used and it is the only thing that gets symbol names out.
static void SohIos_WriteCrashRecord(const char* kind, int sig, const char* note) {
    SohIos_CrashPaths();
    if (__sync_lock_test_and_set(&sSohCrashWritten, 1) != 0) {
        return; // first writer wins: a terminate handler that then aborts must
                // not overwrite the named reason with a bare SIGABRT
    }
    void* frames[96];
    int n = backtrace(frames, 96);
    int fd = SohIos_OpenCrashAppend();
    if (fd < 0) {
        return;
    }
    dprintf(fd, "=== %s ===\n", "record");
    dprintf(fd, "kind=%s signal=%d\n", kind, sig);
    dprintf(fd, "build=%s\n", sSohBuildStamp);
    dprintf(fd, "mode=%s scene=%d hud_frames=%d\n", gSohVRMode ? "vr" : "flat-or-panel",
            (int)gSohVRSceneNum, (int)gSohVRHudFrames);
    dprintf(fd, "avail_mem_mb=%ld phys_mb=%ld\n", SohIos_AvailableMemoryMB(), SohIos_PhysFootprintMB());
    dprintf(fd, "thread=%s\n", pthread_main_np() ? "main" : "non-main");
    if (note != NULL && note[0] != '\0') {
        dprintf(fd, "note=%s\n", note);
    }
    dprintf(fd, "--- backtrace ---\n");
    backtrace_symbols_fd(frames, n, fd);
    fsync(fd);
    close(fd);
}

// A plain C function, not a block: NSSetUncaughtExceptionHandler takes a
// function pointer (NSUncaughtExceptionHandler*), and a block is not one.
static void SohIos_ObjCExceptionHandler(NSException* e) {
    char note[256];
    snprintf(note, sizeof(note), "NSException %s: %s", e.name.UTF8String ?: "?", e.reason.UTF8String ?: "");
    SohIos_WriteCrashRecord("objc-exception", 0, note);
}

// R17 part B item 5. 1.0.1.21's crash.txt carries TWO of these on the main
// thread with empty backtraces and no type -- "std::terminate (uncaught C++
// exception)" and nothing else, which is not attributable to anything.
//
// The type IS still available here: __cxa_current_exception_type() is a plain C
// entry point of the Itanium C++ ABI and returns the std::type_info* of the
// exception being handled. Reading a NAME off it is the part that needs care,
// because std::type_info::name() is inline in libc++ and therefore not a symbol
// this Objective-C translation unit could call, and the object's layout is not
// something to guess at inside a handler that is already running after a fatal
// fault. So: every typeinfo object is a NAMED GLOBAL SYMBOL (_ZTISt13runtime_error
// and friends), dladdr() reads that name out of the image's symbol table with no
// layout assumption at all, and __cxa_demangle -- also a plain C entry point --
// turns it into text. A type whose typeinfo is local or stripped simply gives
// dladdr nothing, and the record says so instead of dereferencing anything.
//
// what() is NOT reached this way, and the honest reason is that it needs a catch
// clause: it is a virtual call on the exception OBJECT, and getting at that from
// C means either a C++ translation unit or a guess about libc++'s layout. The
// type name is what makes the next record attributable, and that is this item's
// whole claim -- the cause is explicitly not chased here.
static void SohIos_TerminateHandler(void) {
    char note[320];
    snprintf(note, sizeof(note), "std::terminate (uncaught C++ exception, type unknown)");
    extern void* __cxa_current_exception_type(void);
    extern char* __cxa_demangle(const char* mangled, char* buf, size_t* len, int* status);
    void* ti = __cxa_current_exception_type();
    if (ti != NULL) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        if (dladdr(ti, &info) != 0 && info.dli_sname != NULL) {
            int status = -1;
            char* pretty = __cxa_demangle(info.dli_sname, NULL, NULL, &status);
            snprintf(note, sizeof(note), "std::terminate (uncaught C++ exception): %s",
                     (status == 0 && pretty != NULL) ? pretty : info.dli_sname);
            free(pretty);
        } else {
            snprintf(note, sizeof(note), "std::terminate (uncaught C++ exception): typeinfo at %p, unnamed", ti);
        }
    }
    SohIos_WriteCrashRecord("cxx-terminate", 0, note);
}

static void SohIos_CrashHandler(int sig) {
    SohIos_WriteCrashRecord("signal", sig, sSohCrashNote);
    signal(sig, SIG_DFL);
    raise(sig);
}

// R7: publicly callable so the render loop can report a Metal command-buffer
// error or a compositor invalidation through the SAME record. Neither of those
// is fatal by itself, so this does NOT abort — it records and returns, and the
// note survives into whatever kills us next.
void SohIos_ReportFatalContext(const char* kind, const char* detail) {
    SohIos_CrashPaths();
    snprintf(sSohCrashNote, sizeof(sSohCrashNote), "%s: %s", kind ? kind : "?", detail ? detail : "");
    NSLog(@"[soh] FATAL CONTEXT %s: %s", kind ? kind : "?", detail ? detail : "");
    // Appended, not truncated: several of these in a row before the exit is
    // itself the diagnosis.
    int fd = open(sSohMemPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "%.3f CONTEXT %s: %s avail_mb=%ld\n", CACurrentMediaTime(), kind ? kind : "?",
                detail ? detail : "", SohIos_AvailableMemoryMB());
        close(fd);
    }
}

// The heartbeat. Rewritten whole every 5 s on its own thread, so a hang in the
// game loop stops it and the STOPPED TIMESTAMP is itself evidence.
static void* SohIos_HeartbeatThread(void* unused) {
    (void)unused;
    pthread_setname_np("soh-heartbeat");
    SohIos_CrashPaths();
    for (;;) {
        // While backgrounded the heartbeat must NOT rewrite the file: the
        // clean-exit marker was just appended to it, and one O_TRUNC beat
        // between resign-active and suspension would erase it, turning the
        // next launch's record into a false memory kill. The first foreground
        // beat overwrites the marker, which is exactly when it stops being true.
        if (gSohIosBackgrounded) {
            sleep(5);
            continue;
        }
        long mb = SohIos_AvailableMemoryMB();
        char mem[512];
        SohIos_MemFields(mem, sizeof(mem));
        char buf[1024];
        int n = snprintf(buf, sizeof(buf),
                         "t=%.3f build=%s mode=%s scene=%d hud_frames=%d avail_mem_mb=%ld %s\n",
                         CACurrentMediaTime(), sSohBuildStamp,
                         gSohVRMode ? "vr" : "flat-or-panel", (int)gSohVRSceneNum,
                         (int)gSohVRHudFrames, mb, mem);
        int fd = open(sSohHeartPath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
        if (fd >= 0) {
            (void)!write(fd, buf, (size_t)n);
            fsync(fd);
            close(fd);
        }
        // CAPPED, and it has to be: this file is in Documents, which is
        // UIFileSharingEnabled — the user sees it in Files — and it is appended
        // to every five seconds for as long as the app runs. About 90 bytes a
        // beat is 65 KB an hour, which is nothing for one session and tens of
        // megabytes of somebody's Zelda folder over months. The slope only
        // needs the recent past, so past the cap the file starts over with a
        // line saying so, rather than growing forever or being silently
        // truncated mid-record.
        {
            struct stat st;
            if (stat(sSohMemPath, &st) == 0 && st.st_size > (off_t)(512 * 1024)) {
                int tfd = open(sSohMemPath, O_CREAT | O_WRONLY | O_TRUNC, 0644);
                if (tfd >= 0) {
                    dprintf(tfd, "--- vr-mem.log rolled at 512 KB (%s) ---\n", sSohBuildStamp);
                    close(tfd);
                }
            }
        }
        fd = open(sSohMemPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            (void)!write(fd, buf, (size_t)n);
            close(fd);
        }
        usleep(5 * 1000 * 1000);
    }
    return NULL;
}

// R8 part C: THE MEMORY PRESSURE HOOK, which did not exist at all. A repo-wide
// grep for DISPATCH_SOURCE_TYPE_MEMORYPRESSURE and didReceiveMemoryWarning
// returned nothing before this round: the app rode straight into jetsam with no
// warning acted on, and gfx_texture_cache_clear() had zero callers.
//
// The source fires on a background queue, and NOTHING here may free a texture
// or a resource from that queue -- the game thread owns both caches, and a
// resource destructor can load other resources. So the handler does exactly two
// things: it REQUESTS a trim (a flag the game thread services at the top of its
// next frame, overlay 0045) and it writes a line into vr-mem.log, so a pressure
// event that preceded a death is visible after the fact.
static dispatch_source_t sSohIosPressureSource;

void SohIos_RequestMemoryTrim(const char* why) {
    gSohIosMemTrimReq = 1;
    SohIos_CrashPaths();
    char mem[512];
    SohIos_MemFields(mem, sizeof(mem));
    int fd = open(sSohMemPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "%.3f PRESSURE %s avail_mem_mb=%ld %s\n", CACurrentMediaTime(), why ? why : "?",
                SohIos_AvailableMemoryMB(), mem);
        close(fd);
    }
    NSLog(@"[soh] memory pressure (%s): trim requested. %s", why ? why : "?", mem);
}

static void SohIos_InstallMemoryPressure(void) {
    if (sSohIosPressureSource != nil) {
        return;
    }
    dispatch_queue_t q = dispatch_queue_create("soh.ios.mempressure", DISPATCH_QUEUE_SERIAL);
    sSohIosPressureSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                                   DISPATCH_MEMORYPRESSURE_WARN |
                                                       DISPATCH_MEMORYPRESSURE_CRITICAL,
                                                   q);
    dispatch_source_set_event_handler(sSohIosPressureSource, ^{
        unsigned long flags = dispatch_source_get_data(sSohIosPressureSource);
        SohIos_RequestMemoryTrim((flags & DISPATCH_MEMORYPRESSURE_CRITICAL) ? "critical" : "warn");
    });
    dispatch_resume(sSohIosPressureSource);

    // The UIKit-side second net. It arrives on the main thread and on a
    // different schedule from the dispatch source, and on some deaths it is the
    // only one that arrives at all.
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification* note) {
                                                    SohIos_RequestMemoryTrim("uikit-warning");
                                                }];
    NSLog(@"[soh] memory pressure hook armed (dispatch warn+critical, UIKit warning)");
}

// --- R14: THE AUDIO LAUNCH WATCHDOG ----------------------------------------
//
// The reasoning is beside gSohAudioDeviceId above. Three pieces live here:
//
//   SohIos_AudioPrepareSession()  the AVAudioSession work SDL does not do for
//                                 us and cannot be asked to retry. Called from
//                                 overlay 0053 BEFORE every SDL_OpenAudioDevice.
//   SohIos_AudioNote()            one line into vr-mem.log, the same file the
//                                 heartbeat writes, so a later pull shows
//                                 whether the watchdog fired without anybody
//                                 having to be listening at the time.
//   SohIos_AudioWatchdogThread()  the watchdog itself.
//
// The watchdog measures BYTES ACCEPTED BY THE DEVICE (gSohAudioQueueBytes),
// which is the only counter that distinguishes "audio is leaving the process"
// from "the audio thread is busy". beats can climb, produced can climb, and the
// game can still be silent; queue_bytes cannot climb while it is.
//
// It never reopens a device that is fine: the test is bytes NOT advancing over
// a whole window while the audio thread IS beating, or the device id being 0.
// A full queue is explicitly not unhealthy -- that is 0044's stall case and
// 0044 owns it.
void SohIos_AudioNote(const char* what) {
    SohIos_CrashPaths();
    int fd = open(sSohMemPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "%.3f AUDIO %s dev=%d beats=%llu bytes=%llu fails=%llu reopens=%llu restarts=%d\n",
                CACurrentMediaTime(), what ? what : "?", (int)gSohAudioDeviceId,
                (unsigned long long)gSohAudioBeats, (unsigned long long)gSohAudioQueueBytes,
                (unsigned long long)gSohAudioQueueFails, (unsigned long long)gSohAudioReopens,
                (int)gSohAudioWatchdogRestarts);
        close(fd);
    }
    NSLog(@"[audio] %s dev=%d beats=%llu bytes=%llu fails=%llu reopens=%llu restarts=%d", what ? what : "?",
          (int)gSohAudioDeviceId, (unsigned long long)gSohAudioBeats, (unsigned long long)gSohAudioQueueBytes,
          (unsigned long long)gSohAudioQueueFails, (unsigned long long)gSohAudioReopens,
          (int)gSohAudioWatchdogRestarts);
}

// R17 part B item 2: THE SAME DOOR, FOR THE IMMERSIVE PATH. Every `[imm]` and
// `[SohVR]` breadcrumb in the VR entry path was NSLog only, which is to say
// invisible the moment the headset comes off -- and that is why a black VR
// entry, twice in four launches of 1.0.1.21, left NO evidence at all. This
// writes into the same vr-mem.log the heartbeat and SohIos_AudioNote write, so
// one pull carries audio, memory and the immersive handshake in timestamp
// order, which is the only way to see that the audio restart landed 0.25 s
// before the mode flip.
void SohIos_VrNote(const char* what, const char* detail) {
    SohIos_CrashPaths();
    int fd = open(sSohMemPath, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd >= 0) {
        dprintf(fd, "%.3f VR %s %s\n", CACurrentMediaTime(), what ? what : "?", detail ? detail : "");
        close(fd);
    }
    NSLog(@"[SohVR] %s %s", what ? what : "?", detail ? detail : "");
}

// The transition gate. Swift raises it before openImmersiveSpace and drops it
// after the space is open (or refused), and likewise around the dismiss. It is a
// COUNTER, not a flag, because the 3 s re-anchor timer and a Crown dismissal can
// overlap an entry -- a bool would be cleared by whichever finished first.
static volatile int sSohVRTransitionDepth = 0;
void SohIos_SetVrTransition(int on) {
    if (on) {
        sSohVRTransitionDepth = sSohVRTransitionDepth + 1;
    } else if (sSohVRTransitionDepth > 0) {
        sSohVRTransitionDepth = sSohVRTransitionDepth - 1;
    }
    gSohVRTransition = (sSohVRTransitionDepth > 0);
}

// Called from libultraship (overlay 0053) on whichever thread is opening the
// device. Returns 1 if the session is active for playback, 0 if it is not --
// and 0 is worth logging rather than swallowing, because it is the shape of
// the user's silent launch.
int SohIos_AudioPrepareSession(void) {
    AVAudioSession* s = AVAudioSession.sharedInstance;
    NSError* err = nil;
    if (s.category != AVAudioSessionCategoryPlayback) {
        if (![s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&err]) {
            gSohAudioSessionFails = gSohAudioSessionFails + 1ull;
            NSLog(@"[audio] setCategory(playback) failed: %@", err);
        }
    }
    err = nil;
    if (![s setActive:YES error:&err]) {
        gSohAudioSessionFails = gSohAudioSessionFails + 1ull;
        NSLog(@"[audio] setActive:YES failed: %@", err);
        return 0;
    }
    return 1;
}

// The watchdog. 500 ms cadence; it does nothing at all until the first rendered
// frame, which it reads off gSohAudioBeats -- OTRAudio_Thread blocks on the gfx
// thread's first wake before it beats even once, so "beats > 0" IS "a frame has
// been rendered", with no second frame counter to keep in step.
#define SOHVR_AUDIO_WD_MAX_RESTARTS 4
static void* SohIos_AudioWatchdogThread(void* unused) {
    (void)unused;
    pthread_setname_np("soh-audio-watchdog");
    // Wait for the first frame to drive the audio thread. 60 s is generous: an
    // O2R first launch extracts before it renders anything.
    for (int i = 0; i < 120 && gSohAudioBeats == 0; i++) {
        usleep(500 * 1000);
    }
    if (gSohAudioBeats == 0) {
        gSohAudioWatchdogState = 3;
        SohIos_AudioNote("watchdog: audio thread never beat -- no first frame, or the thread is not alive");
        return NULL;
    }
    // ~3 s of grace after the first frame, then one health decision every 3 s.
    usleep(3 * 1000 * 1000);
    unsigned long long lastBytes = gSohAudioQueueBytes;
    unsigned long long lastBeats = gSohAudioBeats;
    unsigned long long lastFails = gSohAudioQueueFails;
    unsigned long long satRecoveryMark = gSohAudioRecoveries;
    int deadStreak = 0;   // consecutive windows with no beat at all
    int satStreak = 0;    // consecutive windows with the queue pinned full
    int satActed = 0;     // one reopen per saturation episode, not one per window
    int statePrev = -1;
    int firstWindow = 1;  // R17: the first pass decides NOTHING (see below)
    for (;;) {
        // THE WINDOW COMES FIRST, and this ordering IS the R17 fix. R14 read
        // `beats` at the top of the body having sampled `lastBeats` a few
        // nanoseconds earlier, so the first comparison was a value against
        // itself: deadThread was always true and every launch reopened a
        // perfectly healthy device at t+4 s. Sleeping first makes every
        // comparison span a real 3 s window; `firstWindow` is belt and braces
        // on top of it, so that even a future edit that moves this sleep back
        // to the bottom cannot resurrect the false positive.
        usleep(3 * 1000 * 1000);
        unsigned long long bytes = gSohAudioQueueBytes;
        unsigned long long beats = gSohAudioBeats;
        unsigned long long fails = gSohAudioQueueFails;
        int backgrounded = gSohIosBackgrounded;
        int transition = gSohVRTransition;
        int noDevice = (gSohAudioDeviceId == 0);
        int deadThread = (beats == lastBeats);
        // Bytes standing still is only a fault if the audio thread is running
        // and the queue is NOT full: a full queue is 0044's stall case, and a
        // backgrounded app is not supposed to be producing anything.
        int starved = (bytes == lastBytes) && !backgrounded && !deadThread &&
                      ((gSohAudioBuffered + 1584) <= gSohAudioDesired);
        // (d) THE THIRD FAULT, and the one that was invisible by construction.
        // When a reopened unit never starts, the queue saturates: buffered rides
        // at or above desired forever, which the `starved` test above reads as
        // HEALTHY, while 0044's in-thread recover fires every second to no
        // effect and logs only to spdlog. Two consecutive windows is >5 s.
        int saturated = !backgrounded && (gSohAudioDesired > 0) && (gSohAudioBuffered >= gSohAudioDesired);
        deadStreak = deadThread ? (deadStreak + 1) : 0;
        if (saturated) {
            satStreak = satStreak + 1;
        } else {
            satStreak = 0;
            satActed = 0;
            satRecoveryMark = gSohAudioRecoveries;
        }
        // TWO CONSECUTIVE WINDOWS, AND THE FAILURE COUNTER UNCHANGED. A thread
        // that is genuinely not turning cannot be calling SDL_QueueAudio, so a
        // moving `fails` is positive proof the thread is alive whatever the beat
        // counter says. Both halves had to hold to make the 1.0.1.21 line
        // impossible: it had one window and fails=0 sitting still, but the
        // thread beat again 0.7 s later, which the second window would have
        // seen.
        int deadConfirmed = (deadStreak >= 2) && (fails == lastFails);
        int satConfirmed = (satStreak >= 2) && !satActed && (gSohAudioRecoveries != satRecoveryMark);

        int fault = 0;
        const char* what = NULL;
        if (!backgrounded && !firstWindow) {
            if (noDevice) {
                fault = 1;
                what = "watchdog restarted (device never opened)";
            } else if (deadConfirmed) {
                fault = 1;
                what = "watchdog restarted (audio thread not beating for two windows)";
            } else if (starved) {
                fault = 1;
                what = "watchdog restarted (no bytes accepted)";
            } else if (satConfirmed) {
                fault = 1;
                what = "saturated, unit not draining";
            }
        }
        // (c) NEVER RESTART DURING AN IMMERSIVE TRANSITION. The open/dismiss
        // re-anchors the audio session (setIntendedSpatialExperience), and a
        // close+open racing that is how 1.0.1.21's reopen landed 0.25 s before
        // the mode=vr flip. The decision is deferred a window; the streaks are
        // kept, so a REAL fault is acted on 3 s later instead of being lost.
        if (fault && transition) {
            gSohAudioWatchdogSkips = gSohAudioWatchdogSkips + 1;
            SohIos_AudioNote("watchdog deferred a restart -- immersive transition in flight");
            fault = 0;
        }
        if (fault) {
            gSohAudioWatchdogState = 2;
            if (gSohAudioWatchdogRestarts >= SOHVR_AUDIO_WD_MAX_RESTARTS) {
                gSohAudioWatchdogState = 3;
                SohIos_AudioNote("watchdog gave up -- restart budget spent, audio stays silent this run");
                return NULL;
            }
            gSohAudioWatchdogRestarts = gSohAudioWatchdogRestarts + 1;
            if (satConfirmed) {
                gSohAudioSaturations = gSohAudioSaturations + 1;
                satActed = 1;
            }
            // (b) RE-READ THE BEATS IMMEDIATELY BEFORE THE DIRECT CALL. The
            // direct close+open is only safe while the audio thread is not
            // turning, and "not turning" is a fact about NOW, not about a
            // decision taken up to three seconds ago. If it moved in between,
            // the one-writer request path is used instead -- which is what
            // 1.0.1.21 would have done, and it would have done nothing at all,
            // correctly.
            int direct = 0;
            if (deadConfirmed && !noDevice) {
                if (gSohAudioBeats == beats) {
                    direct = 1;
                } else {
                    SohIos_AudioNote("watchdog: the thread woke between decision and act -- using the request path");
                }
            }
            SohIos_AudioNote(what);
            if (direct) {
                // The audio thread is not turning, so it can never service a
                // request flag -- and for the same reason nothing else is
                // inside SDL's device right now, which is what makes calling
                // the reopen from HERE safe. This is the only path that does.
                extern void SohIos_AudioReopenDevice(void);
                SohIos_AudioReopenDevice();
            } else {
                // The audio thread is alive: IT does the reopen, at the top of
                // its next tick, because SDL_CloseAudioDevice underneath a live
                // SDL_QueueAudio is a race and one writer is the rule.
                gSohAudioReopenReq = 1;
            }
        } else if (!backgrounded) {
            gSohAudioWatchdogState = 1;
        }
        // The state, and the session counters, reach vr-mem.log ON CHANGE --
        // not every window (that would bury the heartbeat) and not never (which
        // is what R14 shipped, so `session_fails` climbing was only ever
        // visible to a console nobody had attached).
        if (gSohAudioWatchdogState != statePrev) {
            static const char* const kSohWdNames[4] = { "waiting", "healthy", "unhealthy", "gave-up" };
            char detail[192];
            snprintf(detail, sizeof(detail),
                     "watchdog state -> %s (session_fails=%llu recoveries=%llu saturations=%d skips=%d)",
                     kSohWdNames[(gSohAudioWatchdogState >= 0 && gSohAudioWatchdogState < 4)
                                     ? gSohAudioWatchdogState
                                     : 0],
                     (unsigned long long)gSohAudioSessionFails, (unsigned long long)gSohAudioRecoveries,
                     (int)gSohAudioSaturations, (int)gSohAudioWatchdogSkips);
            SohIos_AudioNote(detail);
            statePrev = gSohAudioWatchdogState;
        }
        lastBytes = bytes;
        lastBeats = beats;
        lastFails = fails;
        firstWindow = 0;
    }
    return NULL;
}

// --- R17 part B (e): THE OBSERVERS THAT DID NOT EXIST -----------------------
//
// grep for AVAudioSessionInterruptionNotification across app/ios before this
// round: nothing. The app prepared the session and opened a device and then
// never listened again -- so an interruption (Siri, a FaceTime call, another
// app taking the route) left SDL's device paused with nobody to unpause it, and
// a media-services reset left a device id that no longer names anything. All
// three are recoverable, and all three are recovered through the ONE-WRITER
// request path: the audio thread does the reopen at the top of its next tick.
// Nothing here closes a device on the main thread.
static void SohIos_InstallAudioObservers(void) {
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    NSNumber* type = note.userInfo[AVAudioSessionInterruptionTypeKey];
                    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
                        SohIos_AudioPrepareSession();
                        gSohAudioReopenReq = 1;
                        SohIos_AudioNote("session interruption ENDED -- session prepared, reopen requested");
                    } else {
                        SohIos_AudioNote("session interruption BEGAN");
                    }
                }];
    [nc addObserverForName:AVAudioSessionRouteChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    NSNumber* reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
                    // A route change does NOT invalidate the device, so this
                    // prepares the session and says so; it does not reopen.
                    // Reopening on every route change would fight the 3 s
                    // spatial re-anchor timer in Swift.
                    SohIos_AudioPrepareSession();
                    char detail[96];
                    snprintf(detail, sizeof(detail), "route change (reason=%lu) -- session prepared",
                             (unsigned long)reason.unsignedIntegerValue);
                    SohIos_AudioNote(detail);
                }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    // The only case where the device id is meaningless rather
                    // than merely paused: everything must be rebuilt.
                    SohIos_AudioPrepareSession();
                    gSohAudioReopenReq = 1;
                    SohIos_AudioNote("mediaServicesWereReset -- forced full reopen requested");
                }];
    NSLog(@"[audio] session observers armed (interruption, route change, media services reset)");
}

static void SohIos_InstallCrashHandler(void) {
    SohIos_CrashPaths();
    // BEFORE the heartbeat thread starts: it opens the heartbeat file O_TRUNC,
    // and the previous run's last line is the entire evidence a memory kill
    // leaves behind.
    SohIos_RecordPreviousRun();
    SohIos_InstallMemoryPressure();
    // An alternate signal stack, per thread that matters most (this one), so a
    // stack-overflow SIGSEGV still has somewhere to run the handler.
    static char sSohAltStack[SIGSTKSZ * 4];
    stack_t ss = { .ss_sp = sSohAltStack, .ss_size = sizeof(sSohAltStack), .ss_flags = 0 };
    sigaltstack(&ss, NULL);

    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP, SIGSYS };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SohIos_CrashHandler;
        sa.sa_flags = SA_ONSTACK | SA_RESETHAND;
        sigemptyset(&sa.sa_mask);
        sigaction(sigs[i], &sa, NULL);
    }

    // ObjC: runs BEFORE any abort, and carries a name and a reason a bare
    // SIGABRT backtrace does not.
    NSSetUncaughtExceptionHandler(SohIos_ObjCExceptionHandler);

    // C++: an uncaught throw reaches std::terminate first and abort() second,
    // and the terminate handler is the only place the exception is still
    // available to name. This translation unit is Objective-C, not C++, so
    // <exception> is not includable here; the Itanium ABI mangling of
    // `std::set_terminate(void(*)())` is stable and is what libc++ exports on
    // every Apple platform, so it is declared by asm name rather than moving
    // the whole shell to ObjC++ (which would change how several thousand lines
    // compile to install one handler).
    {
        typedef void (*soh_terminate_fn)(void);
        extern soh_terminate_fn soh_set_terminate(soh_terminate_fn) __asm("__ZSt13set_terminatePFvvE");
        soh_set_terminate(SohIos_TerminateHandler);
    }

    pthread_t th;
    pthread_create(&th, NULL, SohIos_HeartbeatThread, NULL);
    pthread_detach(th);
    // R14: the audio launch watchdog rides the same arm point. It costs one
    // sleeping thread and it is the only thing in the program that can notice a
    // silent launch while the launch is still happening.
    pthread_create(&th, NULL, SohIos_AudioWatchdogThread, NULL);
    pthread_detach(th);
    // R17 part B: and the session observers, which have to exist before the
    // first interruption rather than after the first report of one.
    SohIos_InstallAudioObservers();
    NSLog(@"[soh] crash capture armed (signals+terminate+objc+heartbeat+audio watchdog), avail_mem=%ld MB",
          SohIos_AvailableMemoryMB());
}

#pragma mark - Input trace (Documents/input-trace.txt)

// A user on iPadOS 26.5 reported that a controller's B button opened and
// closed the SoH menu on every press, on top of acting as the in-game B —
// and that unbinding EVERY controller button in SoH did not stop it. It
// could not: the toggle arrives as a keyboard Escape, not as a controller
// button, so it never passes through SoH's binding system at all. iPadOS
// forges UIKit "cancel" input from a game controller and SDL's UIKit
// backend converted it into SDL_SCANCODE_ESCAPE.
//
// Remote users have no console bridge, so the evidence has to travel by
// itself: Documents/input-trace.txt is reachable from the Files app
// (UIFileSharingEnabled) and can simply be sent back.
//
// It is written LAZILY. On a healthy device nothing is ever forged, so
// creating the file at every launch would put a mystery file in every
// user's Files folder for nothing. Instead lines accumulate in a small
// in-memory ring, and the file only materializes the first time a forged
// key is actually dropped — at which point the buffered environment
// (device, iOS version, keyboard, pads) is flushed ahead of it, so the
// evidence arrives with its context. The file existing at all is itself
// the signal that something is still forging input.
#define SOHIOS_TRACE_MAX_LINES 300
#define SOHIOS_TRACE_RING 60
static void SohIos_Trace(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SohIos_TraceArm(void); // first drop: start writing, flush the ring
static volatile int32_t sSohIosTraceLines; // read unlocked: a race just costs a line
static volatile int32_t sSohIosTraceArmed;

static dispatch_queue_t SohIos_TraceQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("soh.ios.trace", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Queue-confined state — only ever touched inside SohIos_TraceQueue().
static NSMutableArray<NSString*>* sSohIosTraceRing;
static int sSohIosTraceWritten;

static void SohIos_TraceWriteLocked(NSString* line) {
    static NSString* path;
    if (path == nil) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"input-trace.txt"];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    }
    NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:path];
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void SohIos_Trace(NSString* fmt, ...) {
    // Hard stop once full — a forged key can arrive on EVERY button press, so
    // this must cost nothing at all after the cap, not just skip the write.
    if (sSohIosTraceLines >= SOHIOS_TRACE_MAX_LINES) {
        return;
    }
    va_list ap;
    va_start(ap, fmt);
    NSString* msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[SohIosInput] %@", msg);
    double t = CACurrentMediaTime();
    dispatch_async(SohIos_TraceQueue(), ^{
        NSString* line = [NSString stringWithFormat:@"%8.2f  %@\n", t, msg];
        if (!sSohIosTraceArmed) {
            if (sSohIosTraceRing == nil) {
                sSohIosTraceRing = [NSMutableArray array];
            }
            [sSohIosTraceRing addObject:line];
            if (sSohIosTraceRing.count > SOHIOS_TRACE_RING) {
                [sSohIosTraceRing removeObjectAtIndex:0];
            }
            return;
        }
        if (sSohIosTraceWritten >= SOHIOS_TRACE_MAX_LINES) {
            return;
        }
        sSohIosTraceLines = ++sSohIosTraceWritten;
        SohIos_TraceWriteLocked(sSohIosTraceWritten == SOHIOS_TRACE_MAX_LINES
                                    ? [line stringByAppendingString:@"[trace full]\n"]
                                    : line);
    });
}

// Called the first time a forged key is dropped. Everything buffered so far
// becomes the header of the file, then tracing goes live.
static void SohIos_TraceArm(void) {
    if (sSohIosTraceArmed) {
        return;
    }
    dispatch_async(SohIos_TraceQueue(), ^{
        if (sSohIosTraceArmed) {
            return;
        }
        sSohIosTraceArmed = 1;
        SohIos_TraceWriteLocked(@"# input-trace: forged input was detected on this device.\n"
                                @"# Lines above the marker are the buffered lead-up.\n");
        for (NSString* buffered in sSohIosTraceRing) {
            SohIos_TraceWriteLocked(buffered);
            sSohIosTraceWritten++;
        }
        sSohIosTraceRing = nil;
        SohIos_TraceWriteLocked(@"# --- live from here ---\n");
        sSohIosTraceLines = sSohIosTraceWritten;
    });
}

// Stamped into SDL_Keysym's otherwise-unused field so the event filter can
// tell the shell's own menu keystrokes (≡ button, restore dot, soh://menu,
// the bridge) apart from anything the system forged.
#define SOHIOS_KEY_MAGIC 0x5348494Fu // 'SHIO'

#pragma mark - Virtual game controller (input backend)

// An SDL virtual game controller: LUS's SDL controller stack sees it as a
// normal pad (auto-mapped by SDL), so the touch overlay drives the game
// through the same path a physical controller would.
static SDL_Joystick* gVirtualPad = NULL;
static SDL_Window* gSdlWindow = NULL;

// Inject a left-click at window point (x, y) via SDL's thread-safe event
// queue — ImGui consumes SDL mouse events, so this can activate ImGui
// buttons (e.g. the extractor's "Yes") on the simulator where real taps
// are unavailable.
static void SohIos_InjectMouseMotion(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = SDL_GetWindowID(gSdlWindow);
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectMouseButton(int x, int y, BOOL down) {
    if (gSdlWindow == NULL) {
        return;
    }
    SDL_Event e;
    SDL_zero(e);
    e.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
    e.button.windowID = SDL_GetWindowID(gSdlWindow);
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
}

static void SohIos_InjectClick(int x, int y) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEMOTION;
    e.motion.windowID = windowID;
    e.motion.x = x;
    e.motion.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONDOWN;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_PRESSED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    SDL_zero(e);
    e.type = SDL_MOUSEBUTTONUP;
    e.button.windowID = windowID;
    e.button.button = SDL_BUTTON_LEFT;
    e.button.state = SDL_RELEASED;
    e.button.clicks = 1;
    e.button.x = x;
    e.button.y = y;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected click at (%d,%d)", x, y);
}

static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value);

static void SohIos_AttachVirtualPad(void) {
    if (gVirtualPad != NULL) {
        return;
    }
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) != 0) {
        NSLog(@"[SohIosShell] SDL_InitSubSystem(GAMECONTROLLER) failed: %s", SDL_GetError());
        return;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_zero(desc);
    desc.version = SDL_VIRTUAL_JOYSTICK_DESC_VERSION;
    desc.type = SDL_JOYSTICK_TYPE_GAMECONTROLLER;
    desc.naxes = SDL_CONTROLLER_AXIS_MAX;
    desc.nbuttons = SDL_CONTROLLER_BUTTON_MAX;
    desc.name = "SoH Touch Controls";
    int deviceIndex = SDL_JoystickAttachVirtualEx(&desc);
    if (deviceIndex < 0) {
        NSLog(@"[SohIosShell] AttachVirtualEx failed: %s", SDL_GetError());
        return;
    }
    gVirtualPad = SDL_JoystickOpen(deviceIndex);
    // Triggers idle at raw 0 = half-pressed in trigger space (see
    // SohIos_PadAxis below) — drive them to truly-released immediately.
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT, 0);
    NSLog(@"[SohIosShell] virtual pad attached (index %d, isGameController=%d)", deviceIndex,
          SDL_IsGameController(deviceIndex));
}

// Inject a key press+release via SDL's thread-safe event queue.
// Mouse-wheel injection: vertical pans over the open menu scroll it (device
// feedback: swipe-to-scroll; sliders stay horizontal drags).
static void SohIos_InjectWheel(float dy) {
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_MOUSEWHEEL;
    e.wheel.y = (Sint32)dy;
    e.wheel.preciseY = dy;
    e.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
    SDL_PushEvent(&e);
}

// D-030: the ornament's Menu button (SwiftUI — the only reachable control
// surface in 3D; the touch overlay's ≡ is under the parked window's curtain).
void SohIos_ToggleMenuKey(void);
static void SohIos_InjectKey(SDL_Keycode sym, SDL_Scancode scancode) {
    if (gSdlWindow == NULL) {
        return;
    }
    Uint32 windowID = SDL_GetWindowID(gSdlWindow);
    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_KEYDOWN;
    e.key.windowID = windowID;
    e.key.state = SDL_PRESSED;
    e.key.keysym.sym = sym;
    e.key.keysym.scancode = scancode;
    e.key.keysym.unused = SOHIOS_KEY_MAGIC; // survives the Escape guard below
    SDL_PushEvent(&e);
    e.type = SDL_KEYUP;
    e.key.state = SDL_RELEASED;
    SDL_PushEvent(&e);
    NSLog(@"[SohIosShell] injected key %d", (int)sym);
}

// Identity mapping: virtual joystick axis/button N == SDL_CONTROLLER_*_N.
static void SohIos_PadAxis(SDL_GameControllerAxis axis, Sint16 value) {
    if (gVirtualPad == NULL) {
        return;
    }
    // THE Z ROOT CAUSE (device feedback 2026-07-12, found via the `pads`
    // dump): SDL translates full-range raw axes to trigger space as
    // (raw+32768)/2, so raw 0 reads as HALF-PRESSED (16383) — above LUS's
    // press threshold. The virtual pad was therefore holding Z forever:
    // touch-Z "stuck" after one tap, and gamepad Z looked dead because the
    // bit was already set so real presses produced no new edge. Triggers
    // take raw -32768 for released, +32767 for pressed.
    if (axis == SDL_CONTROLLER_AXIS_TRIGGERLEFT || axis == SDL_CONTROLLER_AXIS_TRIGGERRIGHT) {
        value = (value <= 0) ? SDL_JOYSTICK_AXIS_MIN : SDL_JOYSTICK_AXIS_MAX;
    }
    SDL_JoystickSetVirtualAxis(gVirtualPad, axis, value);
}

static void SohIos_PadButton(SDL_GameControllerButton button, BOOL down) {
    if (gVirtualPad) {
        SDL_JoystickSetVirtualButton(gVirtualPad, button, down ? SDL_PRESSED : SDL_RELEASED);
    }
}

// Self-test (env SOH_SELFTEST): repeated button presses so flows can be
// driven on the simulator, where scripted taps are unavailable.
//   SOH_SELFTEST=1|START → START presses T+15s..T+33s (title → file select)
//   SOH_SELFTEST=A       → A presses T+10s..T+28s (confirm ImGui popups,
//                          e.g. the extractor's "Use this rom?"; needs
//                          gSettings.ControlNav=1 for ImGui gamepad nav)
static void SohIos_ScheduleSelfTest(void) {
    const char* mode = getenv("SOH_SELFTEST");
    if (mode == NULL) {
        return;
    }
    // SOH_SELFTEST=CLICK:x1,y1[;x2,y2…] → inject left-clicks cycling through
    // the given window points, T+8s onward (drives ImGui buttons across a
    // multi-popup flow like the extractor's).
    if (strncmp(mode, "CLICK:", 6) == 0) {
        static int pts[8][2];
        int n = 0;
        const char* p = mode + 6;
        while (n < 8 && sscanf(p, "%d,%d", &pts[n][0], &pts[n][1]) == 2) {
            n++;
            p = strchr(p, ';');
            if (p == NULL) {
                break;
            }
            p++;
        }
        if (n > 0) {
            const int rounds = 12;
            NSLog(@"[SohIosShell] SELFTEST armed: %d click point(s), %d rounds from T+8s", n, rounds);
            const int nPts = n;
            for (int i = 0; i < rounds; i++) {
                double at = 8.0 + 2.0 * i;
                int idx = i % nPts;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                               dispatch_get_main_queue(),
                               ^{ SohIos_InjectClick(pts[idx][0], pts[idx][1]); });
            }
        }
        return;
    }
    // SOH_SELFTEST=KEY:esc → inject one Escape key press at T+12s (opens the
    // SoH menu; on-phone this will be a gesture/HUD button later).
    if (strcmp(mode, "KEY:esc") == 0) {
        NSLog(@"[SohIosShell] SELFTEST armed: Escape at T+12s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); });
        return;
    }
    SDL_GameControllerButton btn = SDL_CONTROLLER_BUTTON_START;
    double firstAt = 15.0;
    if (strcmp(mode, "A") == 0) {
        btn = SDL_CONTROLLER_BUTTON_A;
        firstAt = 10.0;
    }
    NSLog(@"[SohIosShell] SELFTEST armed: 8x button %d from T+%.0fs", btn, firstAt);
    for (int i = 0; i < 8; i++) {
        double at = firstAt + 2.5 * i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[SohIosShell] SELFTEST press #%d (btn %d)", i, btn);
            SohIos_PadButton(btn, YES);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ SohIos_PadButton(btn, NO); });
        });
    }
}

#pragma mark - ROM onboarding (document picker)

static NSString* SohIos_DocumentsPath(void) {
    const char* home = getenv("HOME");
    return [NSString stringWithFormat:@"%s/Documents", home ? home : "/tmp"];
}

static BOOL SohIos_DocumentsHasExt(NSArray<NSString*>* exts) {
    NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:SohIos_DocumentsPath() error:nil];
    for (NSString* f in files) {
        if ([exts containsObject:f.pathExtension.lowercaseString]) {
            return YES;
        }
    }
    return NO;
}

// Native first-run flow: if there's no ROM and no extracted archive yet,
// offer a document picker (Files/iCloud) and copy the chosen ROM into
// Documents with sane protection/permissions . The in-engine
// extractor popups then find it and do the rest.
@interface SohIosOnboarding : NSObject <UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

static SohIosOnboarding* gOnboarding = nil;

@implementation SohIosOnboarding

+ (void)maybePresentIn:(UIWindow*)window {
    if (SohIos_DocumentsHasExt(@[ @"z64", @"n64", @"v64" ]) || SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        return; // already has a ROM or is already extracted
    }
    gOnboarding = [SohIosOnboarding new];
    gOnboarding.window = window;
    UIAlertController* a =
        [UIAlertController alertControllerWithTitle:@"Ocarina of Time ROM needed"
                                            message:@"Pick your legally-owned OoT ROM (.z64 / .n64 / .v64). It will "
                                                    @"be copied into this app's Documents folder, then the game will "
                                                    @"offer to extract it."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Choose ROM…"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* _) { [gOnboarding presentPicker]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later (drop it in via Files)"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [window.rootViewController presentViewController:a animated:YES completion:nil];
}

- (void)presentPicker {
    NSMutableArray<UTType*>* types = [NSMutableArray array];
    for (NSString* e in @[ @"z64", @"n64", @"v64" ]) {
        UTType* t = [UTType typeWithFilenameExtension:e];
        if (t != nil) {
            [types addObject:t];
        }
    }
    if (types.count == 0) {
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController* p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types
                                                                                                    asCopy:YES];
    p.delegate = self;
    [self.window.rootViewController presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)c didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count == 0) {
        return;
    }
    NSURL* src = urls.firstObject; // asCopy:YES => already a local temp copy
    NSString* dst = [SohIos_DocumentsPath() stringByAppendingPathComponent:src.lastPathComponent];
    NSError* err = nil;
    [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
    BOOL ok = [NSFileManager.defaultManager moveItemAtPath:src.path toPath:dst error:&err];
    if (ok) {
        // user-imported data gets NSFileProtectionNone + sane modes.
        [NSFileManager.defaultManager setAttributes:@{
            NSFileProtectionKey : NSFileProtectionNone,
            NSFilePosixPermissions : @0644
        } ofItemAtPath:dst error:nil];
    }
    NSLog(@"[SohIosShell] ROM import %@ -> %@ (%@)", ok ? @"OK" : @"FAILED", dst, err);
    UIAlertController* a = [UIAlertController
        alertControllerWithTitle:ok ? @"ROM added" : @"Import failed"
                         message:ok ? @"Now answer the game's prompts (Yes) to extract and play."
                                    : err.localizedDescription
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self.window.rootViewController presentViewController:a animated:YES completion:nil];
}

@end

// 3D menu toggle: a DIRECT request the engine consumes (Fast3dWindow calls
// GetMenu()->ToggleVisibility()). The old esc-key injection dies on device in
// 3D: the immersive space steals input focus, SDL's window reports focus
// lost, and ImGui clears/ignores key state — sim keeps focus, so every sim
// gate passed while the device silently dropped the key.
volatile int gSoh3DMenuToggleReq = 0;
void SohIos_ToggleMenuKey(void) {
    extern volatile int gSoh3DMode;
    if (gSoh3DMode != 0) {
        gSoh3DMenuToggleReq = 1;
    } else {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    }
}

void SohIos_SetAudioAnchorStatus(int s) {
    extern volatile int gSohAudioAnchorStatus;
    gSohAudioAnchorStatus = s;
}

#pragma mark - Remote console bridge (launch-gated TCP)

// D-040: the bridge is an UNAUTHENTICATED command server (input injection,
// CVar writes, crash.txt/log reads) and soh://console can switch it on from
// any tapped link — so it is COMPILED OUT unless the build asks for it.
// Public/release builds ship without it and cannot be made to listen; dev
// (simulator) and the maintainer's OTA builds set -DSOH_REMOTE_CONSOLE=ON.
#ifndef SOH_REMOTE_CONSOLE
#define SOH_REMOTE_CONSOLE 0
#endif

#if SOH_REMOTE_CONSOLE

// SOH_CONSOLE=1 → listen on TCP 8765 and accept newline-delimited commands.
// Converts "needs hands" into "scriptable" for remote testing .
// Protocol (one command per line, replies "ok"/"err …"):
//   ping                 liveness
//   btn NAME [ms]        press virtual pad button (A B START L R) for ms (default 200)
//   z [ms]               press Z (left trigger axis) for ms
//   stick X Y [ms]       deflect stick, floats -1..1, for ms (default 500)
//   click X Y            SDL mouse click at window point
//   key esc              Escape (toggles the SoH menu)
//   thermal              current thermal state
static NSString* SohIos_HandleConsoleLine(NSString* line) {
    NSArray<NSString*>* tok = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByString:@" "];
    if (tok.count == 0 || tok[0].length == 0) {
        return @"err empty";
    }
    NSString* cmd = tok[0].lowercaseString;
    if ([cmd isEqualToString:@"ping"]) {
        return @"ok";
    }
    if ([cmd isEqualToString:@"thermal"]) {
        return [NSString stringWithFormat:@"ok thermal=%d", SohIos_ThermalState()];
    }
    // R2a: the build stamp, over the bridge. The spec asks for a stamp
    // asserted at launch; the device dev loop needs the same answer from the
    // Mac, because "did my build actually get installed and started" is the
    // first question of every headset session and the ONLY way to be sure the
    // dumps that follow come from the build under test.
    if ([cmd isEqualToString:@"ver"]) {
        NSDictionary* sohInfo = NSBundle.mainBundle.infoDictionary;
        int sohMode = 0;
#if TARGET_OS_VISION
        // The tri-state (spec D1) exists only where the immersive shell is
        // compiled; SohIosShell.m is linked on iPhone too, where an unguarded
        // reference would not resolve.
        extern int Soh_GetMode(void);
        sohMode = Soh_GetMode();
#endif
        return [NSString stringWithFormat:@"ok ver=%@ build=%@ bundle=%@ os=%@ %@ mode=%d",
                                          sohInfo[@"CFBundleShortVersionString"] ?: @"?",
                                          sohInfo[@"CFBundleVersion"] ?: @"?",
                                          sohInfo[@"CFBundleIdentifier"] ?: @"?",
                                          UIDevice.currentDevice.systemName,
                                          UIDevice.currentDevice.systemVersion, sohMode];
    }
    if ([cmd isEqualToString:@"drawable"]) {
        float t = 0;
#if TARGET_OS_VISION
        t = gSohIosVisionLongEdge;
#endif
        return [NSString stringWithFormat:
                @"ok drawable=%.0fx%.0f contentsScale=%.2f target=%.0f cvar=%d msaa=%d gpu_ms=%.2f engine2d=%dx%d cur=%dx%d",
                gSohIosDrawableW, gSohIosDrawableH, gSohIosContentsScale, t,
                CVarGetInteger("gSohIos.VisionLongEdge", -1), CVarGetInteger("gMSAAValue", 1), gSohIosGpuMs,
                gSoh3DDbg2DW, gSoh3DDbg2DH, gSoh3DDbgCurW, gSoh3DDbgCurH];
    }
    if ([cmd isEqualToString:@"cvar"] && tok.count >= 2) {
        // Live integer CVar get/set — `cvar gSohIos.AsyncShaders 0` is the
        // async-shader kill switch for stutter A/B without a rebuild.
        const char* name = tok[1].UTF8String;
        BOOL isFloat = tok.count >= 3 && [tok[2] containsString:@"."];
        if (tok.count >= 3) {
            if (isFloat) {
                extern void CVarSetFloat(const char* n, float v);
                CVarSetFloat(name, tok[2].floatValue);
            } else {
                CVarSetInteger(name, tok[2].intValue);
            }
            extern void CVarSave(void);
            CVarSave();
        }
        if (isFloat) {
            return [NSString stringWithFormat:@"ok %@=%.3f", tok[1], CVarGetFloat(name, -999.0f)];
        }
        return [NSString stringWithFormat:@"ok %@=%d", tok[1], CVarGetInteger(name, -999)];
    }
    if ([cmd isEqualToString:@"shaderclear"]) {
        // Wipe Library/Caches + tmp (Documents/game data untouched) so the
        // next launch recompiles shaders COLD — the repeatable stutter A/B
        // (2ship findings doc). Relaunch after running this.
        NSFileManager* fm = NSFileManager.defaultManager;
        int removed = 0;
        NSArray<NSString*>* dirs = @[
            NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject ?: @"",
            NSTemporaryDirectory() ?: @""
        ];
        for (NSString* dir in dirs) {
            if (dir.length == 0) {
                continue;
            }
            for (NSString* entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if ([fm removeItemAtPath:[dir stringByAppendingPathComponent:entry] error:nil]) {
                    removed++;
                }
            }
        }
        return [NSString stringWithFormat:@"ok cleared %d entries (relaunch to recompile cold)", removed];
    }
    if ([cmd isEqualToString:@"stickregion"] && tok.count >= 3) {
        // Region-logic probe (idb HID cannot reach visionOS app windows, so
        // the spawn-region change is asserted directly; the delivery path is
        // unchanged code proven by the working buttons).
        CGFloat X = tok[1].floatValue, Y = tok[2].floatValue;
        extern int SohIos_ProbeStickRegion(CGFloat x, CGFloat y, CGSize* outBounds);
        __block int r = -1;
        __block CGSize vb = CGSizeZero;
        dispatch_async(dispatch_get_main_queue(), ^{
            CGSize b = CGSizeZero;
            int rr = SohIos_ProbeStickRegion(X, Y, &b);
            vb = b;
            r = rr;
        });
        for (int i = 0; i < 200 && r == -1; i++) {
            usleep(10 * 1000);
        }
        return [NSString stringWithFormat:@"ok in=%d bounds=%.0fx%.0f", r, vb.width, vb.height];
    }
    if ([cmd isEqualToString:@"hideprobe"]) {
        // Customizer hide/show gate (list / select KEY / chiptap / tapedit X Y
        // / save). SohIos_LayoutHideProbe hops to the main thread.
        extern NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args);
        NSArray<NSString*>* args =
            tok.count >= 2 ? [tok subarrayWithRange:NSMakeRange(1, tok.count - 1)] : @[];
        return SohIos_LayoutHideProbe(args);
    }
    if ([cmd isEqualToString:@"winsize"] && tok.count >= 3) {
        // Repro instrument (round 14): drive the same window-size cycle the
        // device's 3D parking performs, on the sim. (Round 16 correction:
        // this handler previously prefix-matched against the first TOKEN and
        // could never fire — the round-15 park repro actually exercised the
        // ENTRY path's own geometry request, which the sim honors.)
        CGFloat W = tok[1].floatValue, H = tok[2].floatValue;
        BOOL force = tok.count >= 4 && [tok[3] isEqualToString:@"force"];
        dispatch_async(dispatch_get_main_queue(), ^{
#if TARGET_OS_VISION
            extern void Soh_RequestWindowSize(CGSize size);
            Soh_RequestWindowSize(CGSizeMake(W, H));
#endif
            if (force) {
                UIView* mv = nil;
                UIWindow* w = SohIos_GameWindowWithMetal(&mv);
                if (w != nil) {
                    w.frame = CGRectMake(w.frame.origin.x, w.frame.origin.y, W, H);
                    for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
                        v.frame = w.bounds;
                    }
                    [w.rootViewController.view setNeedsLayout];
                    [w.rootViewController.view layoutIfNeeded];
                }
            }
        });
        return @"ok winsize";
    }
    if ([cmd isEqualToString:@"geom"]) {
        // Every layer of the 2D window geometry, numerically (round 13: the
        // restore over-crop was only diagnosable by eye — never again).
        extern int SohIos_GeomReport(char* buf, int cap);
        static char gbuf[512];
        __block BOOL filled = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            SohIos_GeomReport(gbuf, (int)sizeof(gbuf));
            filled = YES;
        });
        for (int i = 0; i < 200 && !filled; i++) {
            usleep(10 * 1000); // async+poll: bridge thread must never sync onto main
        }
        return filled ? [NSString stringWithFormat:@"ok %s", gbuf] : @"error: main queue stalled";
    }
    if ([cmd isEqualToString:@"menu"]) {
        SohIos_ToggleMenuKey(); // direct-toggle in 3D, esc injection in 2D
        return @"ok (toggled)";
    }
    if ([cmd isEqualToString:@"audio"]) {
        extern volatile int gSohAudioAnchorStatus; // 0 unset / 1 ok / 2 threw
        AVAudioSession* s = AVAudioSession.sharedInstance;
        return [NSString stringWithFormat:@"ok category=%@ mode=%@ otherAudio=%d anchor=%d",
                                          s.category, s.mode, (int)s.isOtherAudioPlaying,
                                          gSohAudioAnchorStatus];
    }
    if ([cmd isEqualToString:@"fidelity"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Documents/vp3d-fidelity.log", getenv("HOME")];
        NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return content.length ? [@"ok\n" stringByAppendingString:content] : @"ok (no fidelity log yet — enter 3D first)";
    }
    if ([cmd isEqualToString:@"crashlog"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Documents/crash.txt", getenv("HOME")];
        NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        return content.length ? [@"ok\n" stringByAppendingString:content] : @"ok (no crash.txt)";
    }
#if TARGET_OS_VISION
    if ([cmd isEqualToString:@"3d"]) {
        // Remote enter/exit for the stereo mode (the ornament button is system
        // chrome no injected touch can reach). NEVER dispatch_sync from bridge
        // handlers — the game loop owns the main thread.
        extern void Soh_Enter3D(bool on);
        extern int Soh_Get3DMode(void);
        extern volatile int gSoh3DRunning;
        extern volatile int gSoh3DEyeFrames[2];
        extern volatile int gSoh3DDrainTicks, gSoh3DGcdProbe;
        if (tok.count >= 2) {
            // Direct call: gSoh3DMode is a volatile flag and the Swift side
            // marshals to the main actor itself. Also enqueue a GCD probe.
            BOOL on = [tok[1] isEqualToString:@"on"];
            Soh_Enter3D(on);
            dispatch_async(dispatch_get_main_queue(), ^{ gSoh3DGcdProbe++; });
            return @"ok (direct)";
        }
        return [NSString
            stringWithFormat:@"ok mode=%d loop=%d eyeL=%d eyeR=%d camDist=%.1f conv=%.1f sep=%.2f drain=%d probe=%d menuVis=%d menuBuilds=%d menuVtx=%d menuDraws=%d",
                             Soh_Get3DMode(), gSoh3DRunning, gSoh3DEyeFrames[0], gSoh3DEyeFrames[1], gSoh3DCamDist,
                             gSoh3DDbgConv, gSoh3DDbgSep, gSoh3DDrainTicks, gSoh3DGcdProbe, gSoh3DDbgMenuVis,
                             gSoh3DDbgMenuBuilds, gSoh3DDbgMenuVtx, gSoh3DDbgMenuDraws];
    }
    if ([cmd isEqualToString:@"vr"]) {
        // VR-spec D10: the diagnostics dump family. Never dispatch_sync from
        // a bridge handler — every path below reads published state or sets a
        // flag the compositor loop consumes.
        extern NSString* SohVR_HandleCommand(NSArray<NSString*>* args);
        NSArray<NSString*>* args =
            tok.count >= 2 ? [tok subarrayWithRange:NSMakeRange(1, tok.count - 1)] : @[];
        return SohVR_HandleCommand(args);
    }
#endif
    if ([cmd isEqualToString:@"logtail"]) {
        int lines = tok.count >= 2 ? MAX(10, MIN(400, tok[1].intValue)) : 80;
        NSString* dir = [NSString stringWithFormat:@"%s/Documents/logs", getenv("HOME")];
        NSArray* files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
        for (NSString* f in files) {
            if ([f hasSuffix:@".log"]) {
                NSString* content =
                    [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:f]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
                NSArray* all = [content componentsSeparatedByString:@"\n"];
                NSUInteger start = all.count > (NSUInteger)lines ? all.count - lines : 0;
                return [@"ok\n" stringByAppendingString:
                            [[all subarrayWithRange:NSMakeRange(start, all.count - start)]
                                componentsJoinedByString:@"\n"]];
            }
        }
        return @"ok (no log files)";
    }
    if ([cmd isEqualToString:@"bg"]) {
        return [NSString stringWithFormat:@"ok backgrounded=%d", SohIos_IsBackgrounded()];
    }
    if ([cmd isEqualToString:@"pads"]) {
        // Controller diagnostics: name, mapping, live axes — the Z-dead-on-
        // gamepad investigation reads this on sim AND on device.
        NSMutableString* out = [NSMutableString stringWithString:@"ok "];
        for (int i = 0; i < SDL_NumJoysticks(); i++) {
            if (!SDL_IsGameController(i)) {
                [out appendFormat:@"[j%d %s notGC] ", i, SDL_JoystickNameForIndex(i) ?: "?"];
                continue;
            }
            SDL_GameController* gc = SDL_GameControllerOpen(i); // refcounted; close below only releases our ref
            if (gc == NULL) {
                continue;
            }
            char* map = SDL_GameControllerMapping(gc);
            NSString* mapStr = map ? [NSString stringWithUTF8String:map] : @"none";
            if (map != NULL) {
                SDL_free(map);
            }
            if (mapStr.length > 260) {
                mapStr = [[mapStr substringToIndex:260] stringByAppendingString:@"..."];
            }
            [out appendFormat:@"[gc%d %s axes=%d,%d,%d,%d,%d,%d map=%@] ", i, SDL_GameControllerName(gc) ?: "?",
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_LEFTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTX),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_RIGHTY),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERLEFT),
                              SDL_GameControllerGetAxis(gc, SDL_CONTROLLER_AXIS_TRIGGERRIGHT), mapStr];
            SDL_GameControllerClose(gc);
        }
        return out;
    }
    if ([cmd isEqualToString:@"seq"]) {
        uint32_t ids = SohIos_ActiveSeqIds();
        return [NSString stringWithFormat:@"ok bgm=0x%04x fanfare=0x%04x", ids & 0xFFFF, (ids >> 16) & 0xFFFF];
    }
    if ([cmd isEqualToString:@"key"] && tok.count >= 2 && [tok[1] isEqualToString:@"esc"]) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        return @"ok";
    }
    if ([cmd isEqualToString:@"click"] && tok.count >= 3) {
        SohIos_InjectClick(tok[1].intValue, tok[2].intValue);
        return @"ok";
    }
    if ([cmd isEqualToString:@"z"]) {
        int ms = tok.count >= 2 ? tok[1].intValue : 200;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 32767);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0); });
        return @"ok";
    }
    if ([cmd isEqualToString:@"stick"] && tok.count >= 3) {
        float x = tok[1].floatValue, y = tok[2].floatValue;
        int ms = tok.count >= 4 ? tok[3].intValue : 500;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, (Sint16)(MAX(-1.f, MIN(1.f, x)) * 32767));
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, (Sint16)(MAX(-1.f, MIN(1.f, y)) * 32767));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
        });
        return @"ok";
    }
    // VR R3: the RIGHT stick, so the turn (and the C-button provenance mask that
    // overlay 0039 rev3 applies to it) can be driven and asserted from the
    // simulator. Same shape as `stick`.
    if ([cmd isEqualToString:@"rstick"] && tok.count >= 3) {
        float x = tok[1].floatValue, y = tok[2].floatValue;
        int ms = tok.count >= 4 ? tok[3].intValue : 500;
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTX, (Sint16)(MAX(-1.f, MIN(1.f, x)) * 32767));
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTY, (Sint16)(MAX(-1.f, MIN(1.f, y)) * 32767));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTX, 0);
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTY, 0);
        });
        return @"ok";
    }
    if ([cmd isEqualToString:@"btn"] && tok.count >= 2) {
        static NSDictionary<NSString*, NSNumber*>* map = nil;
        if (map == nil) {
            map = @{
                @"a" : @(SDL_CONTROLLER_BUTTON_A),
                @"b" : @(SDL_CONTROLLER_BUTTON_B),
                @"start" : @(SDL_CONTROLLER_BUTTON_START),
                @"l" : @(SDL_CONTROLLER_BUTTON_LEFTSHOULDER),
                @"r" : @(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER),
            };
        }
        NSNumber* b = map[tok[1].lowercaseString];
        if (b == nil) {
            return @"err unknown button";
        }
        int ms = tok.count >= 3 ? tok[2].intValue : 200;
        SDL_GameControllerButton btn = (SDL_GameControllerButton)b.intValue;
        SohIos_PadButton(btn, YES);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(),
                       ^{ SohIos_PadButton(btn, NO); });
        return @"ok";
    }
    return @"err unknown command";
}

static void SohIos_StartConsoleBridge(BOOL force) {
    // Gated three ways: SOH_CONSOLE env (tool launches: simctl/devicectl), a
    // `console_enabled` file in Documents — creatable/deletable in the Files
    // app, so user-launched builds (OTA/TestFlight) can opt in without a
    // computer — or force=YES (soh://console deep link on a running app).
    static BOOL started = NO; // all callers are on the main thread
    if (started) {
        return;
    }
    BOOL fileGate = NO;
    const char* home = getenv("HOME");
    if (home != NULL) {
        // Accept a .txt suffix too — iOS Files can't create extensionless
        // files without a rename dance.
        NSString* docs = [NSString stringWithFormat:@"%s/Documents", home];
        fileGate = [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled"]] ||
                   [NSFileManager.defaultManager
                       fileExistsAtPath:[docs stringByAppendingPathComponent:@"console_enabled.txt"]];
    }
    if (!force && getenv("SOH_CONSOLE") == NULL && !fileGate) {
        return; // launch-gated: no listener unless explicitly requested
    }
    started = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int srv = socket(AF_INET, SOCK_STREAM, 0);
        if (srv < 0) {
            NSLog(@"[SohIosShell] bridge socket failed: %d", errno);
            return;
        }
        int one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = INADDR_ANY;
        addr.sin_port = htons(8765);
        BOOL bound = NO;
        for (int i = 0; i < 10 && !bound; i++) { // bind retry (predecessor pattern)
            bound = bind(srv, (struct sockaddr*)&addr, sizeof(addr)) == 0;
            if (!bound) {
                usleep(500 * 1000);
            }
        }
        if (!bound || listen(srv, 1) != 0) {
            NSLog(@"[SohIosShell] bridge bind/listen failed: %d", errno);
            close(srv);
            return;
        }
        NSLog(@"[SohIosShell] console bridge listening on :8765");
        for (;;) {
            int cli = accept(srv, NULL, NULL);
            if (cli < 0) {
                continue;
            }
            // A client that disconnects before a slow handler replies (e.g.
            // stickregion blocks up to 2 s; logtail writes large replies; a
            // tailnet drop mid-reply) must get EPIPE, not SIGPIPE — the
            // crash handler doesn't cover SIGPIPE, so the default action
            // killed the whole app with no crash.txt (SpaghettiKart
            // docs/SHELL-SIGPIPE-ADVISORY.md; sim-verified kill there).
            int nosig = 1;
            setsockopt(cli, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            NSLog(@"[SohIosShell] bridge client connected");
            FILE* f = fdopen(cli, "r");
            char line[512];
            while (f != NULL && fgets(line, sizeof(line), f) != NULL) {
                NSString* resp = SohIos_HandleConsoleLine([NSString stringWithUTF8String:line] ?: @"");
                dprintf(cli, "%s\n", resp.UTF8String);
            }
            if (f != NULL) {
                fclose(f);
            }
            NSLog(@"[SohIosShell] bridge client disconnected");
        }
    });
}

#else // !SOH_REMOTE_CONSOLE — public build: no listener exists at all.
static void SohIos_StartConsoleBridge(BOOL force) {
    (void)force;
}
#endif

#pragma mark - Deep links (soh:// URL scheme)

static void SohIos_HandleDeepLink(NSString* url) {
    NSLog(@"[SohIosShell] deep link: %@", url);
#if SOH_REMOTE_CONSOLE
    if ([url hasPrefix:@"soh://console"]) {
        SohIos_StartConsoleBridge(YES); // one-tap remote debugging opt-in
    } else
#endif // public builds: soh://console is not a recognised link at all
    if ([url hasPrefix:@"soh://menu"]) {
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
    } else {
        NSLog(@"[SohIosShell] unknown deep link ignored: %@", url);
    }
}

// SDL2's UIKit app delegate delivers incoming custom-scheme URLs as
// SDL_DROPFILE events (application:openURL: -> SDL_SendDropFile). A filter
// (not a watch) can consume them before LUS's FileDropMgr mistakes the URL
// for a file path. NOTE (verified by lldb breakpoints on this runtime):
// iOS 26-era UIKit never calls the legacy application:openURL: on this app
// at all — it runs a scene session (nil delegate) and delivers URL opens
// only via scene:openURLContexts:. The SohIosSceneDelegate below is the
// path that actually fires; this filter stays as belt-and-braces for
// runtimes that still use the legacy delegate.
static int SohIos_EventFilter(void* userdata, SDL_Event* event) {
    if (event->type == SDL_DROPFILE && event->drop.file != NULL &&
        strncmp(event->drop.file, "soh://", 6) == 0) {
        NSString* url = [NSString stringWithUTF8String:event->drop.file];
        SDL_free(event->drop.file);
        event->drop.file = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_HandleDeepLink(url); });
        return 0; // consumed
    }
    // Stray-Escape guard. LUS toggles the menu on Escape (Gui.cpp), and on
    // iOS the ONLY legitimate sources of Escape are this shell's own
    // injections — the ≡ button, the restore dot, the deep link, the bridge.
    // Anything else is forged: iPadOS turns a game controller's B into a
    // UIKit "cancel", which SDL's UIKit backend used to hand over as a
    // keyboard Escape, so B opened/closed the menu on every press. The SDL
    // dependency patch closes both forgery routes at the source; this is
    // the backstop that holds no matter what synthesizes the key.
    if ((event->type == SDL_KEYDOWN || event->type == SDL_KEYUP) &&
        event->key.keysym.scancode == SDL_SCANCODE_ESCAPE && event->key.keysym.unused != SOHIOS_KEY_MAGIC) {
        // Arm first: both hop the same serial queue, so the buffered context
        // is flushed ahead of this line rather than racing it.
        SohIos_TraceArm();
        SohIos_Trace(@"DROPPED forged escape (%@) — a controller or the system sent Escape",
                     event->type == SDL_KEYDOWN ? @"down" : @"up");
        return 0; // consumed: the menu does not move
    }
    if (event->type == SDL_KEYDOWN) {
        SohIos_Trace(@"key down scancode=%d sym=%d%@", (int)event->key.keysym.scancode, (int)event->key.keysym.sym,
                     event->key.keysym.unused == SOHIOS_KEY_MAGIC ? @" (shell)" : @"");
    }
    // First few physical-pad presses only: enough to prove the pad's normal
    // path works, without tracing a whole play session.
    if (event->type == SDL_CONTROLLERBUTTONDOWN) {
        static int seen;
        if (seen++ < 24) {
            SohIos_Trace(@"pad button %d down (joystick %d)", (int)event->cbutton.button, (int)event->cbutton.which);
        }
    }
    if (event->type == SDL_CONTROLLERDEVICEADDED) {
        SohIos_Trace(@"pad added: index %d", (int)event->cdevice.which);
    }
    return 1;
}

// Runtime-installed scene delegate: SDL2 predates scenes, so UIKit creates
// the scene with delegate=nil and scene-routed events (URL opens) vanish.
// Installing a delegate post-launch is surgical: URL contexts start
// arriving here, and the lifecycle methods forward to SDL's app delegate
// (the predecessor's visionOS fwd: pattern) in case delegate presence
// reroutes them away from the legacy callbacks SDL depends on.
@interface SohIosSceneDelegate : NSObject <UIWindowSceneDelegate>
@end
@implementation SohIosSceneDelegate
- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)URLContexts {
    for (UIOpenURLContext* ctx in URLContexts) {
        SohIos_HandleDeepLink(ctx.URL.absoluteString);
    }
}
- (void)fwd:(SEL)sel {
    id<UIApplicationDelegate> app = UIApplication.sharedApplication.delegate;
    if ([app respondsToSelector:sel]) {
        void (*imp)(id, SEL, UIApplication*) = (void*)[(id)app methodForSelector:sel];
        imp(app, sel, UIApplication.sharedApplication);
    }
}
- (void)sceneWillResignActive:(UIScene*)scene {
    SohIos_FlushConfig("sceneWillResignActive"); // swipe-kill safety
    // R8 review: the clean-exit marker was only on the UIApplication
    // notification path; this scene path is the one that actually fires on a
    // swipe-kill, so without it every backgrounded run read as a memory kill.
    SohIos_MarkCleanExit("sceneWillResignActive");
    [self fwd:@selector(applicationWillResignActive:)];
}
- (void)sceneDidEnterBackground:(UIScene*)scene {
    SohIos_FlushConfig("sceneDidEnterBackground");
    SohIos_MarkCleanExit("sceneDidEnterBackground");
    SohIos_SetBackgrounded(1); // gate Metal rendering (overlay 0016)
    [self fwd:@selector(applicationDidEnterBackground:)];
}
- (void)sceneWillEnterForeground:(UIScene*)scene {
    SohIos_SetBackgrounded(0);
    [self fwd:@selector(applicationWillEnterForeground:)];
}
- (void)sceneDidBecomeActive:(UIScene*)scene {
    SohIos_SetBackgrounded(0); // belt-and-braces on every activation path
    [self fwd:@selector(applicationDidBecomeActive:)];
}
- (NSUserActivity*)stateRestorationActivityForScene:(UIScene*)scene {
    return nil; // engine re-boots fresh each launch (predecessor lesson)
}
@end

static void SohIos_InstallSceneDelegate(void) {
    static SohIosSceneDelegate* gSceneDelegate = nil;
    if (gSceneDelegate == nil) {
        gSceneDelegate = [SohIosSceneDelegate new];
    }
    for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.delegate == nil) {
            scene.delegate = gSceneDelegate;
            NSLog(@"[SohIosShell] scene delegate installed on %@", scene);
        }
    }
}

#pragma mark - Touch control overlay (visual v1)

// A translucent overlay drawn over SDL's Metal layer showing the N64 control
// layout: a floating left analog stick and the right-hand button cluster
// (A, B, C-up/down/left/right, Z, R, Start). v1 renders the layout and logs
// touches; input injection (SDL virtual controller) lands in the next revision.
@interface SohIosTouchOverlay : UIView
@end

typedef struct {
    CGPoint center;   // in this view's points
    CGFloat radius;
    UIColor* color;
    NSString* label;
} SohButton;

// CVar-safe key for a (possibly glyph) button label. Defined with the layout
// customizer below; forward-declared here for the hidden-button helpers.
static NSString* SohIos_LayoutKey(NSString* label);

@implementation SohIosTouchOverlay {
    CGPoint _stickBase;   // set where the finger lands (floating stick)
    CGFloat _stickBaseR;  // full-deflection travel (v2: 54 = old 90 * 0.6)
    CGFloat _stickKnobR;  // knob radius (v2: 34 = old 42 * 0.8)
    CGPoint _stickKnob;   // current knob position
    BOOL _stickActive;
    UITouch* __unsafe_unretained _stickTouch;         // identity only, never dereferenced after end
    NSMutableDictionary<NSValue*, NSNumber*>* _touchButtons; // UITouch ptr -> button index
    BOOL _controlsHidden; // while the SoH menu is open: only the restore dot is active
    BOOL _zHeld;          // finger currently on Z (momentary hold)
    BOOL _zLocked;        // double-tap lock engaged (stays held, bright visual)
    CFTimeInterval _zLastTapTime; // for the double-tap window
    Sint16 _lastSentLX, _lastSentLY; // stick-axis coalescing (audio-hitch fix)
    BOOL _controllerMode; // physical controller connected: touch controls hidden
    BOOL _popupOpen;      // any ImGui popup: overlay invisible + fully pass-through
    BOOL _lastMenuBtnVisible; // repaint trigger for pause/title transitions
    UILabel* _perfHud;        // optional fps/thermal readout (gSohIos.PerfHud)
    // Menu touch-router (menu open: overlay owns ALL touches and forwards
    // synthesized mouse events — device feedback: raw drags read as hover +
    // no scrolling): 0=undecided 1=scroll 2=drag 3=hover
    UITouch* __unsafe_unretained _routerTouch;
    int _routerMode;
    CGPoint _routerStart, _routerLast;
    // Layout customizer
    BOOL _editMode;
    NSMutableDictionary<NSString*, NSValue*>* _layoutOverrides; // label -> normalized center
    NSMutableSet<NSString*>* _layoutHidden; // layout keys the user hid from the touch layer
    CGFloat _layoutScale;
    CGPoint _stickHome;   // normalized; CGPointZero = default
    NSString* _editDrag;  // label being dragged, @"__stick", @"__slider", or nil
    NSString* _editSelected; // layout key of the last-touched button: the ONLY
                             // one showing an eye chip in the customizer (nil = none)
}

- (CGPoint)restoreDotCenter {
    // Top-center, matching the ≡ button's home (START owns bottom-center now).
    return CGPointMake(CGRectGetMidX(self.bounds), self.bounds.origin.y + 55);
}

// The ≡ menu button shows only where menu access makes sense: intro/title/
// file-select (users tune settings at the start) and the game's pause menu.
// Hidden during normal gameplay for BOTH touch and controller input.
- (BOOL)menuButtonVisible {
    return SohIos_IsGamePaused() || SohIos_IsTitleOrDemo();
}

// A user-hidden button never draws, never intercepts a touch, and never
// gates the floating stick (see hitButton/drawRect/pointInStickRegion). The
// ≡ menu button is EXEMPT — it's the only touch path into the SoH menu for
// a controller-less user, so it can never be hidden (a stale MENU.hidden
// CVar is ignored here rather than trusted).
- (BOOL)isButtonHidden:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    return [_layoutHidden containsObject:SohIos_LayoutKey(label)];
}

// Toggle from the customizer's per-button eye badge. Returns the new hidden
// state. ≡ can't be hidden. Live: takes effect the moment the customizer
// exits (drawRect/hitButton read _layoutHidden directly); persisted on save.
- (BOOL)toggleHiddenForLabel:(NSString*)label {
    if ([label isEqualToString:@"≡"]) {
        return NO;
    }
    NSString* key = SohIos_LayoutKey(label);
    BOOL nowHidden = ![_layoutHidden containsObject:key];
    if (nowHidden) {
        [_layoutHidden addObject:key];
    } else {
        [_layoutHidden removeObject:key];
    }
    [self setNeedsDisplay];
    return nowHidden;
}

- (CGPoint)zButtonCenter {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"Z"]) {
            return btns[i].center;
        }
    }
    return CGPointMake(-1000, -1000);
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO;
        // Without Redraw, a window resize stretches the cached bitmap and the
        // controls render squished until the next repaint (visionOS resize).
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
        _stickBaseR = 54.0; // -40% travel vs v1 (device feel feedback)
        _stickKnobR = 34.0; // -20% knob vs v1
        _touchButtons = [NSMutableDictionary dictionary];
        _layoutOverrides = [NSMutableDictionary dictionary];
        _layoutHidden = [NSMutableSet set];
        _layoutScale = 1.0;
        _stickHome = CGPointZero; // zero = default position
        [self loadLayoutFromCVars];
        // EditLayout is a transient trigger, not a setting: a stale persisted
        // 1 (e.g. saved by a config flush mid-edit) must never relaunch the
        // app straight into the customizer.
        CVarSetInteger("gSohIos.EditLayout", 0);
        // The game's menu state (overlay 0013) is authoritative for hiding:
        // it catches every way the menu opens/closes (esc key, deep link,
        // the menu's own X button), not just this overlay's ≡ button.
        __weak SohIosTouchOverlay* weakSelf = self;
        [NSTimer scheduledTimerWithTimeInterval:0.25
                                        repeats:YES
                                          block:^(NSTimer* t) { [weakSelf syncWithMenuState]; }];
    }
    return self;
}

// Physical controller (Backbone etc.) present -> touch controls yield.
// SDL creates no GCController for the virtual touch pad (verified: this
// SDL2 has no GCVirtualController path), but the SIMULATOR synthesizes a
// generic keyboard-passthrough pad named exactly "Gamepad" — real hardware
// reports its brand ("Backbone One", "DualSense", ...). Filter the generic
// name; connects are logged so device runs self-document any mismatch.
static BOOL SohIos_PhysicalControllerPresent(void) {
    // visionOS included: with no pad paired, show the touch controls —
    // pinch-taps make them usable enough to navigate menus (user request).
    // Real pads enumerate normally on the headset; the "Gamepad" filter
    // below handles the simulator's synthetic entry.
    for (GCController* c in GCController.controllers) {
        if (![(c.vendorName ?: @"") isEqualToString:@"Gamepad"]) {
            return YES;
        }
    }
    return NO;
}

// Haptic feedback on touch buttons (gSohIos.Haptics: 0 off, 1 light, 2 strong)
#if TARGET_OS_VISION
// Render Scale (Settings->iOS): consumed by the SDL metal view's drawable
// sizing. Polled below; defaults to full 3840.
volatile float gSohIosVisionLongEdge = 3840.0f;
float SohIos_VisionLongEdge(void) {
    return gSohIosVisionLongEdge;
}
#endif

// Recursive: SDL nests its metal view inside its own view hierarchy.
UIView* SohIos_FindMetalViewIn(UIView* v) {
    if ([v.layer isKindOfClass:NSClassFromString(@"CAMetalLayer")]) {
        return v;
    }
    for (UIView* c in v.subviews) {
        UIView* r = SohIos_FindMetalViewIn(c);
        if (r != nil) {
            return r;
        }
    }
    return nil;
}
// Immediately size the game window to its scene and give it the system
// window treatment (visionOS windows are continuously rounded; a raw
// UIWindow over the SwiftUI hosting window shows square corners otherwise).
// Idempotent — called at every attach point and from the self-heal.
void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene) {
    if (w == nil || scene == nil) {
        return;
    }
#if TARGET_OS_VISION
    w.layer.cornerRadius = 46.0;
    w.layer.cornerCurve = kCACornerCurveContinuous;
    w.layer.masksToBounds = YES;
#endif
    CGRect sb = scene.coordinateSpace.bounds;
    if (sb.size.width > 1 && !CGRectEqualToRect(w.frame, sb)) {
        w.frame = sb;
        [w setNeedsLayout];
        [w layoutIfNeeded];
    }
}

// Deterministic post-3D restore (device rounds 10-12: detection-based heals
// kept missing it): find the game window, glue to scene, and force the SDL
// view chain — every level, SDL sets child frames explicitly — to re-adopt.
void SohIos_ForceViewChainAdopt(void) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* mv = SohIos_FindMetalView(w);
        if (mv == nil) {
            continue;
        }
        UIWindowScene* scene = w.windowScene;
        if (scene != nil) {
            SohIos_GlueWindowToScene(w, scene);
        }
        for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
            v.frame = w.bounds;
        }
        UIView* root = w.rootViewController.view;
        [root setNeedsLayout];
        [root layoutIfNeeded];
        NSLog(@"[SohIosShell] forced view-chain adopt (window %.0fx%.0f)",
              w.bounds.size.width, w.bounds.size.height);
        return;
    }
}

UIView* SohIos_FindMetalView(UIWindow* w) {
    return w ? SohIos_FindMetalViewIn(w) : nil;
}

// The window that actually hosts the SDL metal view (the touch overlay can
// live elsewhere; every geometry decision below keys off this one).
static UIWindow* SohIos_GameWindowWithMetal(UIView** outMv) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* mv = SohIos_FindMetalView(w);
        if (mv != nil) {
            if (outMv != NULL) {
                *outMv = mv;
            }
            return w;
        }
    }
    if (outMv != NULL) {
        *outMv = nil;
    }
    return nil;
}

// SSAA hooks for overlay 0036 (Ghostship cross-port adoption). SoH is a
// HEAVY port (HD packs already needed GPU optimization): no device-tier
// auto-default — unset reads as 1.0 (native; already a big step up from the
// sub-native render this fixes). The settings slider (1.0-2.0) always wins.
float SohIos_SsaaFactor(void) {
    float f = CVarGetFloat("gSohIos.Supersample", 0.0f);
    if (f < 1.0f) {
        f = 1.0f;
    }
    if (f > 2.0f) {
        f = 2.0f;
    }
    return f;
}

// Native pixel width of the game window's drawable — already tracked each
// overlay tick into gSohIosDrawableW by syncWithMenuState (render-thread
// callers just read the cached global; 0 until the layer is sized, which the
// interpreter treats as "no SSAA yet").
uint32_t SohIos_DrawablePixelWidth(void) {
    float w = gSohIosDrawableW, h = gSohIosDrawableH; // file-scope statics, tick-updated
    return (uint32_t)(w > h ? w : h); // long edge = width (landscape-locked)
}

// 3D perf HUD text (overlay 0034 draws it into the eye frames): the 2D HUD is
// a UIKit label on the parked window, invisible on the panel. Same format as
// the label. Returns -1 when the HUD option is off, else thermal state.
int SohIos_PerfHud3DText(char* buf, int cap) {
    if (buf == NULL || cap < 8) {
        return -1;
    }
    buf[0] = 0;
    if (!CVarGetInteger("gSohIos.PerfHud", 0)) {
        return -1;
    }
    float fps = 0;
    SohIos_HudStats(&fps);
    int th = SohIos_ThermalState();
    // ASCII only: ImGui's font atlas has no U+2022 (renders '?', device
    // round 14).
    if (th >= 2) {
        snprintf(buf, cap, "%.0f - HOT", fps);
    } else if (th == 1) {
        snprintf(buf, cap, "%.0f - warm", fps);
    } else {
        snprintf(buf, cap, "%.0f", fps);
    }
    return th;
}

// ---- 3D-exit deterministic restore (device round 13: content rendered
// LARGER than the restored window — the blind timed adopts can glue a
// mid-animation or stale size, and SDL's resize debounce can eat the final
// event so the engine keeps rendering the stale size 1:1, top-left cropped).
// The predecessor ports' pattern instead: restore to the EXACT size captured
// before entering 3D, verify the engine adopted it, and escalate with a real
// bounds change if the resize event was lost. `geom` reports every layer.
static CGSize soh_restoreTarget = { 0, 0 };
static int soh_restoreTicks = 0;
static NSTimer* soh_restoreTimer = nil;
static const char* soh_restoreState = "idle";

static void SohIos_RestoreTick(void) {
    soh_restoreTicks++;
    UIView* mv = nil;
    UIWindow* w = SohIos_GameWindowWithMetal(&mv);
    if (w == nil) {
        soh_restoreState = "no-window";
        if (soh_restoreTicks > 24) {
            [soh_restoreTimer invalidate];
            soh_restoreTimer = nil;
        }
        return;
    }
    UIWindowScene* scene = w.windowScene;
    CGSize sb = scene ? scene.coordinateSpace.bounds.size : CGSizeZero;
    CGSize goal = (soh_restoreTarget.width >= 1) ? soh_restoreTarget : sb;
    BOOL sceneAtGoal = sb.width > 1 && fabs(sb.width - goal.width) <= 2 && fabs(sb.height - goal.height) <= 2;
    if (!sceneAtGoal && soh_restoreTicks < 16) {
        // Re-ask (the first request can race the immersive dismissal); wait
        // for the scene animation to land before touching the view chain.
        if (soh_restoreTicks == 1 || soh_restoreTicks == 8) {
#if TARGET_OS_VISION /* host VC (and scene geometry requests) exist only there */
            extern void Soh_RequestWindowSize(CGSize size);
            Soh_RequestWindowSize(goal);
#endif
        }
        soh_restoreState = "waiting-scene";
        NSLog(@"[SohIosShell] restore tick %d: scene %.0fx%.0f != goal %.0fx%.0f — waiting",
              soh_restoreTicks, sb.width, sb.height, goal.width, goal.height);
        return;
    }
    // Past the wait budget the system evidently won't grant the captured
    // size — adopt the settled scene instead (internal consistency is what
    // prevents the crop; exact size is best-effort on top).
    SohIos_GlueWindowToScene(w, scene);
    for (UIView* v = mv; v != nil && v != (UIView*)w; v = v.superview) {
        v.frame = w.bounds;
    }
    [w.rootViewController.view setNeedsLayout];
    [w.rootViewController.view layoutIfNeeded];
    // Did SDL actually adopt? Engine dims (points) must match the view.
    CGSize vb = mv.bounds.size;
    BOOL engineOk = gSoh3DDbg2DW > 0 && vb.width > 1 &&
                    fabs((float)gSoh3DDbg2DW - vb.width) <= vb.width * 0.02f &&
                    fabs((float)gSoh3DDbg2DH - vb.height) <= vb.height * 0.02f;
    if (engineOk) {
        soh_restoreState = "done";
        NSLog(@"[SohIosShell] restore done in %d ticks: win %.0fx%.0f engine %dx%d",
              soh_restoreTicks, w.bounds.size.width, w.bounds.size.height, gSoh3DDbg2DW, gSoh3DDbg2DH);
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
        return;
    }
    soh_restoreState = "engine-stale";
    if (soh_restoreTicks >= 4 && (soh_restoreTicks % 2) == 0) {
        // SDL's debounce ate the resize: force a REAL bounds change (−1pt,
        // layout, back) so the final size definitely reaches the engine.
        NSLog(@"[SohIosShell] restore tick %d: engine %dx%d != view %.0fx%.0f — jiggling",
              soh_restoreTicks, gSoh3DDbg2DW, gSoh3DDbg2DH, vb.width, vb.height);
        mv.frame = CGRectMake(0, 0, w.bounds.size.width - 1, w.bounds.size.height - 1);
        [mv setNeedsLayout];
        [mv layoutIfNeeded];
        mv.frame = CGRectMake(0, 0, w.bounds.size.width, w.bounds.size.height);
        [mv setNeedsLayout];
        [mv layoutIfNeeded];
    }
    if (soh_restoreTicks > 24) {
        NSLog(@"[SohIosShell] restore GAVE UP: scene %.0fx%.0f win %.0fx%.0f view %.0fx%.0f engine %dx%d",
              sb.width, sb.height, w.bounds.size.width, w.bounds.size.height, vb.width, vb.height,
              gSoh3DDbg2DW, gSoh3DDbg2DH);
        soh_restoreState = "gave-up";
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
    }
}

// Full geometry snapshot for the bridge `geom` command. MAIN THREAD ONLY.
int SohIos_GeomReport(char* buf, int cap) {
    UIView* mv = nil;
    UIWindow* w = SohIos_GameWindowWithMetal(&mv);
    if (w == nil) {
        snprintf(buf, cap, "no game window");
        return 0;
    }
    UIWindowScene* scene = w.windowScene;
    CGRect sb = scene ? scene.coordinateSpace.bounds : CGRectZero;
    CGRect wf = w.frame;
    CGRect mf = mv != nil ? mv.frame : CGRectZero;
    CGSize ds = mv != nil ? ((CAMetalLayer*)mv.layer).drawableSize : CGSizeZero;
    CGFloat cs = mv != nil ? mv.layer.contentsScale : 0;
    snprintf(buf, cap,
             "restore=%s ticks=%d target=%.0fx%.0f scene=%.0fx%.0f win=%.0f,%.0f+%.0fx%.0f "
             "mv=%.0f,%.0f+%.0fx%.0f drawable=%.0fx%.0f scale=%.2f engine2d=%dx%d mode3d=%d",
             soh_restoreState, soh_restoreTicks, soh_restoreTarget.width, soh_restoreTarget.height,
             sb.size.width, sb.size.height, wf.origin.x, wf.origin.y, wf.size.width, wf.size.height,
             mf.origin.x, mf.origin.y, mf.size.width, mf.size.height, ds.width, ds.height, (float)cs,
             gSoh3DDbg2DW, gSoh3DDbg2DH, gSoh3DMode);
    return 1;
}

// Entry must cancel any mid-flight restore (or the timer fights the 480x320
// parking), and can inherit its target as the true pre-3D size (a quick
// re-enter would otherwise capture the half-restored transient).
CGSize SohIos_RestorePendingTarget(void) {
    return (soh_restoreTimer != nil) ? soh_restoreTarget : CGSizeZero;
}

void SohIos_RestoreCancel(void) {
    if (soh_restoreTimer != nil) {
        [soh_restoreTimer invalidate];
        soh_restoreTimer = nil;
        soh_restoreState = "cancelled";
        NSLog(@"[SohIosShell] restore cancelled (3D re-entry)");
    }
}

void SohIos_RestoreWindowTo(CGSize target) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SohIos_RestoreWindowTo(target); });
        return;
    }
    soh_restoreTarget = target;
    soh_restoreTicks = 0;
    soh_restoreState = "running";
    [soh_restoreTimer invalidate];
    soh_restoreTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                       repeats:YES
                                                         block:^(NSTimer* t) { SohIos_RestoreTick(); }];
    NSLog(@"[SohIosShell] restore controller started, target %.0fx%.0f", target.width, target.height);
}

- (void)hapticTap {
#if !TARGET_OS_VISION /* no haptic hardware on Vision Pro */
    int mode = CVarGetInteger("gSohIos.Haptics", 1);
    if (mode <= 0) {
        return;
    }
    UIImpactFeedbackStyle style = (mode >= 2) ? UIImpactFeedbackStyleMedium : UIImpactFeedbackStyleLight;
    UIImpactFeedbackGenerator* gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [gen impactOccurred];
#endif
}

- (void)syncWithMenuState {
    {
        UIView* mv = SohIos_FindMetalView(self.window);
        if (mv != nil) {
            CGSize ds = ((CAMetalLayer*)mv.layer).drawableSize;
            gSohIosDrawableW = ds.width;
            gSohIosDrawableH = ds.height;
            gSohIosContentsScale = mv.layer.contentsScale;
        }
    }
#if TARGET_OS_VISION
    {
        // Self-healing drawable: the SDL metal view's resize DEBOUNCE can lose
        // the final edge (observed at first open under the SwiftUI entry: the
        // scene grows during boot and the drawable stays at the boot size —
        // content fills only part of the window until a manual resize). If the
        // actual drawable disagrees with what the current bounds demand for
        // two consecutive ticks (0.5 s > the 0.3 s debounce), re-derive.
        UIView* mv = SohIos_FindMetalView(self.window);
        if (mv != nil && gSoh3DMode == 0) {
            static int sohMismatchTicks = 0;
            // LAYER 1 (the reproduced fill bug, telemetry engine2d=480x320 vs
            // full drawable): the WINDOW can stay at a stale size while the
            // SCENE has grown (boot growth, 3D-exit restore) — the layout
            // chain that feeds SDL its new size never fires because UIKit
            // thinks nothing changed. Re-glue window to scene on mismatch.
            UIWindowScene* scene = self.window.windowScene;
            if (scene != nil) {
                CGSize sb = scene.coordinateSpace.bounds.size;
                CGSize wb = self.window.bounds.size;
                if (sb.width > 1 &&
                    (fabs(sb.width - wb.width) > 2 || fabs(sb.height - wb.height) > 2)) {
                    NSLog(@"[SohIosShell] window %.0fx%.0f != scene %.0fx%.0f — re-gluing",
                          wb.width, wb.height, sb.width, sb.height);
                }
                SohIos_GlueWindowToScene(self.window, scene);
            }
            // LAYER 3 (device round 10): the METAL VIEW itself can stay at the
            // parked size inside a restored window — then engine2d == view
            // bounds and layer 2 sees no mismatch. View-vs-window is the
            // missing comparison; force the SDL hierarchy to re-adopt.
            {
                CGSize vb2 = mv.bounds.size;
                CGSize wb2 = self.window.bounds.size;
                if (wb2.width > 1 && (fabs(vb2.width - wb2.width) > wb2.width * 0.02f ||
                                      fabs(vb2.height - wb2.height) > wb2.height * 0.02f)) {
                    static int sohViewStaleTicks = 0;
                    if (++sohViewStaleTicks >= 2) {
                        sohViewStaleTicks = 0;
                        NSLog(@"[SohIosShell] metal view %.0fx%.0f != window %.0fx%.0f — re-adopting chain",
                              vb2.width, vb2.height, wb2.width, wb2.height);
                        // Force EVERY level: SDL sets child frames explicitly (no
                        // autoresizing), so nudging layout alone leaves the metal
                        // view parked; and SDL re-learns its size from the VC
                        // view's bounds — set the whole ancestor chain, then let
                        // viewDidLayoutSubviews report the corrected size to SDL.
                        for (UIView* v = mv; v != nil && v != (UIView*)self.window; v = v.superview) {
                            v.frame = self.window.bounds;
                        }
                        UIView* root = self.window.rootViewController.view;
                        [root setNeedsLayout];
                        [root layoutIfNeeded];
                    }
                }
            }
            // LAYER 2: SDL's cached size (engine2d telemetry) vs the view —
            // a lost resize event leaves the engine rendering a sub-rect.
            {
                CGSize vb = mv.bounds.size;
                if (gSoh3DDbg2DW > 0 && vb.width > 1 &&
                    (fabs((float)gSoh3DDbg2DW - vb.width) > vb.width * 0.02f ||
                     fabs((float)gSoh3DDbg2DH - vb.height) > vb.height * 0.02f)) {
                    static int sohSdlStaleTicks = 0;
                    if (++sohSdlStaleTicks >= 3) {
                        sohSdlStaleTicks = 0;
                        NSLog(@"[SohIosShell] engine dims %dx%d != view %.0fx%.0f — re-kicking layout chain",
                              gSoh3DDbg2DW, gSoh3DDbg2DH, vb.width, vb.height);
                        [self.window.rootViewController.view setNeedsLayout];
                        [self.window.rootViewController.view layoutIfNeeded];
                        [mv setNeedsLayout];
                        [mv layoutIfNeeded];
                    }
                }
            }
            CGSize b = mv.bounds.size;
            CGSize d = ((CAMetalLayer*)mv.layer).drawableSize;
            float targetLong = (float)CVarGetInteger("gSohIos.VisionLongEdge", 3840);
            float boundsLong = MAX(b.width, b.height);
            float expectLong = MAX(targetLong, boundsLong);
            float actualLong = MAX(d.width, d.height);
            float bAspect = (b.height > 1) ? b.width / b.height : 0;
            float dAspect = (d.height > 1) ? d.width / d.height : 0;
            BOOL sizeOff = fabsf(actualLong - expectLong) > expectLong * 0.02f;
            BOOL aspectOff = (bAspect > 0 && dAspect > 0) && fabsf(dAspect - bAspect) > bAspect * 0.02f;
            if (boundsLong > 1 && (sizeOff || aspectOff)) {
                if (++sohMismatchTicks >= 2) {
                    sohMismatchTicks = 0;
                    NSLog(@"[SohIosShell] drawable mismatch (have %.0fx%.0f, bounds %.0fx%.0f, want long %.0f) — re-deriving",
                          d.width, d.height, b.width, b.height, expectLong);
                    [mv setNeedsLayout];
                    [mv layoutIfNeeded];
                }
            } else {
                sohMismatchTicks = 0;
            }
        }
    }
    {
        float target = (float)CVarGetInteger("gSohIos.VisionLongEdge", 3840);
        if (target != gSohIosVisionLongEdge) {
            gSohIosVisionLongEdge = target;
            // The SDL metal view only re-derives drawableSize in
            // layoutSubviews — poke it so Render Scale applies live.
            UIView* mv = SohIos_FindMetalView(self.window);
            if (mv != nil) {
                [mv setNeedsLayout];
                [mv layoutIfNeeded];
                NSLog(@"[SohIosShell] render scale -> %.0f (drawable re-derive poked)", target);
            } else {
                NSLog(@"[SohIosShell] render scale -> %.0f (METAL VIEW NOT FOUND)", target);
            }
        }
    }
#endif
    // Customizer entry: the ImGui button (0017) sets this CVar; we consume
    // it, close the menu, and enter edit mode (even with a gamepad).
    if (CVarGetInteger("gSohIos.EditLayout", 0)) {
        CVarSetInteger("gSohIos.EditLayout", 0);
        if (SohIos_IsMenuOpen()) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        }
        _editMode = YES;
        _editSelected = nil; // no eye chips until the user touches a button
        _controlsHidden = NO;
        [self releaseAllControls];
        [self setNeedsDisplay];
        NSLog(@"[SohIosShell] layout customizer entered");
        return;
    }
    if (_editMode) {
        return; // customizer owns the screen; skip hide/show logic
    }
    BOOL open = SohIos_IsMenuOpen() != 0;
    BOOL controller = SohIos_PhysicalControllerPresent();
    BOOL popup = SohIos_IsPopupOpen() != 0;
    BOOL changed = NO;
    // ≡ visibility follows pause/title state (device bug: the button was
    // hit-testable before it was drawn, and lingered after unpause, because
    // nothing repainted on those transitions).
    BOOL menuBtn = [self menuButtonVisible];
    if (menuBtn != _lastMenuBtnVisible) {
        _lastMenuBtnVisible = menuBtn;
        changed = YES;
    }
    if (popup != _popupOpen) {
        _popupOpen = popup;
        if (popup) {
            [self releaseAllControls];
        }
        changed = YES;
    }
    if (controller != _controllerMode) {
        _controllerMode = controller;
        [self releaseAllControls];
        changed = YES;
        NSLog(@"[SohIosShell] controller mode %@ (controllers: %@)",
              controller ? @"ON (touch hidden)" : @"OFF (touch active)",
              [[GCController.controllers valueForKey:@"vendorName"] componentsJoinedByString:@", "]);
    }
    if (open != _controlsHidden) {
        _controlsHidden = open;
        if (open) {
            [self releaseAllControls]; // no stuck buttons/stick while hidden
        }
        changed = YES;
    }
    if (changed || _controllerMode) {
        // controllerMode redraws every tick cheaply so the ≡ button can track
        // the game's pause state (visible only while paused).
        [self setNeedsDisplay];
    }
    // Touch-control opacity (edit mode and open menu stay fully opaque).
    CGFloat opacity = CVarGetFloat("gSohIos.TouchOpacity", 1.0f);
    self.alpha = (_editMode || _controlsHidden) ? 1.0 : MAX(0.25, MIN(1.0, opacity));
#if SOH_REMOTE_CONSOLE
    // Remote console toggle: start the bridge on demand (idempotent). The
    // 0017 menu widget that drives this CVar is compiled out in lockstep.
    if (CVarGetInteger("gSohIos.RemoteConsole", 0)) {
        SohIos_StartConsoleBridge(YES);
    }
#endif
    // Perf HUD (fps + thermal from the 0008 probe).
    if (CVarGetInteger("gSohIos.PerfHud", 0)) {
        if (_perfHud == nil) {
            // Inset from the corner: the rounded bezel + landscape safe area
            // clipped the thermal suffix ("• warm/HOT") at the old x.
            _perfHud = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 190, 10, 150, 16)];
            _perfHud.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
            _perfHud.textAlignment = NSTextAlignmentRight;
            _perfHud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            [self addSubview:_perfHud];
        }
        _perfHud.hidden = NO;
        float fps = 0;
        SohIos_HudStats(&fps);
        // Just the number (user feedback); thermal only when it matters.
        int th = SohIos_ThermalState();
        if (th >= 2) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 HOT", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.3 alpha:0.95];
        } else if (th == 1) {
            _perfHud.text = [NSString stringWithFormat:@"%.0f \u2022 warm", fps];
            _perfHud.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.4 alpha:0.9];
        } else {
            _perfHud.text = [NSString stringWithFormat:@"%.0f", fps];
            _perfHud.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        }
    } else if (_perfHud != nil) {
        _perfHud.hidden = YES;
    }
}

// Send up-events for everything currently held and recentre the stick.
- (void)releaseAllControls {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if (![l isEqualToString:@"≡"] && ![l hasPrefix:@"C"]) {
            [self applyButton:l down:NO];
        }
    }
    [_touchButtons removeAllObjects];
    [self recomputeCAxes]; // dict now empty -> C axes recentre
    _stickActive = NO;
    _stickTouch = nil;
    _zHeld = NO;
    _zLocked = NO;
    _lastSentLX = _lastSentLY = 0;
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
}

// Button labels -> virtual pad actions. C-buttons ride the right stick
// (SoH's default C mapping); Z is the left trigger.
- (void)applyButton:(NSString*)label down:(BOOL)down {
    if ([label isEqualToString:@"≡"]) {
        if (down) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // open SoH menu
            _controlsHidden = YES; // get out of the menu's way (restore dot remains)
            [self setNeedsDisplay];
        }
        return;
    }
    if ([label isEqualToString:@"A"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_A, down);
    } else if ([label isEqualToString:@"B"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_B, down);
    } else if ([label isEqualToString:@"START"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_START, down);
    } else if ([label isEqualToString:@"L"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_LEFTSHOULDER, down);
    } else if ([label isEqualToString:@"R"]) {
        SohIos_PadButton(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, down);
    } else if ([label isEqualToString:@"Z"]) {
        // Touchscreen Z (device feedback 2026-07-12): MOMENTARY by default
        // — held exactly while the finger is down. Double-tapping (within
        // 0.35 s) LOCKS it held until the next tap; gSohIos.ZDoubleTap=0
        // disables the lock gesture. Lock state is unmistakable in drawRect.
        if (down) {
            CFTimeInterval now = CACurrentMediaTime();
            if (_zLocked) {
                _zLocked = NO; // any tap while locked unlocks (finger still holds)
            } else if (CVarGetInteger("gSohIos.ZDoubleTap", 1) && now - _zLastTapTime < 0.35) {
                _zLocked = YES;
            }
            _zLastTapTime = now;
            _zHeld = YES;
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 32767);
        } else {
            _zHeld = NO;
            if (!_zLocked) {
                SohIos_PadAxis(SDL_CONTROLLER_AXIS_TRIGGERLEFT, 0);
            }
        }
        [self setNeedsDisplay];
    } else if ([label hasPrefix:@"C"]) {
        [self recomputeCAxes];
    }
}

// C-buttons combine on the right-stick axes; recompute from all held touches.
- (void)recomputeCAxes {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    Sint32 rx = 0, ry = 0;
    for (NSNumber* idx in _touchButtons.allValues) {
        NSString* l = btns[idx.intValue].label;
        if ([l isEqualToString:@"C←"]) {
            rx -= 32767;
        } else if ([l isEqualToString:@"C→"]) {
            rx += 32767;
        } else if ([l isEqualToString:@"C↑"]) {
            ry -= 32767;
        } else if ([l isEqualToString:@"C↓"]) {
            ry += 32767;
        }
    }
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTX, (Sint16)MAX(-32767, MIN(32767, rx)));
    SohIos_PadAxis(SDL_CONTROLLER_AXIS_RIGHTY, (Sint16)MAX(-32767, MIN(32767, ry)));
}

- (int)hitButton:(CGPoint)p {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        if ([btns[i].label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay: not tappable either
        }
        if ([self isButtonHidden:btns[i].label]) {
            continue; // user-hidden: not drawn, not tappable
        }
        if (hypot(p.x - btns[i].center.x, p.y - btns[i].center.y) <= btns[i].radius * 1.35) {
            return i;
        }
    }
    return -1;
}

// LUS applies Port1.LeftStick.DeadzonePercentage (default 20) to all stick
// input — right for physical sticks, wrong for touch (the touch layer has
// zero mechanical noise; spec wants zero effective deadzone). Precompensate:
// any deflection starts past the deadzone, and the remaining travel maps
// linearly, so walk/run gradation is preserved. Physical pads are untouched.
static const CGFloat kLusDeadzone = 0.20;
static Sint16 SohIos_StickValue(CGFloat n) {
    if (n == 0) {
        return 0;
    }
    CGFloat m = MIN(1.0, fabs(n));
    // gSohIos.StickCurve: 0 linear, 1 expo (finer control near center)
    if (CVarGetInteger("gSohIos.StickCurve", 0) == 1) {
        m = m * m;
    }
    CGFloat v = kLusDeadzone + m * (1.0 - kLusDeadzone);
    return (Sint16)((n < 0 ? -v : v) * 32767);
}

- (void)updateStickAxesFromKnob {
    CGFloat nx = (_stickKnob.x - _stickBase.x) / _stickBaseR;
    CGFloat ny = (_stickKnob.y - _stickBase.y) / _stickBaseR;
    Sint16 lx = SohIos_StickValue(MAX(-1.0, MIN(1.0, nx)));
    Sint16 ly = SohIos_StickValue(MAX(-1.0, MIN(1.0, ny)));
    // Coalesce (device feedback: audio hitched every ~2 s while the touch
    // stick was held): touchesMoved arrives at up to 120 Hz and every
    // SDL_JoystickSetVirtualAxis takes SDL's joystick lock, contending with
    // the game thread's event pump — enough to starve the audio ring.
    // Only forward meaningful changes (~1% of range, and every zero
    // crossing so release is always exact).
    BOOL lxChanged = abs(lx - _lastSentLX) > 300 || ((lx == 0) != (_lastSentLX == 0));
    BOOL lyChanged = abs(ly - _lastSentLY) > 300 || ((ly == 0) != (_lastSentLY == 0));
    if (lxChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, lx);
        _lastSentLX = lx;
    }
    if (lyChanged) {
        SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, ly);
        _lastSentLY = ly;
    }
}

// --- Layout customizer ----------------------------------------------------
static NSString* SohIos_LayoutKey(NSString* label) {
    // CVar-safe keys for glyph labels
    if ([label isEqualToString:@"C\u2191"]) return @"CU";
    if ([label isEqualToString:@"C\u2193"]) return @"CD";
    if ([label isEqualToString:@"C\u2190"]) return @"CL";
    if ([label isEqualToString:@"C\u2192"]) return @"CR";
    if ([label isEqualToString:@"\u2261"])  return @"MENU";
    return label;
}

// Canonical layout reference: ALWAYS landscape-shaped (w = long side),
// regardless of the view's momentary orientation — early-boot portrait
// bounds scrambled normalized coords on device (feedback 2026-07-12).
- (CGSize)layoutRefSize {
    CGRect b = self.bounds;
    CGFloat w = CGRectGetWidth(b), h = CGRectGetHeight(b);
    return CGSizeMake(MAX(w, h), MIN(w, h));
}

- (void)loadLayoutFromCVars {
    if (!CVarGetInteger("gSohIos.Layout.Set", 0)) {
        return;
    }
    _layoutScale = CVarGetFloat("gSohIos.Layout.Scale", 1.0f);
    for (NSString* key in @[ @"A", @"B", @"CU", @"CD", @"CL", @"CR", @"Z", @"L", @"R", @"START", @"MENU" ]) {
        float x = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, -1.0f);
        float y = CVarGetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, -1.0f);
        if (x >= 0 && y >= 0) {
            _layoutOverrides[key] = [NSValue valueWithCGPoint:CGPointMake(x, y)];
        }
        // MENU (≡) is never hideable (isButtonHidden exempts it), so a stale
        // MENU.hidden is simply not read back into the set.
        if (![key isEqualToString:@"MENU"] &&
            CVarGetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 0)) {
            [_layoutHidden addObject:key];
        }
    }
    float sx = CVarGetFloat("gSohIos.Layout.Stick.x", -1.0f);
    float sy = CVarGetFloat("gSohIos.Layout.Stick.y", -1.0f);
    if (sx >= 0 && sy >= 0) {
        _stickHome = CGPointMake(sx, sy);
    }
}

- (void)saveLayoutToCVars {
    // Clear EVERYTHING first: stale per-button keys from earlier saves were
    // resurrecting on the next launch (device bug: deterministic jumble).
    CVarClearBlock("gSohIos.Layout");
    CVarSetInteger("gSohIos.Layout.Set", 1);
    CVarSetFloat("gSohIos.Layout.Scale", (float)_layoutScale);
    for (NSString* key in _layoutOverrides) {
        CGPoint n = [_layoutOverrides[key] CGPointValue];
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.x", key].UTF8String, (float)n.x);
        CVarSetFloat([NSString stringWithFormat:@"gSohIos.Layout.%@.y", key].UTF8String, (float)n.y);
    }
    // Hidden buttons are stored independently of position overrides — a user
    // can hide L/R without ever dragging anything (positions stay default).
    for (NSString* key in _layoutHidden) {
        CVarSetInteger([NSString stringWithFormat:@"gSohIos.Layout.%@.hidden", key].UTF8String, 1);
    }
    if (!CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CVarSetFloat("gSohIos.Layout.Stick.x", (float)_stickHome.x);
        CVarSetFloat("gSohIos.Layout.Stick.y", (float)_stickHome.y);
    }
    CVarSave();
}

- (CGPoint)stickHomePoint {
    CGRect b = self.bounds;
    if (CGPointEqualToPoint(_stickHome, CGPointZero)) {
        CGPoint def = CGPointMake(b.origin.x + 150, CGRectGetMaxY(b) - 170);
        return [self applyLefty:def];
    }
    CGSize ref = [self layoutRefSize];
    return [self applyLefty:CGPointMake(_stickHome.x * ref.width, _stickHome.y * ref.height)];
}

// Left-handed mirror (gSohIos.LeftyFlip): flips every X around the canonical
// width. Applied AFTER overrides so customized layouts mirror too.
- (CGPoint)applyLefty:(CGPoint)c {
    if (!CVarGetInteger("gSohIos.LeftyFlip", 0)) {
        return c;
    }
    return CGPointMake([self layoutRefSize].width - c.x, c.y);
}

#define kStickHaloR 150.0

- (CGRect)editChromeRect {
    // Bottom-LEFT per user preference (overlapping the stick halo is fine —
    // the chrome is hit-tested first, and the left side is the least
    // crowded place for customized buttons).
    CGRect b = self.bounds;
    return CGRectMake(b.origin.x + 16, CGRectGetMaxY(b) - 50, 330, 44);
}
- (CGPoint)editResetCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMinX(c) + 26, CGRectGetMidY(c));
}
- (CGPoint)editSaveCenter {
    CGRect c = [self editChromeRect];
    return CGPointMake(CGRectGetMaxX(c) - 26, CGRectGetMidY(c));
}
- (CGRect)editSliderRect {
    CGRect c = [self editChromeRect];
    return CGRectMake(CGRectGetMinX(c) + 58, CGRectGetMidY(c) - 4, CGRectGetWidth(c) - 116, 8);
}

- (int)hitButtonForEdit:(CGPoint)pnt {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if (hypot(pnt.x - btns[i].center.x, pnt.y - btns[i].center.y) <= MAX(btns[i].radius * 1.35, 30)) {
            return i;
        }
    }
    return -1;
}

// --- Per-button hide/show badge (customizer only) --------------------------
// A small eye chip sits just OUTSIDE the button rim so the whole button body
// stays a drag handle (user constraint: the badge must not block moving a
// button around). It points toward screen interior and is clamped on-screen,
// so edge buttons (L/R top corners) never push it off-screen. eye.slash =
// "tap to hide" on a visible button; eye = "tap to show" on a hidden one.
#define kHideBadgeR 14.0
- (CGPoint)hideBadgeCenterForCenter:(CGPoint)c radius:(CGFloat)r {
    CGRect b = self.bounds;
    // Direction: point the badge AWAY from the local cluster centroid so a
    // tight group (the C-button diamond) spreads its badges radially outward
    // instead of piling up on neighbors; for an isolated button (L/R/START)
    // there's no local cluster, so point toward screen interior. Clamped on-
    // screen either way, so edge buttons never push their badge off-screen.
    SohButton all[16];
    int an = 0;
    [self buttonRects:all count:&an];
    CGFloat sx = 0, sy = 0;
    int cnt = 0;
    for (int i = 0; i < an; i++) {
        CGFloat d = hypot(all[i].center.x - c.x, all[i].center.y - c.y);
        if (d > 1.0 && d < 150.0) {
            sx += all[i].center.x;
            sy += all[i].center.y;
            cnt++;
        }
    }
    CGFloat dirX, dirY;
    if (cnt > 0) {
        dirX = c.x - sx / cnt;
        dirY = c.y - sy / cnt;
        CGFloat nrm = hypot(dirX, dirY);
        if (nrm < 1.0) { // sits on the centroid: default up
            dirX = 0;
            dirY = -1;
        } else {
            dirX /= nrm;
            dirY /= nrm;
        }
    } else {
        dirX = (c.x > CGRectGetMidX(b)) ? -0.7071 : 0.7071;
        dirY = (c.y > CGRectGetMidY(b)) ? -0.7071 : 0.7071;
    }
    CGFloat off = r + kHideBadgeR - 2.0; // badge inner edge ~tangent to the rim
    CGPoint badge = CGPointMake(c.x + dirX * off, c.y + dirY * off);
    CGFloat m = kHideBadgeR + 4.0;
    badge.x = MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, badge.x));
    badge.y = MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, badge.y));
    return badge;
}

// Which button's hide badge contains pnt (-1 = none). ≡ has no badge.
- (int)indexForLayoutKey:(NSString*)key {
    if (key == nil) {
        return -1;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        if ([SohIos_LayoutKey(btns[i].label) isEqualToString:key]) {
            return i;
        }
    }
    return -1;
}

// The eye chip lives ONLY on the currently-selected button. Returns YES and
// (optionally) its center if the selected button has a chip pnt falls in.
- (BOOL)pointHitsSelectedChip:(CGPoint)pnt center:(CGPoint*)outChip {
    int i = [self indexForLayoutKey:_editSelected];
    if (i < 0) {
        return NO;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    if ([btns[i].label isEqualToString:@"≡"]) {
        return NO; // menu button has no chip (never hideable)
    }
    CGPoint chip = [self hideBadgeCenterForCenter:btns[i].center radius:btns[i].radius];
    if (outChip != NULL) {
        *outChip = chip;
    }
    return hypot(pnt.x - chip.x, pnt.y - chip.y) <= kHideBadgeR + 4.0;
}

- (void)drawHideBadgeAt:(CGPoint)c hidden:(BOOL)hidden {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect ring = CGRectMake(c.x - kHideBadgeR, c.y - kHideBadgeR, kHideBadgeR * 2, kHideBadgeR * 2);
    [[UIColor colorWithWhite:0.10 alpha:0.92] setFill];
    CGContextFillEllipseInRect(ctx, ring);
    [[UIColor colorWithWhite:1.0 alpha:0.85] setStroke];
    CGContextSetLineWidth(ctx, 1.5);
    CGContextStrokeEllipseInRect(ctx, ring);
    UIImageSymbolConfiguration* cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    UIImage* img = [[UIImage systemImageNamed:(hidden ? @"eye.fill" : @"eye.slash.fill") withConfiguration:cfg]
        imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (img != nil) {
        [img drawInRect:CGRectMake(c.x - img.size.width / 2, c.y - img.size.height / 2, img.size.width, img.size.height)];
    } else {
        // Font fallback if SF Symbols is unavailable (should not happen on iOS 15+).
        [self drawGlyph:(hidden ? @"o" : @"x") at:c size:16 alpha:1.0];
    }
}

// Bridge gate probe (idb taps are unreliable on the sim — traps list). MAIN
// THREAD ONLY. Selection model: the eye chip shows ONLY on the last-touched
// (selected) button. Subcommands:
//   list          -> "edit=E sel=KEY|none <KEY:h<hidden>:hit<hitself>> ...
//                     selchip=x,y|none" (hitself must be 0 for a hidden button)
//   select KEY    -> drives the REAL editBegan at KEY's button center =
//                    touch-to-select; its chip appears, any prior one clears
//   chiptap       -> drives the REAL editBegan at the SELECTED button's chip;
//                    toggles hide, keeps selection, starts no drag
//   tapedit X Y   -> real editBegan at an arbitrary point (gates ↺/✓ chrome)
//   save          -> saveLayoutToCVars (what ✓ does)
- (NSString*)hideProbe:(NSArray<NSString*>*)a {
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    NSString* sub = a.count >= 1 ? a[0].lowercaseString : @"list";
    if ([sub isEqualToString:@"select"] && a.count >= 2) {
        int i = [self indexForLayoutKey:a[1].uppercaseString];
        if (i < 0) {
            return @"err no such button";
        }
        [self editBegan:btns[i].center]; // real touch-to-select on the body
        NSString* dragWas = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok sel=%@ editDragWas=%@", _editSelected ?: @"none", dragWas];
    }
    if ([sub isEqualToString:@"chiptap"]) {
        int i = [self indexForLayoutKey:_editSelected];
        if (i < 0) {
            return @"err nothing selected";
        }
        CGPoint chip = CGPointZero;
        BOOL onChip = [self pointHitsSelectedChip:btns[i].center center:&chip]; // center just to fetch chip
        (void)onChip;
        BOOL was = [self isButtonHidden:btns[i].label];
        NSString* selBefore = _editSelected;
        [self editBegan:chip]; // real chip tap
        NSString* dragAfter = _editDrag ?: @"nil"; // must be nil: a chip tap starts no drag
        BOOL now = [self isButtonHidden:btns[i].label];
        [self editEnded];
        return [NSString stringWithFormat:@"ok chiptap %@ %d->%d sel=%@ editDrag=%@", SohIos_LayoutKey(btns[i].label),
                                          was, now, _editSelected ?: @"none",
                                          [selBefore isEqualToString:_editSelected ?: @""] ? dragAfter : @"SELCHANGED"];
    }
    if ([sub isEqualToString:@"save"]) {
        [self saveLayoutToCVars]; // exactly what the customizer's checkmark does
        return @"ok saved";
    }
    if ([sub isEqualToString:@"tapedit"] && a.count >= 3) {
        // Drive the REAL customizer touch entry at an arbitrary point — gates
        // the ↺ reset and ✓ save chrome (which live in editBegan) without
        // guessing at idb HID taps.
        [self editBegan:CGPointMake(a[1].floatValue, a[2].floatValue)];
        NSString* drag = _editDrag ?: @"nil";
        [self editEnded];
        return [NSString stringWithFormat:@"ok tapedit editMode=%d editDrag=%@", _editMode, drag];
    }
    int seli = [self indexForLayoutKey:_editSelected];
    NSMutableString* s = [NSMutableString stringWithFormat:@"ok edit=%d sel=%@", _editMode, _editSelected ?: @"none"];
    for (int i = 0; i < n; i++) {
        [s appendFormat:@" %@:h%d:hit%d", SohIos_LayoutKey(btns[i].label),
                        [self isButtonHidden:btns[i].label], [self hitButton:btns[i].center] == i];
    }
    if (seli >= 0 && ![btns[seli].label isEqualToString:@"≡"]) {
        CGPoint chip = [self hideBadgeCenterForCenter:btns[seli].center radius:btns[seli].radius];
        [s appendFormat:@" selchip=%.0f,%.0f", chip.x, chip.y];
    } else {
        [s appendString:@" selchip=none"];
    }
    return s;
}

- (void)editBegan:(CGPoint)pnt {
    CGPoint reset = [self editResetCenter], save = [self editSaveCenter];
    CGRect slider = CGRectInset([self editSliderRect], -12, -18);
    if (hypot(pnt.x - reset.x, pnt.y - reset.y) <= 26) {
        [_layoutOverrides removeAllObjects];
        [_layoutHidden removeAllObjects]; // reset restores every button to visible
        _layoutScale = 1.0;
        _stickHome = CGPointZero;
        [self setNeedsDisplay];
        return;
    }
    if (hypot(pnt.x - save.x, pnt.y - save.y) <= 26) {
        [self saveLayoutToCVars];
        _editMode = NO;
        _editDrag = nil;
        [self setNeedsDisplay];
        return;
    }
    if (CGRectContainsPoint(slider, pnt)) {
        _editDrag = @"__slider";
        [self editMoved:pnt];
        return;
    }
    // Eye chip (only on the selected button) is checked BEFORE the button-body
    // drag: tapping it toggles visibility, keeps the selection, and never
    // starts a drag. The chip sits outside the rim, so the body stays a drag
    // handle.
    if ([self pointHitsSelectedChip:pnt center:NULL]) {
        int i = [self indexForLayoutKey:_editSelected];
        SohButton bb[16];
        int bn = 0;
        [self buttonRects:bb count:&bn];
        if (i >= 0) {
            [self toggleHiddenForLabel:bb[i].label];
        }
        return;
    }
    // Touching a button SELECTS it (its eye chip appears; any prior selection's
    // chip disappears) and begins a drag.
    int idx = [self hitButtonForEdit:pnt];
    if (idx >= 0) {
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        _editSelected = SohIos_LayoutKey(btns[idx].label);
        _editDrag = _editSelected;
        [self setNeedsDisplay];
        return;
    }
    CGPoint home = [self stickHomePoint];
    if (hypot(pnt.x - home.x, pnt.y - home.y) <= kStickHaloR) {
        _editDrag = @"__stick";
    }
}

- (void)editMoved:(CGPoint)pnt {
    CGRect b = self.bounds;
    if (_editDrag == nil) {
        return;
    }
    if ([_editDrag isEqualToString:@"__slider"]) {
        CGRect s = [self editSliderRect];
        CGFloat frac = MAX(0.0, MIN(1.0, (pnt.x - CGRectGetMinX(s)) / CGRectGetWidth(s)));
        _layoutScale = 0.7 + frac * (1.4 - 0.7);
        [self setNeedsDisplay];
        return;
    }
    CGFloat m = 30;
    CGPoint clamped = CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, pnt.x)),
                                  MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, pnt.y)));
    // un-mirror before storing so lefty users edit in their own view
    clamped = [self applyLefty:clamped];
    CGSize ref = [self layoutRefSize];
    CGPoint normalized = CGPointMake(clamped.x / ref.width, clamped.y / ref.height);
    if ([_editDrag isEqualToString:@"__stick"]) {
        _stickHome = normalized;
    } else {
        _layoutOverrides[_editDrag] = [NSValue valueWithCGPoint:normalized];
    }
    [self setNeedsDisplay];
}

- (void)editEnded {
    _editDrag = nil;
}
// ----------------------------------------------------------------------------

// The stick is FLOATING: hidden until a touch lands inside its spawn halo
// (customizable home), then its base is wherever the finger came down.
- (BOOL)pointInStickRegion:(CGPoint)p {
#if TARGET_OS_VISION
    // Gaze-pinch has no proprioception — you can't feel where the spawn
    // halo is, so on visionOS the ENTIRE left half spawns the stick
    // (user report: pinch on the left side did nothing). Buttons are
    // hit-tested before the stick region, so they keep priority; near-miss
    // protection below still applies (a missed Z/L pinch must be a dead
    // pinch, not a surprise stick).
    if (p.x >= CGRectGetMidX(self.bounds)) {
        return NO;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (int i = 0; i < n; i++) {
        BOOL guarded = [btns[i].label isEqualToString:@"Z"] || [btns[i].label isEqualToString:@"L"] ||
                       [btns[i].label isEqualToString:@"≡"];
        if (guarded && [self isButtonHidden:btns[i].label]) {
            continue; // a hidden button leaves no dead zone
        }
        // buttonRects radii are already _layoutScale-scaled; only the
        // 26 pt near-miss margin needs scaling here.
        if (guarded &&
            hypot(p.x - btns[i].center.x, p.y - btns[i].center.y) <= btns[i].radius * 1.35 + 26 * _layoutScale) {
            return NO;
        }
    }
    return YES;
#else
    CGPoint home = [self stickHomePoint];
    if (hypot(p.x - home.x, p.y - home.y) > kStickHaloR) {
        return NO;
    }
    // Z protection (device feedback): a halo around Z never spawns the
    // stick — a missed Z tap is a dead tap, not a surprise stick. Skipped
    // when Z is hidden (no button there = no dead zone).
    if (![self isButtonHidden:@"Z"]) {
        CGPoint zC = [self zButtonCenter];
        if (hypot(p.x - zC.x, p.y - zC.y) <= (34 * 1.35 + 26) * _layoutScale) {
            return NO;
        }
    }
    return YES;
#endif
}

- (CGPoint)clampStickBase:(CGPoint)p {
    CGRect b = self.bounds;
    CGFloat m = _stickBaseR + 14; // keep the drawn ring on-screen
    return CGPointMake(MAX(b.origin.x + m, MIN(CGRectGetMaxX(b) - m, p.x)),
                       MAX(b.origin.y + m, MIN(CGRectGetMaxY(b) - m, p.y)));
}

- (NSArray<NSValue*>*)buttonRects:(SohButton*)outButtons count:(int*)outCount {
    CGRect b = self.bounds;
    CGFloat maxX = CGRectGetMaxX(b), maxY = CGRectGetMaxY(b);
    UIColor* cYellow = [UIColor colorWithRed:0.95 green:0.80 blue:0.15 alpha:0.55];
    UIColor* cBlue = [UIColor colorWithRed:0.20 green:0.45 blue:0.95 alpha:0.6];
    UIColor* cGreen = [UIColor colorWithRed:0.20 green:0.75 blue:0.35 alpha:0.6];
    UIColor* cGray = [UIColor colorWithWhite:0.6 alpha:0.55];
    UIColor* cRed = [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.6];
    // A/B primary cluster, bottom-right corner (v2: -20% radii per device
    // feel; program-wide unified layout 2026-07-21: cluster up ~20pt off the
    // very corner — Ghostship device-tuned, user wants identical defaults
    // across every HM port).
    CGFloat aX = maxX - 85, aY = maxY - 105;
    // C-button diamond, above the A/B cluster (kept fully on-screen).
    CGFloat cX = maxX - 105, cY = maxY - 235;
    SohButton btns[] = {
        { CGPointMake(aX, aY), 37, cBlue, @"A" },
        { CGPointMake(aX - 92, aY - 18), 32, cGreen, @"B" }, // a hair down toward Z (unified layout)
        { CGPointMake(cX, cY - 38), 27, cYellow, @"C↑" },
        { CGPointMake(cX, cY + 38), 27, cYellow, @"C↓" },
        { CGPointMake(cX - 40, cY), 27, cYellow, @"C←" },
        { CGPointMake(cX + 40, cY), 27, cYellow, @"C→" },
        // Z below A/B, EQUIDISTANT from both (unified layout, Ghostship
        // device-tuned): aX-68, not the plain midpoint aX-46 — A and B sit at
        // different heights (|Z-A|=92.7, |Z-B|=92.2). Thumb-reach beside
        // jump/attack enables the Z→A slide long-jump class of inputs, and it
        // clears the iOS edge-gesture zones that ate the old upper-left spot
        // (the stuck-Z story).
        { CGPointMake(aX - 68, maxY - 42), 34, cGray, @"Z" },
        { CGPointMake(b.origin.x + 80, b.origin.y + 60), 34, cGray, @"L" },
        { CGPointMake(maxX - 80, b.origin.y + 60), 34, cGray, @"R" },
        // START and ≡ swapped per device feedback: START bottom-center,
        // menu button top-center (visible only in intro/pause contexts).
        { CGPointMake(CGRectGetMidX(b), maxY - 45), 30, cRed, @"START" },
        { CGPointMake(CGRectGetMidX(b), b.origin.y + 55), 26, cGray, @"≡" },
    };
    int n = (int)(sizeof(btns) / sizeof(btns[0]));
    for (int i = 0; i < n; i++) {
        // Customized layout: per-button normalized centers (canonical
        // landscape reference) + lefty mirror + global scale.
        NSValue* ov = _layoutOverrides[SohIos_LayoutKey(btns[i].label)];
        if (ov != nil) {
            CGPoint nrm = [ov CGPointValue];
            CGSize ref = [self layoutRefSize];
            btns[i].center = CGPointMake(nrm.x * ref.width, nrm.y * ref.height);
        }
        btns[i].center = [self applyLefty:btns[i].center];
        btns[i].radius *= _layoutScale;
        outButtons[i] = btns[i];
    }
    *outCount = n;
    return nil;
}

- (void)drawGlyph:(NSString*)glyph at:(CGPoint)c size:(CGFloat)fontSize alpha:(CGFloat)alpha {
    NSDictionary* attrs = @{
        NSFontAttributeName : [UIFont boldSystemFontOfSize:fontSize],
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1 alpha:alpha]
    };
    CGSize sz = [glyph sizeWithAttributes:attrs];
    [glyph drawAtPoint:CGPointMake(c.x - sz.width / 2, c.y - sz.height / 2) withAttributes:attrs];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();

    if (_editMode) {
        // --- Customizer: everything visible and draggable ---
        // Stick spawn halo (moves with its home).
        CGPoint home = [self stickHomePoint];
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.16] setFill];
        CGContextFillEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        [[UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(
            ctx, CGRectMake(home.x - kStickHaloR, home.y - kStickHaloR, kStickHaloR * 2, kStickHaloR * 2));
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        CGContextSetLineWidth(ctx, 4);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(home.x - ringR, home.y - ringR, ringR * 2, ringR * 2));
        [[UIColor colorWithWhite:1 alpha:0.35] setFill];
        CGFloat knobR = _stickKnobR * _layoutScale;
        CGContextFillEllipseInRect(ctx, CGRectMake(home.x - knobR, home.y - knobR, knobR * 2, knobR * 2));

        // All buttons at their (possibly overridden) spots. Hidden buttons are
        // ghosted (low opacity) so the user still sees them to reposition or
        // un-hide. The eye chip appears on the SELECTED button ONLY (the last
        // one touched) — no chip at all until the user touches a button.
        SohButton ebtns[16];
        int en = 0;
        [self buttonRects:ebtns count:&en];
        for (int i = 0; i < en; i++) {
            SohButton bt = ebtns[i];
            BOOL hidden = [self isButtonHidden:bt.label];
            BOOL selected = (_editSelected != nil && [_editSelected isEqualToString:SohIos_LayoutKey(bt.label)]);
            CGFloat fillA = hidden ? 0.22 : 1.0, strokeA = hidden ? 0.28 : 0.7, glyphA = hidden ? 0.35 : 0.95;
            [[bt.color colorWithAlphaComponent:CGColorGetAlpha(bt.color.CGColor) * fillA] setFill];
            [[UIColor colorWithWhite:1 alpha:(selected ? 1.0 : strokeA)] setStroke];
            CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
            CGContextSetLineWidth(ctx, selected ? 3 : 2); // selected button: brighter ring
            CGContextFillEllipseInRect(ctx, r);
            CGContextStrokeEllipseInRect(ctx, r);
            [self drawGlyph:bt.label at:bt.center size:16 * _layoutScale alpha:glyphA];
            if (selected && ![bt.label isEqualToString:@"≡"]) {
                [self drawHideBadgeAt:[self hideBadgeCenterForCenter:bt.center radius:bt.radius] hidden:hidden];
            }
        }

        // Chrome strip: [reset][scale slider][save]
        CGRect chrome = [self editChromeRect];
        [[UIColor colorWithWhite:0 alpha:0.55] setFill];
        UIBezierPath* rounded = [UIBezierPath bezierPathWithRoundedRect:chrome cornerRadius:14];
        [rounded fill];
        CGPoint reset = [self editResetCenter];
        [[UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:0.9] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(reset.x - 20, reset.y - 20, 40, 40));
        [self drawGlyph:@"\u21ba" at:reset size:22 alpha:1.0];
        CGPoint save = [self editSaveCenter];
        [[UIColor colorWithRed:0.2 green:0.7 blue:0.35 alpha:0.95] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(save.x - 20, save.y - 20, 40, 40));
        [self drawGlyph:@"\u2713" at:save size:22 alpha:1.0];
        CGRect s = [self editSliderRect];
        [[UIColor colorWithWhite:1 alpha:0.3] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:s cornerRadius:4] fill];
        CGFloat frac = (_layoutScale - 0.7) / (1.4 - 0.7);
        CGFloat thumbX = CGRectGetMinX(s) + frac * CGRectGetWidth(s);
        [[UIColor whiteColor] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(thumbX - 10, CGRectGetMidY(s) - 10, 20, 20));
        NSString* pct = [NSString stringWithFormat:@"%d%%", (int)round(_layoutScale * 100)];
        [self drawGlyph:pct at:CGPointMake(CGRectGetMidX(chrome), CGRectGetMinY(chrome) - 12) size:13 alpha:0.9];
        return;
    }

    if (_popupOpen) {
        return; // a popup owns the screen: draw nothing at all
    }

    if (_controlsHidden) {
        // Menu is open: draw only the small restore dot.
        CGPoint dot = [self restoreDotCenter];
        [[UIColor colorWithWhite:1 alpha:0.25] setFill];
        CGContextFillEllipseInRect(ctx, CGRectMake(dot.x - 22, dot.y - 22, 44, 44));
        [self drawGlyph:@"≡" at:dot size:18 alpha:0.8];
        return;
    }

    if (_controllerMode) {
        // Physical controller drives the game: no touch controls. The ≡
        // button follows the same visibility policy as touch (intro/title
        // and pause only), keeping the SoH menu reachable without clutter.
        if ([self menuButtonVisible]) {
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            SohButton menuBtn = btns[n - 1]; // ≡ is last
            [menuBtn.color setFill];
            CGRect r = CGRectMake(menuBtn.center.x - menuBtn.radius, menuBtn.center.y - menuBtn.radius,
                                  menuBtn.radius * 2, menuBtn.radius * 2);
            CGContextFillEllipseInRect(ctx, r);
            [self drawGlyph:@"≡" at:menuBtn.center size:20 alpha:0.95];
        }
        return;
    }

    // Floating left stick: drawn only while a finger holds it.
    if (_stickActive) {
        CGContextSetLineWidth(ctx, 4);
        [[UIColor colorWithWhite:1 alpha:0.35] setStroke];
        CGFloat ringR = (_stickBaseR + 8) * _layoutScale;
        CGContextStrokeEllipseInRect(ctx,
                                     CGRectMake(_stickBase.x - ringR, _stickBase.y - ringR, ringR * 2, ringR * 2));
        [[UIColor colorWithWhite:1 alpha:0.28] setFill];
        CGFloat knobR = _stickKnobR * _layoutScale;
        CGContextFillEllipseInRect(ctx,
                                   CGRectMake(_stickKnob.x - knobR, _stickKnob.y - knobR, knobR * 2, knobR * 2));
    }

    // Buttons. Labels only where the glyph isn't obvious (L/R/Z + ≡).
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    BOOL menuBtnVisible = [self menuButtonVisible];
    for (int i = 0; i < n; i++) {
        SohButton bt = btns[i];
        BOOL isZ = [bt.label isEqualToString:@"Z"];
        if ([bt.label isEqualToString:@"≡"] && !menuBtnVisible) {
            continue; // hidden during normal gameplay
        }
        if ([self isButtonHidden:bt.label]) {
            continue; // user-hidden from the touch layer (customizer)
        }
        if (isZ && _zLocked) {
            // Double-tap lock engaged: unmistakably "on".
            [[UIColor colorWithRed:0.30 green:0.60 blue:1.0 alpha:0.9] setFill];
            [[UIColor colorWithWhite:1 alpha:0.95] setStroke];
        } else if (isZ && _zHeld) {
            // Momentary hold: clearly active, dimmer than the lock.
            [[UIColor colorWithRed:0.25 green:0.45 blue:0.8 alpha:0.7] setFill];
            [[UIColor colorWithWhite:1 alpha:0.7] setStroke];
        } else {
            [bt.color setFill];
            [[UIColor colorWithWhite:1 alpha:0.5] setStroke];
        }
        CGRect r = CGRectMake(bt.center.x - bt.radius, bt.center.y - bt.radius, bt.radius * 2, bt.radius * 2);
        CGContextSetLineWidth(ctx, isZ && _zLocked ? 4 : 3);
        CGContextFillEllipseInRect(ctx, r);
        CGContextStrokeEllipseInRect(ctx, r);
        BOOL labeled = isZ || [bt.label isEqualToString:@"L"] || [bt.label isEqualToString:@"R"] ||
                       [bt.label isEqualToString:@"≡"];
        if (labeled) {
            [self drawGlyph:bt.label at:bt.center size:20 alpha:0.95];
        }
    }
}

// Pass-through: only the stick zone and button circles intercept touches;
// everywhere else falls through to SDL's view (game taps, ImGui menu).
// While hidden (menu open), ONLY the restore dot intercepts.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    if (_editMode) {
        return YES; // customizer owns the screen
    }
    if (_popupOpen) {
        return NO; // popup owns all input (extractor Yes/No etc.)
    }
    if (_controlsHidden) {
        return YES; // menu open: the touch-router owns every touch
    }
    if (_controllerMode) {
        // Only the ≡ button (and only when visible per policy) is touch-active.
        if (![self menuButtonVisible]) {
            return NO;
        }
        SohButton btns[16];
        int n = 0;
        [self buttonRects:btns count:&n];
        SohButton menuBtn = btns[n - 1];
        return hypot(point.x - menuBtn.center.x, point.y - menuBtn.center.y) <= menuBtn.radius * 1.35;
    }
    if ([self hitButton:point] >= 0) {
        return YES;
    }
    return [self pointInStickRegion:point]; // floating stick spawns anywhere here
}

// --- Menu touch-router -------------------------------------------------
// While the SoH menu is open the overlay owns every touch and forwards
// SYNTHESIZED mouse events, because raw touch-as-mouse reads as hover
// (tooltips) and can never scroll. Taps click; vertical drags scroll
// (wheel); horizontal drags press-and-drag (sliders); a 450 ms hold
// hovers (tooltip), cleared on release.
- (void)routerReset {
    _routerTouch = nil;
    _routerMode = 0;
}

- (void)routerBegan:(UITouch*)t {
    if (_routerTouch != nil) {
        return; // single-touch menu interaction
    }
    _routerTouch = t;
    _routerMode = 0;
    _routerStart = _routerLast = [t locationInView:self];
    const void* captured = (__bridge const void*)t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ((__bridge const void*)self->_routerTouch == captured && self->_routerMode == 0 && self->_controlsHidden) {
            self->_routerMode = 3; // hover: tooltip appears under the held finger
            SohIos_InjectMouseMotion((int)self->_routerStart.x, (int)self->_routerStart.y);
        }
    });
}

- (void)routerMoved:(UITouch*)t {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 0) {
        CGFloat dx = pnt.x - _routerStart.x, dy = pnt.y - _routerStart.y;
        if (hypot(dx, dy) > 8.0) {
            if (fabs(dy) > fabs(dx) * 1.15) {
                _routerMode = 1; // scroll: mouse-free (no hover -> no tooltips/slider side-effects)
            } else {
                _routerMode = 2; // drag: real press for sliders/scrollbars
                SohIos_InjectMouseMotion((int)_routerStart.x, (int)_routerStart.y);
                SohIos_InjectMouseButton((int)_routerStart.x, (int)_routerStart.y, YES);
            }
        }
    }
    if (_routerMode == 1) {
        CGFloat dy = pnt.y - _routerLast.y;
        if (fabs(dy) >= 1.0) {
            SohIos_QueueMenuScroll((float)pnt.x, (float)dy);
            _routerLast = pnt;
        }
    } else if (_routerMode == 2) {
        SohIos_InjectMouseMotion((int)pnt.x, (int)pnt.y);
        _routerLast = pnt;
    }
}

- (void)routerEnded:(UITouch*)t cancelled:(BOOL)cancelled {
    if (t != _routerTouch) {
        return;
    }
    CGPoint pnt = [t locationInView:self];
    if (_routerMode == 2) {
        SohIos_InjectMouseButton((int)pnt.x, (int)pnt.y, NO);
    } else if (_routerMode == 3) {
        // clear the hover so the tooltip dismisses
        SohIos_InjectMouseMotion((int)self.bounds.size.width - 2, (int)self.bounds.size.height - 2);
    } else if (_routerMode == 0 && !cancelled) {
        CGPoint dot = [self restoreDotCenter];
        if (hypot(pnt.x - dot.x, pnt.y - dot.y) <= 34) {
            SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE); // restore dot: close menu
            _controlsHidden = NO;
            [self setNeedsDisplay];
        } else {
            SohIos_InjectClick((int)pnt.x, (int)pnt.y);
        }
    }
    [self routerReset];
}
// ------------------------------------------------------------------------

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editBegan:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerBegan:t];
        }
        return;
    }
    if (_controllerMode) {
        // pointInside already vetted this as a paused-state ≡ tap.
        SohIos_InjectKey(SDLK_ESCAPE, SDL_SCANCODE_ESCAPE);
        _controlsHidden = YES;
        [self setNeedsDisplay];
        return;
    }
    for (UITouch* t in touches) {
        CGPoint p = [t locationInView:self];
        int idx = [self hitButton:p];
        if (idx >= 0) {
            _touchButtons[[NSValue valueWithPointer:(__bridge const void*)t]] = @(idx);
            SohButton btns[16];
            int n = 0;
            [self buttonRects:btns count:&n];
            [self hapticTap];
            [self applyButton:btns[idx].label down:YES];
        } else if (!_stickActive && [self pointInStickRegion:p]) {
            // Floating stick: base is where the finger landed.
            [self hapticTap];
            _stickActive = YES;
            _stickTouch = t;
            _stickBase = [self clampStickBase:p];
            _stickKnob = _stickBase;
            [self updateStickAxesFromKnob];
            [self setNeedsDisplay];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        for (UITouch* t in touches) {
            [self editMoved:[t locationInView:self]];
            break;
        }
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerMoved:t];
        }
        return;
    }
    // Button slide-across (Ghostship cross-port fix, device-confirmed): a
    // finger that slides from one button onto a DIFFERENT one transfers the
    // press (release old, press new) — the Z→A slide long-jump / B→A dive
    // class of inputs consoles always had. Sliding through the gap between
    // buttons KEEPS the current button held, so Z stays down right until the
    // finger reaches A. Never stores -1 (empty space leaves the binding
    // untouched); updates _touchButtons BEFORE applyButton so the C-axis
    // recompute sees the post-transfer state.
    if (_touchButtons.count > 0) {
        SohButton sbtns[16];
        int sn = 0;
        [self buttonRects:sbtns count:&sn];
        for (UITouch* t in touches) {
            NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
            NSNumber* boundIdx = _touchButtons[key];
            if (boundIdx == nil) {
                continue; // stick touch — handled below
            }
            int boundI = boundIdx.intValue;
            int nowIdx = [self hitButton:[t locationInView:self]];
            if (nowIdx >= 0 && nowIdx != boundI) {
                _touchButtons[key] = @(nowIdx);
                if (boundI >= 0 && boundI < sn) {
                    [self applyButton:sbtns[boundI].label down:NO];
                }
                [self applyButton:sbtns[nowIdx].label down:YES];
            }
        }
    }
    if (!_stickActive) {
        return;
    }
    for (UITouch* t in touches) {
        if (t != _stickTouch) {
            continue;
        }
        CGPoint p = [t locationInView:self];
        CGFloat dx = p.x - _stickBase.x, dy = p.y - _stickBase.y;
        CGFloat d = hypot(dx, dy);
        if (d > _stickBaseR) {
            dx = dx / d * _stickBaseR;
            dy = dy / d * _stickBaseR;
        }
        CGPoint knob = CGPointMake(_stickBase.x + dx, _stickBase.y + dy);
        if (hypot(knob.x - _stickKnob.x, knob.y - _stickKnob.y) < 1.0) {
            continue; // sub-point jitter: no axis send, no redraw
        }
        _stickKnob = knob;
        [self updateStickAxesFromKnob];
        [self setNeedsDisplay];
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:NO];
        }
        return;
    }
    SohButton btns[16];
    int n = 0;
    [self buttonRects:btns count:&n];
    for (UITouch* t in touches) {
        NSValue* key = [NSValue valueWithPointer:(__bridge const void*)t];
        NSNumber* idx = _touchButtons[key];
        if (idx != nil) {
            [_touchButtons removeObjectForKey:key];
            [self applyButton:btns[idx.intValue].label down:NO];
        }
        if (t == _stickTouch) {
            _stickActive = NO;
            _stickTouch = nil;
            _stickKnob = _stickBase;
            _lastSentLX = _lastSentLY = 0;
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTX, 0);
            SohIos_PadAxis(SDL_CONTROLLER_AXIS_LEFTY, 0);
            [self setNeedsDisplay];
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if (_editMode) {
        [self editEnded];
        return;
    }
    if (_controlsHidden) {
        for (UITouch* t in touches) {
            [self routerEnded:t cancelled:YES];
        }
        return;
    }
    [self touchesEnded:touches withEvent:event];
}
@end

static UIWindow* SohIos_GetSDLWindow(struct SDL_Window* sdlWindow) {
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(sdlWindow, &wm) || wm.subsystem != SDL_SYSWM_UIKIT) {
        return nil;
    }
    return wm.info.uikit.window;
}

static UIWindowScene* SohIos_ActiveScene(void) {
    UIWindowScene* fallback = nil;
    for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        if (s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene*)s;
        }
        fallback = (UIWindowScene*)s;
    }
    return fallback;
}

// Nudge the scene to landscape if needed. Retries a few times since the scene
// can lag window creation on iOS 26.
static void SohIos_EnsureLandscape(UIWindow* window, int attempt) {
    UIWindowScene* scene = SohIos_ActiveScene();
    if (scene == nil && attempt < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ SohIos_EnsureLandscape(window, attempt + 1); });
        return;
    }
    if (scene == nil) {
        return;
    }
    if (window.windowScene != scene) {
        window.windowScene = scene;
    }
    SohIos_GlueWindowToScene(window, scene);
    UIInterfaceOrientation o = scene.interfaceOrientation;
    if (o == UIInterfaceOrientationLandscapeLeft || o == UIInterfaceOrientationLandscapeRight) {
        return; // already landscape
    }
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS* prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
            initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
        [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError* e) {
            NSLog(@"[SohIosShell] landscape request failed: %@", e);
        }];
        [window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    }
}

// Region probe for the bridge `stickregion` command. MAIN THREAD ONLY.
// Returns 1/0 for in/out of the stick spawn region, -2 if no overlay found.
@interface SohIosTouchOverlay (SohStickProbe)
- (BOOL)pointInStickRegion:(CGPoint)p; // defined in the main @implementation
- (NSString*)hideProbe:(NSArray<NSString*>*)a;
@end

int SohIos_ProbeStickRegion(CGFloat x, CGFloat y, CGSize* outBounds) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        UIView* root = w.rootViewController.view ?: w;
        for (UIView* v in root.subviews) {
            if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                if (outBounds != NULL) {
                    *outBounds = v.bounds.size;
                }
                return [(SohIosTouchOverlay*)v pointInStickRegion:CGPointMake(x, y)] ? 1 : 0;
            }
        }
    }
    return -2;
}

// Bridge `hideprobe` backend. Dispatches to the main thread (UIKit) and
// polls, mirroring stickregion.
NSString* SohIos_LayoutHideProbe(NSArray<NSString*>* args) {
    __block NSString* out = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* r = @"err no overlay";
        for (UIWindow* w in UIApplication.sharedApplication.windows) {
            UIView* root = w.rootViewController.view ?: w;
            for (UIView* v in root.subviews) {
                if ([v isKindOfClass:SohIosTouchOverlay.class]) {
                    r = [(SohIosTouchOverlay*)v hideProbe:args];
                    break;
                }
            }
        }
        out = r;
    });
    for (int i = 0; i < 200 && out == nil; i++) {
        usleep(10 * 1000);
    }
    return out ?: @"err timeout";
}

static void SohIos_InstallOverlay(UIWindow* window) {
    // Add the touch overlay above SDL's Metal view, tracking the window bounds.
    for (UIView* v in window.subviews) {
        if ([v isKindOfClass:SohIosTouchOverlay.class]) {
            return; // already installed
        }
    }
    UIView* host = window.rootViewController.view ?: window;
    SohIosTouchOverlay* overlay = [[SohIosTouchOverlay alloc] initWithFrame:host.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:overlay];
#if TARGET_OS_VISION
    // Claim gamepad events app-wide: visionOS otherwise routes pad input to
    // the gaze-and-pinch UI layer and GCController/SDL sees a dead pad
    // (VISION-PRO-GUIDE 1.3).
    if (@available(visionOS 2.0, *)) {
        GCEventInteraction* padClaim = [GCEventInteraction new];
        padClaim.handledEventTypes = GCUIEventTypeGamepad;
        [host addInteraction:padClaim];
        NSLog(@"[SohIosShell] GCEventInteraction gamepad claim installed");
    }
    // An app with an EMPTY Documents dir is invisible in the Files app —
    // seed a readme so the user has a drop target for the ROM/o2r
    // (VISION-PRO-GUIDE 1.5).
    {
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* readme = [docs stringByAppendingPathComponent:@"DROP-ROM-OR-O2R-HERE.txt"];
        if (![NSFileManager.defaultManager fileExistsAtPath:readme]) {
            [@"Drop your Ocarina of Time ROM (.z64) or an extracted oot.o2r here,\n"
              "then relaunch Ship of Harkinian.\n"
                writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
#endif
    NSLog(@"[SohIosShell] touch overlay installed (%.0fx%.0f)", host.bounds.size.width, host.bounds.size.height);
    SohIos_AttachVirtualPad();
    SohIos_ScheduleSelfTest();
}

// The overlay would eat the extractor popups' taps (the stick zone overlaps
// them), and it's useless before game data exists — so install it only once
// an extracted archive is present (poll; extraction can take a while).
static void SohIos_InstallOverlayWhenReady(UIWindow* window, int attempt) {
    if (SohIos_DocumentsHasExt(@[ @"o2r" ])) {
        SohIos_InstallOverlay(window);
        return;
    }
    if (attempt < 1200) { // up to ~20 min of onboarding time
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, attempt + 1); });
    }
}

void SohIos_OnWindowCreated(struct SDL_Window* sdlWindow) {
    gSdlWindow = sdlWindow;
    // Not overlay-dependent — must be live during onboarding too (a crash or
    // remote-debug need can precede game data existing).
    SohIos_InstallCrashHandler();
    SohIos_StartConsoleBridge(NO);
    SohIos_InstallConfigPersist(); // flush CVars on resign (swipe-kill safety)
    dispatch_async(dispatch_get_main_queue(), ^{ SohIos_InstallBackgroundReconciler(); });
    SohIos_SeedDefaultsOnce();     // per-device fidelity defaults, first run only
    SDL_SetEventFilter(SohIos_EventFilter, NULL); // soh:// deep links + stray-Escape guard
    // Input environment, first lines of the trace: which device, which pads,
    // and whether a hardware keyboard is attached — the last one decides
    // which of SDL's UIKit keyboard routes was even live on the reporter's
    // iPad (pressesBegan: is skipped whenever a GCKeyboard exists).
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    SohIos_Trace(@"soh %@ (build %@) on %@ %@", info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"],
                 UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion);
    SohIos_Trace(@"hardware keyboard attached: %@", GCKeyboard.coalescedKeyboard != nil ? @"YES" : @"no");
    SohIos_Trace(@"controllers: %@",
                 GCController.controllers.count
                     ? [[GCController.controllers valueForKey:@"vendorName"] componentsJoinedByString:@", "]
                     : @"(none yet)");
    UIWindow* window = SohIos_GetSDLWindow(sdlWindow);
    if (window == nil) {
        NSLog(@"[SohIosShell] no UIKit window for SDL window");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SohIos_InstallSceneDelegate(); // soh:// URL delivery (scene-routed)
        SohIos_EnsureLandscape(window, 0);
        // Native ROM picker if there's nothing to play yet .
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ [SohIosOnboarding maybePresentIn:window]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, 0); });
    });
}

// ---------------------------------------------------------------------------
// R10 verdict 5: THE SENSE PAIR IN 2D
// ---------------------------------------------------------------------------
//
// the user, on 1.0.1.13: *"The VR controllers no longer work in 2D mode. Is there
// a way to allow it in 2D without messing up VR?"*
//
// Two mechanisms in series took them away, and BOTH were correct on their own.
// Overlay 0052 removed a spatial controller from SDL's gamepad enumeration,
// because SDL's MFi backend accepts any GCController with a physicalInputProfile
// and SoH's default mapping then bound the Sense right stick to the four C
// buttons -- the complaint that survived two rounds. Overlay 0047's merge, which
// is what a Sense unit reaches the game through instead, was gated on
// `gSohVRMode != 0`. Outside VR, therefore: not a gamepad, and not merged.
// Nothing polled them at all.
//
// The tracking half genuinely needs VR (an ARKit session, a head pose, an
// anchor); the BUTTONS AND STICKS need none of it -- they are ordinary
// GameController inputs. So this pump reads exactly that half, on the game
// thread, from overlay 0047's own hook, and publishes into the same words the VR
// loop publishes. The VR loop OWNS those words while it runs, so the pump stands
// down for it: one producer at a time, whichever mode is live.
//
// TARGET_OS_VISION, because SohSense.m is only compiled into the visionOS
// target; on iPhone this is a no-op and the call from overlay 0047 still links.
void SohVR_SenseFlatPump(void) {
#if TARGET_OS_VISION
    extern volatile int gSohVRRunning;
    if (gSohVRRunning) {
        // The compositor loop is publishing these words this frame. Nothing to
        // do, and writing them from here would be two producers on one datum.
        gSohVRSenseFlat = 0;
        return;
    }
    SohSense_UpdateFlat();
    for (int h = 0; h < 2; h++) {
        float sx = 0.0f, sy = 0.0f;
        gSohVRSenseBtn[h] = SohSense_HandButtons(h);
        SohSense_HandStick(h, &sx, &sy);
        gSohVRSenseStickX[h] = sx;
        gSohVRSenseStickY[h] = sy;
    }
    gSohVRSenseActive = SohSense_Active();
    gSohVRSenseFlat = gSohVRSenseActive;
#else
    gSohVRSenseFlat = 0;
#endif
}
