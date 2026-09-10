// SohSense.m — PSVR2 Sense controllers on visionOS. See SohSense.h for the
// provenance, the two scars that look like hardware faults, and why this file
// derives velocity even though ARKit supplies it.

#import "SohSense.h"

#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>
#import <os/lock.h>

#define SOHSENSE_MAX_ACCESSORIES 4

// ---------------------------------------------------------------------------
// State. Plain storage, `volatile int` validity published LAST — the same
// discipline the eye-pose publish uses, for the same reason: a reader that
// catches a torn pose must catch it as "not valid" rather than as a pose.
// ---------------------------------------------------------------------------

static simd_float4x4 sHandWorld[SOHSENSE_HANDS] = {
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } }
};
static simd_float3 sHandVel[SOHSENSE_HANDS];    // ORIGIN frame, m/s, filtered
static simd_float3 sHandAngVel[SOHSENSE_HANDS]; // ORIGIN frame, rad/s, filtered
// The two provenances, kept side by side so `vr hands` can report them
// together. `rt` is what the runtime handed us; `dv` is what we derived from
// consecutive poses. The first headset session reads one line and knows which
// to trust — the donor map lists velocity provenance as one of the two real
// risks of this transfer (DONOR-MAP §8e), and a disagreement here IS that risk.
static simd_float3 sVelRuntime[SOHSENSE_HANDS], sAngVelRuntime[SOHSENSE_HANDS];
static simd_float3 sVelDerived[SOHSENSE_HANDS], sAngVelDerived[SOHSENSE_HANDS];
static int sHaveRuntimeVel[SOHSENSE_HANDS];

// R9 part A: THE GRIP COORDINATE SPACE.
//
// `ar_accessory_anchor_get_origin_from_anchor_transform` returns the ANCHOR
// pose, and an accessory's anchor origin is the origin of its MODEL -- not the
// point at which a person's fist closes around it. On a PS VR2 Sense that is
// centimetres away, along the barrel, and every centimetre of it is a lever
// arm: a wrist roll rotates about the hand, so a body rigidly attached to the
// ANCHOR sweeps an arc of exactly that radius. That is the user's "the hand
// rolls around my controller instead of turning in place", and it is also why
// the offsets he dialled came out at 10-17 cm when a real grip-to-palm offset
// is a few.
//
// visionOS 26 publishes the fix directly:
// `ar_accessory_anchor_get_anchor_from_location_transform_with_correction`,
// with the pre-defined location names `ar_accessory_location_name_grip`,
// `..._grip_surface` and `..._aim`. Composing anchor x anchorFromGrip gives a
// pose whose ORIGIN is where the accessory is held, so a pure roll about the
// grip axis leaves it standing still.
//
// THE COMPOSITION HAPPENS HERE, at the single point where a tracked pose
// enters the program, so everything downstream -- the solver, the calibration,
// the drawn hand, the blade line, the rigidity readout -- sees one pose source
// and cannot disagree about it. `vr set gripspace 0` is the A/B.
//
// The transform is per ACCESSORY MODEL, so it is a runtime constant we cannot
// know on this Mac (there is no spatial hardware in the simulator). It is
// logged once per hand at the first tracked anchor and printed by `vr hands`
// as `gripoff=`, which is how the Sense's actual number gets recorded.
static simd_float4x4 sAnchorFromGrip[SOHSENSE_HANDS] = {
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
};
static int sGripHave[SOHSENSE_HANDS] = { 0, 0 };
// 0 = none (the raw anchor is the pose), 1 = grip, 2 = grip_surface,
// 3 = injected by the harness.
static int sGripSrc[SOHSENSE_HANDS] = { 0, 0 };
static int sGripLogged[SOHSENSE_HANDS] = { 0, 0 };
// R15 (VR): THE AIM LOCATION. The Sense controller publishes a SECOND named
// location beside the grip -- ar_accessory_location_name_aim, "the aim point"
// -- which is the runtime's own answer to "where is this controller pointing".
// Every aim before this round was derived from the hand MESH calibration, a
// frame dialled so a sword sits in a fist and a shield sits on a forearm, and
// neither of those is a pointing direction. Captured beside the grip, logged
// once, and published as a pose of its own; the physics substitution and the
// hand calibration never touch it.
static simd_float4x4 sAnchorFromAim[SOHSENSE_HANDS] = {
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
};
static int sAimHave[SOHSENSE_HANDS] = { 0, 0 };
// 0 = the runtime returned the identity (no aim location: the anchor IS the
// aim), 1 = a real aim transform, 3 = injected by the harness.
static int sAimSrc[SOHSENSE_HANDS] = { 0, 0 };
static int sAimLogged[SOHSENSE_HANDS] = { 0, 0 };
// The raw anchor pose, kept beside the published grip pose. Velocities arrive
// in the ACCESSORY's local frame, so they are rotated by the ANCHOR's rotation
// and not the grip's -- those two differ by whatever rotation the grip
// location carries, and using the wrong one is invisible at rest.
static simd_float4x4 sAnchorWorld[SOHSENSE_HANDS] = {
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
    { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } },
};

static volatile int sHandValid[SOHSENSE_HANDS] = { 0, 0 };
static volatile int sHandHeld[SOHSENSE_HANDS] = { 0, 0 };
static volatile int sHandInjected[SOHSENSE_HANDS] = { 0, 0 };
static int sVelInjected[SOHSENSE_HANDS] = { 0, 0 };
static int sAngVelInjected[SOHSENSE_HANDS] = { 0, 0 };

// Previous pose + its timestamp, for the derived velocities.
static simd_float4x4 sPrevWorld[SOHSENSE_HANDS];
static double sPrevTime[SOHSENSE_HANDS];
static int sHavePrev[SOHSENSE_HANDS];

static volatile uint32_t sHandBtn[SOHSENSE_HANDS];
static float sHandStickX[SOHSENSE_HANDS], sHandStickY[SOHSENSE_HANDS];
static volatile int sBtnInjected = 0;

static simd_float4x4 sHeadWorld = { { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } } };
static int sHaveHead = 0;

// Discovery / authorization / load bookkeeping. Every counter here exists
// because the sibling's decision table (loads 0 / fails>0 / polls 0 / anchors 0)
// is the only way to tell four very different failures apart from a headset.
static GCController* sPad[SOHSENSE_HANDS];
// R10 verdict 5: 1 while that slot was filled by CONNECTION ORDER rather than by
// chirality. Chirality is the only authority and always wins (see the load
// callback), but it arrives from `ar_accessory_load_from_device`, and a load can
// fail or simply not have happened yet -- and in the flat window, where the pair
// is now an ordinary N64 pad, "which unit is the left one" only decides which
// stick moves and which is the C pad. A provisional slot is what makes the
// controllers work in 2D at all if accessory loading never succeeds there; a
// swapped pair is a worse outcome than a dead pair only if you cannot swap it
// back, and chirality does exactly that the moment it lands.
static int sPadProvisional[SOHSENSE_HANDS];
static int sAuthState = 0; // 0 not asked or pending, 1 allowed, -1 denied
static bool sAuthAsked = false;
static int sLoadOK = 0, sLoadFail = 0, sLoadFailCode = 0;
static int sLastAnchorCount = 0;
static unsigned int sPollCount = 0, sUpdates = 0;
static int sStarted = 0;
static int sCtlSeen = 0, sSpatialSeen = 0, sDoffEvents = 0;

// R5 THREADING DISCIPLINE. Everything below this line is written on the MAIN
// QUEUE (GameController connect/disconnect notifications and the
// ar_accessory_load_from_device completion block all deliver there) and read on
// the VR LOOP THREAD (sohsense_rebuild_provider, sohsense_read_hardware,
// SohSense_Active, SohSense_Dump). The rest of this file publishes with the
// volatile / publish-`valid`-LAST discipline, which works for a scalar snapshot
// but CANNOT work for a variable-length LIST: a reader that samples
// sAccessoryCount and then walks sAccessory[] can be interrupted by
// sohsense_forget compacting the array under it, and the read is then of a
// released ar_accessory_t or a dangling GCController*. R4 shipped that race
// (unobserved, because the simulator has no accessories to disconnect); R5
// closes it with a lock rather than pretending a counter is a barrier.
//
// os_unfair_lock, not a mutex: the critical sections are an array copy of at
// most SOHSENSE_MAX_ACCESSORIES entries with no allocation and no ObjC message
// sends, and os_unfair_lock donates the caller's priority to the holder, which
// is exactly the property a compositor-thread reader needs from a main-queue
// writer. Nothing that can block is ever done under it: the provider is BUILT
// from a snapshot taken under the lock and released, never while holding it.
static os_unfair_lock sListLock = OS_UNFAIR_LOCK_INIT;

// Haptic state; see the haptics section near the bottom of this file.
static CHHapticEngine* sHaptic[SOHSENSE_HANDS];
static volatile unsigned int sHapticRequests = 0;
static volatile unsigned int sHapticPlayed = 0;


API_AVAILABLE(visionos(26.0))
static ar_accessory_t sAccessory[SOHSENSE_MAX_ACCESSORIES];
static GCController* sAccessoryDevice[SOHSENSE_MAX_ACCESSORIES];
static int sAccessoryCount = 0;
API_AVAILABLE(visionos(26.0))
static ar_accessory_tracking_provider_t sProvider = NULL;
API_AVAILABLE(visionos(26.0))
static ar_session_t sSession = NULL;
static volatile bool sProviderDirty = false;
static GCController* sPending[SOHSENSE_MAX_ACCESSORIES];
static int sPendingCount = 0;

// ---------------------------------------------------------------------------
// Tunables.
// ---------------------------------------------------------------------------
static struct {
    float velSource;  // 0 = runtime when available else derived, 1 = force runtime, 2 = force derived
    float velCutoff;  // one-euro minimum cutoff, Hz
    float velBeta;    // one-euro speed coefficient
    float velDCutoff; // one-euro derivative cutoff, Hz
    // R9 part A: 1 = publish the GRIP coordinate space (anchor x
    // anchorFromGrip), 0 = publish the raw anchor, which is what every build
    // before R9 did. The A/B for the roll orbit.
    float gripSpace;
} sT = {
    .velSource = 0.0f,
    .gripSpace = 1.0f,
    // One-euro defaults. The filter's own paper recommends starting from
    // mincutoff 1.0 / beta 0.0 and raising beta until lag is acceptable; these
    // are that starting point moved once toward responsiveness, because the
    // consumer is a 5 m/s THRESHOLD and lag on the rising edge of a swing is
    // a late attack. UNTUNED IN A HEADSET -- every one is a `vr set` key.
    .velCutoff = 2.0f,
    .velBeta = 0.35f,
    .velDCutoff = 1.0f,
};

// ---------------------------------------------------------------------------
// Small math helpers (simd is available here; SohVrPhys.c deliberately has no
// such luxury and hand-rolls its own).
// ---------------------------------------------------------------------------

static simd_float3 sohsense_pos(simd_float4x4 m) {
    return m.columns[3].xyz;
}

static simd_quatf sohsense_rot(simd_float4x4 m) {
    // simd_quaternion(float4x4) wants a pure rotation; the anchor transform is
    // rigid, but normalize the basis anyway so a hair of numerical drift in the
    // matrix cannot become a non-unit quaternion the physics then integrates.
    simd_float3x3 r;
    r.columns[0] = simd_normalize(m.columns[0].xyz);
    r.columns[1] = simd_normalize(m.columns[1].xyz);
    r.columns[2] = simd_normalize(m.columns[2].xyz);
    return simd_normalize(simd_quaternion(r));
}

// The angular velocity that carries `a` to `b` over `dt`. This is DONOR-MAP
// §8e's "we'd need to add quaternion differencing" in three lines: the log map
// of the relative rotation, over dt. Hemisphere-corrected, because q and -q are
// the same rotation and the raw difference of two poses either side of the
// boundary is a 2*pi spike exactly where a fast swing lives.
static simd_float3 sohsense_ang_vel(simd_quatf a, simd_quatf b, float dt) {
    if (!(dt > 1e-5f)) {
        return simd_make_float3(0, 0, 0);
    }
    simd_quatf d = simd_mul(b, simd_inverse(a));
    float w = simd_real(d);
    simd_float3 v = simd_imag(d);
    if (w < 0.0f) {
        w = -w;
        v = -v;
    }
    float len = simd_length(v);
    if (len < 1e-7f) {
        return simd_make_float3(0, 0, 0);
    }
    float angle = 2.0f * atan2f(len, w);
    return v * (angle / (len * dt));
}

// One-euro filter, one per scalar channel. Chosen over a plain EMA because the
// input is a velocity whose useful range spans two orders of magnitude: an EMA
// smooth enough to kill jitter at rest lags a 5 m/s swing edge by tens of
// milliseconds, and a late attack is exactly the failure a player feels. The
// one-euro filter's whole point is that its cutoff RISES with speed.
typedef struct {
    float xPrev, dxPrev;
    int primed;
} SohEuro;

static float sohsense_lowpass(float x, float xPrev, float alpha) {
    return alpha * x + (1.0f - alpha) * xPrev;
}

static float sohsense_alpha(float cutoffHz, float dt) {
    float tau = 1.0f / (2.0f * (float)M_PI * cutoffHz);
    return 1.0f / (1.0f + tau / dt);
}

static float sohsense_euro(SohEuro* f, float x, float dt) {
    if (!(dt > 1e-5f)) {
        return f->primed ? f->xPrev : x;
    }
    if (!f->primed) {
        f->primed = 1;
        f->xPrev = x;
        f->dxPrev = 0.0f;
        return x;
    }
    float dx = (x - f->xPrev) / dt;
    float dxHat = sohsense_lowpass(dx, f->dxPrev, sohsense_alpha(sT.velDCutoff, dt));
    f->dxPrev = dxHat;
    float cutoff = sT.velCutoff + sT.velBeta * fabsf(dxHat);
    float xHat = sohsense_lowpass(x, f->xPrev, sohsense_alpha(cutoff, dt));
    f->xPrev = xHat;
    return xHat;
}

static SohEuro sVelFilter[SOHSENSE_HANDS][3], sAngFilter[SOHSENSE_HANDS][3];

static void sohsense_reset_filters(int hand) {
    for (int i = 0; i < 3; i++) {
        sVelFilter[hand][i].primed = 0;
        sAngFilter[hand][i].primed = 0;
    }
}

static simd_float3 sohsense_filter3(SohEuro f[3], simd_float3 v, float dt) {
    return simd_make_float3(sohsense_euro(&f[0], v.x, dt), sohsense_euro(&f[1], v.y, dt),
                            sohsense_euro(&f[2], v.z, dt));
}

// ---------------------------------------------------------------------------
// Authorization + accessory load. Order is load-bearing; see SohSense.h.
// ---------------------------------------------------------------------------

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device_retry(GCController* c, int attempt);

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device(GCController* c) {
    sohsense_load_device_retry(c, 0);
}

API_AVAILABLE(visionos(26.0))
static void sohsense_load_device_retry(GCController* c, int attempt) {
    if (c == nil) {
        return;
    }
    {
        bool known = false;
        os_unfair_lock_lock(&sListLock);
        for (int i = 0; i < sAccessoryCount; i++) {
            if (sAccessoryDevice[i] == c) {
                known = true;
                break;
            }
        }
        os_unfair_lock_unlock(&sListLock);
        if (known) {
            return; // already loaded
        }
    }
    ar_accessory_load_from_device(
        c, ^(id<GCDevice> device, bool successful, ar_error_t error, ar_accessory_t accessory) {
            (void)device;
            if (!successful || accessory == NULL) {
                sLoadFail++;
                long code = -1;
                if (error != NULL) {
                    code = (long)ar_error_get_error_code(error);
                }
                sLoadFailCode = (int)code;
                // Code 1200 with an aggregated MFi presentation means the
                // GCSupportedGameControllers/SpatialGamepad declaration did not
                // reach the built product -- NOT that the hardware is
                // untrackable. Two device rounds were lost to that read.
                NSLog(@"[sense] accessory load FAILED for '%@' (category '%@') code=%ld attempt=%d", c.vendorName,
                      c.productCategory, code, attempt);
                if (attempt == 0) {
                    // ONE retry: accessory tracking is gated on the app being
                    // focused, so a load issued during immersive-space entry can
                    // fail for that alone. Both results are logged, so the retry
                    // can never hide the first answer.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       if (@available(visionOS 26.0, *)) {
                                           sohsense_load_device_retry(c, 1);
                                       }
                                   });
                }
                return;
            }
            ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
            int known = 0;
            os_unfair_lock_lock(&sListLock);
            if (sAccessoryCount < SOHSENSE_MAX_ACCESSORIES) {
                sAccessory[sAccessoryCount] = accessory;
                sAccessoryDevice[sAccessoryCount] = c;
                sAccessoryCount++;
                sProviderDirty = true;
                // Chirality is available HERE, before any provider runs, and it
                // is the only authority: GameController has no chirality API.
                if (ch == ar_accessory_chirality_left || ch == ar_accessory_chirality_right) {
                    // R10 verdict 5: CHIRALITY WINS over a provisional slot,
                    // and it has to undo one carefully -- this controller may
                    // be sitting in the wrong slot, and the slot it belongs in
                    // may be holding the other unit provisionally.
                    int sohWant = (ch == ar_accessory_chirality_left) ? SOHSENSE_LEFT : SOHSENSE_RIGHT;
                    int sohOther = sohWant ^ 1;
                    if ((sPad[sohOther] == c) && sPadProvisional[sohOther]) {
                        sPad[sohOther] = nil;
                        sPadProvisional[sohOther] = 0;
                    }
                    if ((sPad[sohWant] != nil) && (sPad[sohWant] != c) && sPadProvisional[sohWant]) {
                        if (sPad[sohOther] == nil) {
                            sPad[sohOther] = sPad[sohWant];
                            sPadProvisional[sohOther] = 1;
                        }
                        sPad[sohWant] = nil;
                    }
                    sPad[sohWant] = c;
                    sPadProvisional[sohWant] = 0;
                }
                known = sAccessoryCount;
            }
            os_unfair_lock_unlock(&sListLock);
            if (known == 0) {
                return;
            }
            sLoadOK++;
            NSLog(@"[sense] accessory LOADED '%s' chirality=%s from '%@' (%d known)", ar_accessory_get_name(accessory),
                  ch == ar_accessory_chirality_left    ? "left"
                  : ch == ar_accessory_chirality_right ? "right"
                                                       : "unspecified",
                  c.vendorName, known);
        });
}

API_AVAILABLE(visionos(26.0))
static void sohsense_request_authorization(void) {
    if (sAuthAsked) {
        return;
    }
    sAuthAsked = true;
    if (sSession == NULL) {
        sSession = ar_session_create();
    }
    NSLog(@"[sense] requesting accessory-tracking authorization");
    ar_session_request_authorization(
        sSession, ar_authorization_type_accessory_tracking, ^(ar_authorization_results_t results, ar_error_t error) {
            __block int state = -1;
            if (results != NULL) {
                ar_authorization_results_enumerate_results(results, ^bool(ar_authorization_result_t r) {
                    if (ar_authorization_result_get_authorization_type(r) == ar_authorization_type_accessory_tracking) {
                        state = (ar_authorization_result_get_status(r) == ar_authorization_status_allowed) ? 1 : -1;
                    }
                    return true;
                });
            }
            sAuthState = state;
            NSLog(@"[sense] accessory-tracking authorization: %s%@", state == 1 ? "ALLOWED" : "DENIED",
                  error ? @" (with error)" : @"");
            if (state != 1) {
                return;
            }
            for (int i = 0; i < sPendingCount; i++) {
                sohsense_load_device(sPending[i]);
            }
            sPendingCount = 0;
        });
}

static void sohsense_register_device(GCController* c) {
    if (c == nil) {
        return;
    }
    if (@available(visionOS 26.0, *)) {
        sohsense_request_authorization();
        if (sAuthState == 1) {
            sohsense_load_device(c);
            return;
        }
        if (sAuthState == -1) {
            return;
        }
        if (sPendingCount < SOHSENSE_MAX_ACCESSORIES) {
            sPending[sPendingCount++] = c;
        }
    }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

int SohSense_IsSpatialController(void* gcController) {
    GCController* c = (__bridge GCController*)gcController;
    if (c == nil) {
        return 0;
    }
    if (@available(visionOS 26.0, *)) {
        return [c.productCategory isEqualToString:GCProductCategorySpatialController] ? 1 : 0;
    }
    return 0;
}

static void sohsense_log_inventory(GCController* c) {
    NSLog(@"[sense] controller vendor='%@' category='%@'", c.vendorName, c.productCategory);
    NSLog(@"[sense]   buttons: %@", c.physicalInputProfile.buttons.allKeys);
    NSLog(@"[sense]   dpads:   %@", c.physicalInputProfile.dpads.allKeys);
    // Did the declaration survive CMake + Xcode plist processing into the built
    // product? One line closes that doubt permanently -- it is the difference
    // between "the pair is untrackable" and "we never asked".
    NSLog(@"[sense]   bundle GCSupportedGameControllers = %@",
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"]);
}

// --- R9 part B: THE SPATIAL NAME SET, and why it exists ---------------------
//
// the user, on 1.0.1.12: "The right joystick is STILL sometimes triggering C
// buttons! Stop this!" The cause is not in this file and not in any overlay we
// had: SDL's MFi joystick backend accepts ANY GCController carrying a
// physicalInputProfile (SDL_mfijoystick.m:488-492), so each Sense unit is ALSO
// an SDL game controller; LUS hands every gamepad to port 0; and SoH's default
// mapping binds RIGHTX/RIGHTY to the four C buttons at a 25% threshold. The
// Sense pair was therefore playing the game twice -- once through overlay
// 0047's taxonomy and once as an anonymous gamepad whose right stick is the
// C-pad.
//
// The fix is to take the pair OUT of the SDL enumeration (overlay 0052), which
// needs a predicate LUS can call from C++ with nothing but an SDL device index.
// The only identity SDL exposes there is the name, and on iOS/visionOS
// SDL_JoystickNameForIndex returns GCController.vendorName verbatim -- so this
// records the vendorName of every controller GameController itself calls a
// SPATIAL controller, and the exported predicate is an exact match against that
// set. The set is filled at adoption, i.e. before the game ever asks, because
// discovery starts at launch.
//
// The substring fallback exists for the one ordering we cannot rule out (a
// refresh that runs before any GCController connect notification has landed)
// and is deliberately conservative: two families, matched case-insensitively,
// and nothing that a real gamepad is plausibly called.
#define SOHSENSE_MAX_SPATIAL_NAMES 8
static NSString* sSpatialNames[SOHSENSE_MAX_SPATIAL_NAMES];
static int sSpatialNameCount = 0;
static os_unfair_lock sSpatialNameLock = OS_UNFAIR_LOCK_INIT;
static int sSpatialSkips = 0;

static void sohsense_remember_spatial_name(GCController* c) {
    NSString* n = c.vendorName;
    if (n.length == 0) {
        return;
    }
    os_unfair_lock_lock(&sSpatialNameLock);
    for (int i = 0; i < sSpatialNameCount; i++) {
        if ([sSpatialNames[i] isEqualToString:n]) {
            os_unfair_lock_unlock(&sSpatialNameLock);
            return;
        }
    }
    if (sSpatialNameCount < SOHSENSE_MAX_SPATIAL_NAMES) {
        sSpatialNames[sSpatialNameCount++] = [n copy];
    }
    os_unfair_lock_unlock(&sSpatialNameLock);
    NSLog(@"[sense] spatial name registered: '%@' (SDL will skip it)", n);
}

int SohSense_IsSpatialControllerName(const char* name) {
    if (name == NULL || name[0] == '\0') {
        return 0;
    }
    @autoreleasepool {
        NSString* n = [NSString stringWithUTF8String:name];
        if (n == nil) {
            return 0;
        }
        os_unfair_lock_lock(&sSpatialNameLock);
        for (int i = 0; i < sSpatialNameCount; i++) {
            if ([sSpatialNames[i] isEqualToString:n]) {
                os_unfair_lock_unlock(&sSpatialNameLock);
                return 1;
            }
        }
        os_unfair_lock_unlock(&sSpatialNameLock);
        // THE FALLBACK, and the suite caught the obvious way to get it wrong:
        // a SUBSTRING test for "Sense" matches "DualSense Wireless Controller",
        // which is an ordinary gamepad and one of the most common ones people
        // own. Excluding the whole pad because its name contains four letters
        // of another product's is a worse bug than the one being fixed.
        //
        // So the fallback is a TOKEN test: the name is split on non-alphanumerics
        // and a token must be exactly "Sense", "PSVR2" or "VR2". "DualSense" is
        // one token and is not "Sense"; "PS VR2 Sense Controller" has both.
        NSCharacterSet* sep = [NSCharacterSet alphanumericCharacterSet].invertedSet;
        for (NSString* tokRaw in [n componentsSeparatedByCharactersInSet:sep]) {
            NSString* tok = tokRaw.lowercaseString;
            if ([tok isEqualToString:@"sense"] || [tok isEqualToString:@"psvr2"] ||
                [tok isEqualToString:@"vr2"]) {
                return 1;
            }
        }
    }
    return 0;
}

// Overlay 0052 calls this once per skipped device so the count is readable from
// the console (`vr sdlpads`) rather than only from a log.
void SohSense_NoteSdlSpatialSkip(void) {
    sSpatialSkips++;
}

int SohSense_SdlSpatialSkips(void) {
    return sSpatialSkips;
}

int SohSense_SpatialNameCount(void) {
    return sSpatialNameCount;
}

static void sohsense_adopt(GCController* c) {
    if (c == nil) {
        return;
    }
    sCtlSeen++;
    sohsense_log_inventory(c);
    // Register EVERY controller: ar_accessory_load_from_device takes a GCDevice,
    // and hiding this behind the spatial gate is exactly the bug that meant the
    // sibling never once asked whether poses existed.
    sohsense_register_device(c);
    if (!SohSense_IsSpatialController((__bridge void*)c)) {
        NSLog(@"[sense] '%@' is not a spatial controller -- leaving it to the SDL path", c.productCategory);
        return;
    }
    // R9 part B: and it must NOT be left to the SDL path. See the block above.
    sohsense_remember_spatial_name(c);
    sSpatialSeen++;
    // R10 verdict 5: A PROVISIONAL HAND, so the pair can play the flat game
    // before (or without) chirality. See sPadProvisional.
    {
        int sohSlot = -1;
        os_unfair_lock_lock(&sListLock);
        if ((sPad[SOHSENSE_LEFT] != c) && (sPad[SOHSENSE_RIGHT] != c)) {
            if (sPad[SOHSENSE_LEFT] == nil) {
                sohSlot = SOHSENSE_LEFT;
            } else if (sPad[SOHSENSE_RIGHT] == nil) {
                sohSlot = SOHSENSE_RIGHT;
            }
            if (sohSlot >= 0) {
                sPad[sohSlot] = c;
                sPadProvisional[sohSlot] = 1;
            }
        }
        os_unfair_lock_unlock(&sListLock);
        if (sohSlot >= 0) {
            NSLog(@"[sense] '%@' provisionally the %s unit (connection order; chirality will override)",
                  c.vendorName, sohSlot == SOHSENSE_LEFT ? "LEFT" : "RIGHT");
        }
    }
}

static void sohsense_forget(GCController* c) {
    if (c == nil) {
        return;
    }
    for (int i = 0; i < sPendingCount; i++) {
        if (sPending[i] != c) {
            continue;
        }
        for (int j = i; j < sPendingCount - 1; j++) {
            sPending[j] = sPending[j + 1];
        }
        sPending[--sPendingCount] = nil;
        break;
    }
    int sohDropped[SOHSENSE_HANDS] = { 0, 0 };
    os_unfair_lock_lock(&sListLock);
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessoryDevice[i] != c) {
            continue;
        }
        for (int j = i; j < sAccessoryCount - 1; j++) {
            sAccessory[j] = sAccessory[j + 1];
            sAccessoryDevice[j] = sAccessoryDevice[j + 1];
        }
        sAccessoryCount--;
        sAccessory[sAccessoryCount] = NULL;
        sAccessoryDevice[sAccessoryCount] = nil;
        sProviderDirty = true;
        break;
    }
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (sPad[h] == c) {
            sPad[h] = nil;
            sPadProvisional[h] = 0;
            sohDropped[h] = 1;
        }
    }
    os_unfair_lock_unlock(&sListLock);
    // Logging OUTSIDE the lock: NSLog takes locks of its own and can block, and
    // the compositor thread may be spinning on this one.
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (sohDropped[h]) {
            NSLog(@"[sense] %s controller disconnected", h == SOHSENSE_LEFT ? "LEFT" : "RIGHT");
        }
    }
    // RELEASE EVERYTHING: a controller that vanishes mid-press must not leave a
    // button held, a hand frozen in mid-air, or -- the one that matters here --
    // a swing detector latched HOT with no hand to bring it back down.
    SohSense_InjectDoff();
}

// ---------------------------------------------------------------------------
// Provider + per-frame anchor poll
// ---------------------------------------------------------------------------

API_AVAILABLE(visionos(26.0))
static void sohsense_rebuild_provider(void) {
    sProvider = NULL;
    sHandValid[SOHSENSE_LEFT] = sHandValid[SOHSENSE_RIGHT] = 0;
    // SNAPSHOT under the lock, BUILD outside it. ar_accessories_create and
    // ar_session_run allocate and may block; holding a lock a main-queue
    // disconnect handler also wants across them is how a compositor frame
    // becomes a hitch. Clearing sProviderDirty is part of the snapshot: a
    // disconnect that lands after this point re-dirties it and we rebuild on
    // the next poll, which is correct and cheap.
    ar_accessory_t snap[SOHSENSE_MAX_ACCESSORIES];
    int snapCount = 0;
    os_unfair_lock_lock(&sListLock);
    sProviderDirty = false;
    for (int i = 0; i < sAccessoryCount; i++) {
        if (sAccessory[i] != NULL) {
            snap[snapCount++] = sAccessory[i];
        }
    }
    os_unfair_lock_unlock(&sListLock);
    if (snapCount == 0) {
        return;
    }
    ar_accessories_t set = ar_accessories_create();
    for (int i = 0; i < snapCount; i++) {
        ar_accessories_add_accessory(set, snap[i]);
    }
    ar_accessory_tracking_configuration_t cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);
    // The SAME session the authorization was granted on -- a fresh one is
    // unauthorized again -- and a DEDICATED session, not the VR loop's
    // world-tracking one: accessories load and disconnect asynchronously, and a
    // failure there must never disturb the tracking the whole mode depends on.
    if (sSession == NULL) {
        sSession = ar_session_create();
    }
    sProvider = ar_accessory_tracking_provider_create(cfg);
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(sProvider, NULL);
    ar_session_run(sSession, providers);
    NSLog(@"[sense] accessory tracking running with %d accessory(s)", snapCount);
}

// Fold one freshly-observed pose into the published state: derive both
// velocities from the previous pose, filter whichever provenance is in force,
// and publish `valid` LAST.
static void sohsense_commit_pose(int hand, simd_float4x4 xf, double now, int haveRuntime, simd_float3 rtVel,
                                 simd_float3 rtAng) {
    float dt = 0.0f;
    if (sHavePrev[hand] && sPrevTime[hand] > 0.0) {
        dt = (float)(now - sPrevTime[hand]);
    }
    // A poll gap longer than a few frames is a tracking dropout, not motion:
    // differencing across it manufactures a swing out of nothing. Drop the
    // history and the filter state rather than emit one.
    if (dt > 0.2f || dt < 0.0f) {
        sHavePrev[hand] = 0;
        dt = 0.0f;
        sohsense_reset_filters(hand);
    }
    if (dt > 1e-5f) {
        simd_float3 dp = sohsense_pos(xf) - sohsense_pos(sPrevWorld[hand]);
        sVelDerived[hand] = dp / dt;
        sAngVelDerived[hand] = sohsense_ang_vel(sohsense_rot(sPrevWorld[hand]), sohsense_rot(xf), dt);
    } else if (!sHavePrev[hand]) {
        sVelDerived[hand] = simd_make_float3(0, 0, 0);
        sAngVelDerived[hand] = simd_make_float3(0, 0, 0);
    }
    sHaveRuntimeVel[hand] = haveRuntime;
    if (haveRuntime) {
        sVelRuntime[hand] = rtVel;
        sAngVelRuntime[hand] = rtAng;
    }

    int useRuntime = haveRuntime;
    if (sT.velSource >= 1.5f) {
        useRuntime = 0; // forced derived
    } else if (sT.velSource >= 0.5f) {
        useRuntime = haveRuntime; // forced runtime (still nothing to force if absent)
    }
    simd_float3 v = useRuntime ? sVelRuntime[hand] : sVelDerived[hand];
    simd_float3 w = useRuntime ? sAngVelRuntime[hand] : sAngVelDerived[hand];
    if (sVelInjected[hand]) {
        v = sHandVel[hand]; // the harness owns it; do not re-filter a constant
    } else {
        v = sohsense_filter3(sVelFilter[hand], v, dt > 1e-5f ? dt : (1.0f / 90.0f));
    }
    if (sAngVelInjected[hand]) {
        w = sHandAngVel[hand];
    } else {
        w = sohsense_filter3(sAngFilter[hand], w, dt > 1e-5f ? dt : (1.0f / 90.0f));
    }

    sPrevWorld[hand] = xf;
    sPrevTime[hand] = now;
    sHavePrev[hand] = 1;
    sHandWorld[hand] = xf;
    if (!sVelInjected[hand]) {
        sHandVel[hand] = v;
    }
    if (!sAngVelInjected[hand]) {
        sHandAngVel[hand] = w;
    }
    sHandValid[hand] = 1; // published LAST
}

static int sohsense_is_identity(simd_float4x4 m) {
    return (simd_length(m.columns[3].xyz) < 1e-6f) &&
           (simd_length(m.columns[0].xyz - simd_make_float3(1, 0, 0)) < 1e-6f) &&
           (simd_length(m.columns[1].xyz - simd_make_float3(0, 1, 0)) < 1e-6f) &&
           (simd_length(m.columns[2].xyz - simd_make_float3(0, 0, 1)) < 1e-6f);
}

// R9 part A: anchor -> published pose. One function, used by BOTH the hardware
// poll and the injector, so a simulator assertion exercises the exact
// composition the headset runs (an injector that skipped it would make the
// grip fix untestable, which is how the R8 notes' "assert the thing that
// ships" rule reads here).
static simd_float4x4 sohsense_publish_pose(int hand, simd_float4x4 anchorXf) {
    if (sT.gripSpace == 0.0f || !sGripHave[hand]) {
        return anchorXf;
    }
    return simd_mul(anchorXf, sAnchorFromGrip[hand]);
}

API_AVAILABLE(visionos(26.0))
static void sohsense_capture_grip(int hand, ar_accessory_anchor_t anchor) {
    // The API returns a transform, not a status. An accessory that has no such
    // location returns the identity, which is also a legitimate answer for an
    // accessory whose grip IS its origin -- so try the specific name first and
    // fall back to the surface, and record which one answered rather than
    // pretending the difference does not exist.
    if (sGripSrc[hand] == 3) {
        return; // the harness owns it this session
    }
    simd_float4x4 g = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
        anchor, ar_accessory_location_name_grip, ar_transform_correction_rendered);
    int src = 1;
    if (sohsense_is_identity(g)) {
        simd_float4x4 gs = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
            anchor, ar_accessory_location_name_grip_surface, ar_transform_correction_rendered);
        if (!sohsense_is_identity(gs)) {
            g = gs;
            src = 2;
        } else {
            src = 0;
        }
    }
    sAnchorFromGrip[hand] = g;
    sGripSrc[hand] = src;
    sGripHave[hand] = 1;
    if (!sGripLogged[hand]) {
        sGripLogged[hand] = 1;
        simd_quatf q = sohsense_rot(g);
        simd_float3 qi = simd_imag(q);
        // THE line to copy out of a headset log: this is the Sense's grip
        // transform, the number nobody on this Mac can measure.
        NSLog(@"[sense] grip space %s src=%d anchorFromGrip pos=%.4f,%.4f,%.4f quat=%.4f,%.4f,%.4f,%.4f",
              hand == SOHSENSE_LEFT ? "L" : "R", src, g.columns[3].x, g.columns[3].y, g.columns[3].z, qi.x, qi.y,
              qi.z, simd_real(q));
    }
}

API_AVAILABLE(visionos(26.0))
static void sohsense_capture_aim(int hand, ar_accessory_anchor_t anchor) {
    if (sAimSrc[hand] == 3) {
        return; // the harness owns it this session
    }
    simd_float4x4 a = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
        anchor, ar_accessory_location_name_aim, ar_transform_correction_rendered);
    sAnchorFromAim[hand] = a;
    sAimSrc[hand] = sohsense_is_identity(a) ? 0 : 1;
    sAimHave[hand] = 1;
    if (!sAimLogged[hand]) {
        sAimLogged[hand] = 1;
        simd_quatf q = sohsense_rot(a);
        simd_float3 qi = simd_imag(q);
        // THE other line to copy out of a headset log: the Sense's aim
        // transform relative to its anchor.
        NSLog(@"[sense] aim space %s src=%d anchorFromAim pos=%.4f,%.4f,%.4f quat=%.4f,%.4f,%.4f,%.4f",
              hand == SOHSENSE_LEFT ? "L" : "R", sAimSrc[hand], a.columns[3].x, a.columns[3].y, a.columns[3].z,
              qi.x, qi.y, qi.z, simd_real(q));
    }
}

API_AVAILABLE(visionos(26.0))
static void sohsense_poll_anchors(void) {
    if (sProviderDirty) {
        sohsense_rebuild_provider();
    }
    if (sProvider == NULL) {
        return;
    }
    sPollCount++;
    ar_accessory_anchors_t anchors = ar_accessory_tracking_provider_get_latest_anchors(sProvider);
    if (anchors == NULL) {
        return;
    }
    sLastAnchorCount = (int)ar_accessory_anchors_get_count(anchors);
    double now = CACurrentMediaTime();
    __block int seenMask = 0;
    ar_accessory_anchors_enumerate_anchors(anchors, ^bool(ar_accessory_anchor_t anchor) {
        if (!ar_accessory_anchor_is_tracked(anchor)) {
            return true;
        }
        // held_chirality is "which hand is holding it NOW" and can be
        // unspecified (a controller resting on a table). Fall back to the
        // accessory's INHERENT chirality; never guess from position.
        ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality(anchor);
        int hand = -1;
        if (ch == ar_accessory_chirality_left) {
            hand = SOHSENSE_LEFT;
        } else if (ch == ar_accessory_chirality_right) {
            hand = SOHSENSE_RIGHT;
        } else {
            ar_accessory_t acc = ar_accessory_anchor_get_accessory(anchor);
            if (acc != NULL) {
                ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality(acc);
                if (inh == ar_accessory_chirality_left) {
                    hand = SOHSENSE_LEFT;
                } else if (inh == ar_accessory_chirality_right) {
                    hand = SOHSENSE_RIGHT;
                }
            }
        }
        if (hand < 0 || sHandInjected[hand]) {
            return true; // injection wins: the simulator asserts must be stable
        }
        simd_float4x4 axf = ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
        sAnchorWorld[hand] = axf;
        sohsense_capture_grip(hand, anchor);
        sohsense_capture_aim(hand, anchor);
        // R9 part A: the PUBLISHED pose is the GRIP space, not the anchor.
        simd_float4x4 xf = sohsense_publish_pose(hand, axf);
        // Both runtime velocities are documented as being in the accessory's
        // LOCAL frame; everything downstream works in the ARKit origin frame,
        // so rotate them by the ANCHOR's own rotation -- the anchor's, because
        // that is the frame the runtime measured them in, and the grip location
        // may carry a rotation of its own.
        simd_quatf q = sohsense_rot(axf);
        simd_float3 rtVel = simd_act(q, ar_accessory_anchor_get_velocity(anchor));
        simd_float3 rtAng = simd_act(q, ar_accessory_anchor_get_angular_velocity(anchor));
        sHandHeld[hand] = ar_accessory_anchor_is_held(anchor) ? 1 : 0;
        sohsense_commit_pose(hand, xf, now, 1, rtVel, rtAng);
        seenMask |= (1 << hand);
        return true;
    });
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (!(seenMask & (1 << h)) && !sHandInjected[h]) {
            sHandValid[h] = 0;
            sHavePrev[h] = 0;
            sohsense_reset_filters(h);
        }
    }
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

static bool sohsense_btn(GCController* c, NSString* name) {
    if (c == nil) {
        return false;
    }
    GCControllerButtonInput* b = c.physicalInputProfile.buttons[name];
    return b ? b.isPressed : false;
}

// Name-agnostic fallback so a naming surprise degrades instead of killing the
// pad. Guessing the plural `GCInputLeftTrigger` cost the sibling its Z button:
// GCInputTrigger is SINGULAR, one per hand device.
static bool sohsense_btn_like(GCController* c, NSString* needle) {
    if (c == nil) {
        return false;
    }
    for (NSString* k in c.physicalInputProfile.buttons.allKeys) {
        if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            GCControllerButtonInput* b = c.physicalInputProfile.buttons[k];
            if (b != nil && b.isPressed) {
                return true;
            }
        }
    }
    return false;
}

static GCControllerDirectionPad* sohsense_stick(GCController* c) {
    if (c == nil) {
        return nil;
    }
    GCPhysicalInputProfile* p = c.physicalInputProfile;
    GCControllerDirectionPad* d = p.dpads[GCInputThumbstick];
    if (d != nil) {
        return d;
    }
    for (NSString* k in p.dpads.allKeys) {
        return p.dpads[k];
    }
    return nil;
}

static void sohsense_read_hardware(void) {
    if (sBtnInjected) {
        return; // the harness owns the buttons this session
    }
    GCController* sohPads[SOHSENSE_HANDS];
    os_unfair_lock_lock(&sListLock);
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sohPads[h] = sPad[h];
    }
    os_unfair_lock_unlock(&sListLock);
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        GCController* c = sohPads[h];
        if (c == nil) {
            sHandBtn[h] = 0;
            sHandStickX[h] = sHandStickY[h] = 0.0f;
            continue;
        }
        uint32_t b = 0;
        if (sohsense_btn(c, GCInputButtonA)) {
            b |= SOHSENSE_BTN_PRIMARY;
        }
        if (sohsense_btn(c, GCInputButtonB)) {
            b |= SOHSENSE_BTN_SECONDARY;
        }
        if (sohsense_btn(c, GCInputTrigger) || sohsense_btn_like(c, @"Trigger")) {
            b |= SOHSENSE_BTN_TRIGGER;
        }
        if (sohsense_btn(c, GCInputGripButton) || sohsense_btn_like(c, @"Grip")) {
            b |= SOHSENSE_BTN_GRIP;
        }
        if (sohsense_btn(c, GCInputThumbstickButton)) {
            b |= SOHSENSE_BTN_THUMBCLICK;
        }
        if (sohsense_btn(c, GCInputButtonMenu)) {
            b |= SOHSENSE_BTN_MENU;
        }
        sHandBtn[h] = b;
        GCControllerDirectionPad* d = sohsense_stick(c);
        sHandStickX[h] = d ? d.xAxis.value : 0.0f;
        sHandStickY[h] = d ? d.yAxis.value : 0.0f;
    }
}

// ---------------------------------------------------------------------------
// Lifecycle + per-frame update
// ---------------------------------------------------------------------------

int SohSense_Active(void) {
    int havePad;
    os_unfair_lock_lock(&sListLock);
    havePad = (sPad[SOHSENSE_LEFT] != nil || sPad[SOHSENSE_RIGHT] != nil);
    os_unfair_lock_unlock(&sListLock);
    return (sHandValid[SOHSENSE_LEFT] || sHandValid[SOHSENSE_RIGHT] || havePad) ? 1 : 0;
}

void SohSense_Update(double presTime, simd_float4x4 originFromHead) {
    (void)presTime;
    if (!sStarted) {
        return;
    }
    sHeadWorld = originFromHead;
    sHaveHead = 1;
    sUpdates++;
    if (@available(visionOS 26.0, *)) {
        sohsense_poll_anchors();
    }
    sohsense_read_hardware();
    // Injected hands get their velocities derived here rather than in the poll,
    // because nothing calls the poll for them. Same code path, same filters --
    // that identity is what makes a headless swing assert mean something.
    double now = CACurrentMediaTime();
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (sHandInjected[h] && sHandValid[h]) {
            sohsense_commit_pose(h, sHandWorld[h], now, 0, simd_make_float3(0, 0, 0), simd_make_float3(0, 0, 0));
        }
    }
}

// R10 verdict 5: buttons and sticks only. No provider, no anchors, no head.
// the user, on 1.0.1.13: *"The VR controllers no longer work in 2D mode. Is there
// a way to allow it in 2D without messing up VR?"* -- overlay 0052 took the
// Sense pair out of SDL's gamepad enumeration (rightly: its right stick was
// playing the C buttons), and overlay 0047's merge, which is what replaced it,
// only ran in VR. Nothing was left to read them in the flat window. This is the
// read that fixes that; the merge's own gate is in overlay 0047.
void SohSense_UpdateFlat(void) {
    if (!sStarted) {
        // Discovery is what adopts the pair and installs the connect/disconnect
        // observers; it does not open an ARKit session (sohsense_poll_anchors
        // does, and nothing here calls it).
        SohSense_Start();
        return; // adoption is a main-queue hop; read on the next tick
    }
    sohsense_read_hardware();
}

void SohSense_Start(void) {
    if (sStarted) {
        return;
    }
    sStarted = 1;
    SohSense_InjectDoff(); // every latch starts clear on every VR entry
    dispatch_async(dispatch_get_main_queue(), ^{
        for (GCController* c in GCController.controllers) {
            sohsense_adopt(c);
        }
        static int observed = 0;
        if (!observed) {
            observed = 1;
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification* n) {
                                                            sohsense_adopt((GCController*)n.object);
                                                        }];
            [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                            object:nil
                                                             queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification* n) {
                                                            sohsense_forget((GCController*)n.object);
                                                        }];
        }
        NSLog(@"[sense] backend ready (%lu controller(s) present)", (unsigned long)GCController.controllers.count);
    });
}

void SohSense_Stop(void) {
    if (!sStarted) {
        return;
    }
    sStarted = 0;
    // Release everything, unconditionally and idempotently. A VR exit with a
    // trigger down must not leave that N64 bit asserted in the flat game.
    SohSense_InjectDoff();
    // R5: drop the haptic engines. Leaving a started CHHapticEngine alive
    // across a VR exit keeps the controller's motor subsystem powered for a
    // mode that is no longer running, and the next entry re-creates them
    // lazily on the first pulse anyway.
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        if (sHaptic[h] != nil) {
            [sHaptic[h] stopWithCompletionHandler:nil];
            sHaptic[h] = nil;
        }
    }
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

int SohSense_HandPose(int hand, simd_float4x4* out) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || !sHandValid[hand]) {
        return 0;
    }
    if (out != NULL) {
        *out = sHandWorld[hand];
    }
    return 1;
}

// R15: the AIM pose -- anchor x anchorFromAim, in the same ORIGIN frame as the
// hand pose. Returns 0 until the runtime has answered for this hand; the
// consumer falls back to the hand basis rather than aiming along a stale ray.
int SohSense_HandAimPose(int hand, simd_float4x4* out, int* outSrc) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || !sHandValid[hand] || !sAimHave[hand]) {
        return 0;
    }
    if (out != NULL) {
        *out = simd_mul(sAnchorWorld[hand], sAnchorFromAim[hand]);
    }
    if (outSrc != NULL) {
        *outSrc = sAimSrc[hand];
    }
    return 1;
}

// R15: the harness's aim transform (rotation as a quaternion, translation in
// metres), so a simulator assertion can exercise the ray path.
void SohSense_InjectAim(int hand, float x, float y, float z, float qx, float qy, float qz, float qw) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    simd_quatf q = simd_quaternion(qx, qy, qz, qw);
    if (simd_length(simd_make_float4(qx, qy, qz, qw)) < 1e-5f) {
        q = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
    } else {
        q = simd_normalize(q);
    }
    simd_float4x4 a = simd_matrix4x4(q);
    a.columns[3] = simd_make_float4(x, y, z, 1.0f);
    sAnchorFromAim[hand] = a;
    sAimHave[hand] = 1;
    sAimSrc[hand] = 3;
}

int SohSense_HandMotion(int hand, simd_float4x4* outPose, simd_float3* outVel, simd_float3* outAngVel) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || !sHandValid[hand]) {
        return 0;
    }
    if (outPose != NULL) {
        *outPose = sHandWorld[hand];
    }
    if (outVel != NULL) {
        *outVel = sHandVel[hand];
    }
    if (outAngVel != NULL) {
        *outAngVel = sHandAngVel[hand];
    }
    return 1;
}

unsigned int SohSense_HandButtons(int hand) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return 0;
    }
    return sHandBtn[hand];
}

void SohSense_HandStick(int hand, float* outX, float* outY) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    if (outX != NULL) {
        *outX = sHandStickX[hand];
    }
    if (outY != NULL) {
        *outY = sHandStickY[hand];
    }
}

// ---------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------

int SohSense_SetTunable(const char* key, float value) {
    if (key == NULL) {
        return 0;
    }
    if (strcmp(key, "gripspace") == 0) {
        sT.gripSpace = (value != 0.0f) ? 1.0f : 0.0f;
    } else if (strcmp(key, "velsource") == 0) {
        sT.velSource = value;
    } else if (strcmp(key, "velcutoff") == 0 && value > 0.01f && value < 200.0f) {
        sT.velCutoff = value;
    } else if (strcmp(key, "velbeta") == 0 && value >= 0.0f && value < 100.0f) {
        sT.velBeta = value;
    } else if (strcmp(key, "veldcutoff") == 0 && value > 0.01f && value < 200.0f) {
        sT.velDCutoff = value;
    } else {
        return 0;
    }
    return 1;
}

float SohSense_GetTunable(const char* key) {
    if (key == NULL) {
        return 0.0f;
    }
    if (strcmp(key, "gripspace") == 0) {
        return sT.gripSpace;
    }
    if (strcmp(key, "velsource") == 0) {
        return sT.velSource;
    }
    if (strcmp(key, "velcutoff") == 0) {
        return sT.velCutoff;
    }
    if (strcmp(key, "velbeta") == 0) {
        return sT.velBeta;
    }
    if (strcmp(key, "veldcutoff") == 0) {
        return sT.velDCutoff;
    }
    return 0.0f;
}

// ---------------------------------------------------------------------------
// Injection
// ---------------------------------------------------------------------------

void SohSense_InjectHand(int hand, float x, float y, float z, float qx, float qy, float qz, float qw) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    simd_quatf q = simd_quaternion(qx, qy, qz, qw);
    if (simd_length(simd_make_float4(qx, qy, qz, qw)) < 1e-5f) {
        q = simd_quaternion(0.0f, simd_make_float3(0, 1, 0));
    } else {
        q = simd_normalize(q);
    }
    simd_float4x4 m = simd_matrix4x4(q);
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    // R9 part A: the injector injects an ANCHOR pose and goes through the SAME
    // grip composition the hardware poll does. Injecting the published pose
    // directly would have left the one thing this round changes untested.
    sAnchorWorld[hand] = m;
    sHandWorld[hand] = sohsense_publish_pose(hand, m);
    sHandHeld[hand] = 1;
    sHandInjected[hand] = 1;
    sHandValid[hand] = 1; // published LAST
}

// R9 part A: give the harness the accessory's grip transform. There is no
// spatial hardware in the simulator, so without this the composition is the
// identity and an assertion about it would assert nothing. Translation only --
// the lever arm is what produces an orbit, and a rotation in the grip location
// changes the hand's ORIENTATION, which the calibration rotations already own.
void SohSense_InjectGrip(int hand, float x, float y, float z) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    simd_float4x4 g = matrix_identity_float4x4;
    g.columns[3] = simd_make_float4(x, y, z, 1.0f);
    sAnchorFromGrip[hand] = g;
    sGripHave[hand] = 1;
    sGripSrc[hand] = 3;
    // Re-publish immediately so a grip injected after a pose still takes.
    if (sHandInjected[hand]) {
        sHandWorld[hand] = sohsense_publish_pose(hand, sAnchorWorld[hand]);
    }
}

void SohSense_InjectHandEuler(int hand, float x, float y, float z, float yawDeg, float pitchDeg, float rollDeg) {
    float cy = cosf(yawDeg * (float)M_PI / 360.0f), sy = sinf(yawDeg * (float)M_PI / 360.0f);
    float cp = cosf(pitchDeg * (float)M_PI / 360.0f), sp = sinf(pitchDeg * (float)M_PI / 360.0f);
    float cr = cosf(rollDeg * (float)M_PI / 360.0f), sr = sinf(rollDeg * (float)M_PI / 360.0f);
    // Y (yaw) * X (pitch) * Z (roll), the same order the sibling's injector uses
    // so a trajectory script written against one reads the same in the other.
    // The half-angles are already folded into the cos/sin above (M_PI/360 rather
    // than M_PI/180), which is what a quaternion component wants.
    simd_quatf qy = simd_quaternion(0.0f, sy, 0.0f, cy);
    simd_quatf qp = simd_quaternion(sp, 0.0f, 0.0f, cp);
    simd_quatf qr = simd_quaternion(0.0f, 0.0f, sr, cr);
    simd_quatf q = simd_mul(qy, simd_mul(qp, qr));
    SohSense_InjectHand(hand, x, y, z, simd_imag(q).x, simd_imag(q).y, simd_imag(q).z, simd_real(q));
}

void SohSense_InjectVelocity(int hand, float vx, float vy, float vz) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sHandVel[hand] = simd_make_float3(vx, vy, vz);
    sVelInjected[hand] = 1;
}

void SohSense_InjectAngVelocity(int hand, float wx, float wy, float wz) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sHandAngVel[hand] = simd_make_float3(wx, wy, wz);
    sAngVelInjected[hand] = 1;
}

void SohSense_InjectButton(int hand, const char* name, int down) {
    if (hand < 0 || hand >= SOHSENSE_HANDS || name == NULL) {
        return;
    }
    uint32_t bit = 0;
    if (strcmp(name, "primary") == 0 || strcmp(name, "a") == 0) {
        bit = SOHSENSE_BTN_PRIMARY;
    } else if (strcmp(name, "secondary") == 0 || strcmp(name, "b") == 0) {
        bit = SOHSENSE_BTN_SECONDARY;
    } else if (strcmp(name, "trigger") == 0) {
        bit = SOHSENSE_BTN_TRIGGER;
    } else if (strcmp(name, "grip") == 0) {
        bit = SOHSENSE_BTN_GRIP;
    } else if (strcmp(name, "thumbclick") == 0 || strcmp(name, "stick") == 0) {
        bit = SOHSENSE_BTN_THUMBCLICK;
    } else if (strcmp(name, "menu") == 0) {
        bit = SOHSENSE_BTN_MENU;
    } else {
        return;
    }
    sBtnInjected = 1;
    if (down) {
        sHandBtn[hand] |= bit;
    } else {
        sHandBtn[hand] &= ~bit;
    }
}

void SohSense_InjectStick(int hand, float x, float y) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sBtnInjected = 1;
    sHandStickX[hand] = (x < -1.0f) ? -1.0f : (x > 1.0f ? 1.0f : x);
    sHandStickY[hand] = (y < -1.0f) ? -1.0f : (y > 1.0f ? 1.0f : y);
}

void SohSense_InjectClear(void) {
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sHandInjected[h] = 0;
        sVelInjected[h] = 0;
        sAngVelInjected[h] = 0;
        sHandValid[h] = 0;
        sHavePrev[h] = 0;
        sHandVel[h] = simd_make_float3(0, 0, 0);
        sHandAngVel[h] = simd_make_float3(0, 0, 0);
        sohsense_reset_filters(h);
        // R9: an injected grip transform is harness state and dies with it.
        if (sGripSrc[h] == 3) {
            sAnchorFromGrip[h] = matrix_identity_float4x4;
            sGripHave[h] = 0;
            sGripSrc[h] = 0;
        }
        if (sAimSrc[h] == 3) {
            sAnchorFromAim[h] = matrix_identity_float4x4;
            sAimHave[h] = 0;
            sAimSrc[h] = 0;
        }
    }
    sBtnInjected = 0;
}

void SohSense_InjectDoff(void) {
    for (int h = 0; h < SOHSENSE_HANDS; h++) {
        sHandBtn[h] = 0;
        sHandStickX[h] = sHandStickY[h] = 0.0f;
        sHandValid[h] = 0;
        sHandHeld[h] = 0;
        sHandInjected[h] = 0;
        sVelInjected[h] = 0;
        sAngVelInjected[h] = 0;
        sHavePrev[h] = 0;
        sHandVel[h] = simd_make_float3(0, 0, 0);
        sHandAngVel[h] = simd_make_float3(0, 0, 0);
        sohsense_reset_filters(h);
        // R9: an injected grip transform is harness state and dies with it.
        if (sGripSrc[h] == 3) {
            sAnchorFromGrip[h] = matrix_identity_float4x4;
            sGripHave[h] = 0;
            sGripSrc[h] = 0;
        }
        if (sAimSrc[h] == 3) {
            sAnchorFromAim[h] = matrix_identity_float4x4;
            sAimHave[h] = 0;
            sAimSrc[h] = 0;
        }
    }
    sBtnInjected = 0;
    sDoffEvents++;
}

// ---------------------------------------------------------------------------
// Haptics (VR R5)
// ---------------------------------------------------------------------------
//
// GCController exposes a CHHapticEngine per locality. We keep ONE engine per
// hand, created lazily and cached, because CHHapticEngine creation is not cheap
// and a hit lands on a frame we would rather not spend allocating. Engines are
// dropped in sohsense_forget's path via SohSense_Stop.
//
// Everything here is best-effort and silent: a controller with no haptics
// (every simulator run, and some third-party pads) must not log per hit, must
// not throw, and must not cost anything. What IS observable, always, is
// sHapticRequests -- what the game ASKED for. The suite asserts on that number
// and says so in its own output, because "a pulse was requested" is the only
// claim a simulator can honestly support.
static CHHapticEngine* sohsense_haptic_engine(int hand) {
    if (sHaptic[hand] != nil) {
        return sHaptic[hand];
    }
    GCController* c;
    os_unfair_lock_lock(&sListLock);
    c = sPad[hand];
    os_unfair_lock_unlock(&sListLock);
    if (c == nil || c.haptics == nil) {
        return nil;
    }
    // Handles-locality is the one a controller held in a hand actually has; the
    // default locality is the fallback for pads that do not split.
    CHHapticEngine* e = [c.haptics createEngineWithLocality:GCHapticsLocalityHandles];
    if (e == nil) {
        e = [c.haptics createEngineWithLocality:GCHapticsLocalityDefault];
    }
    if (e == nil) {
        return nil;
    }
    NSError* err = nil;
    [e startAndReturnError:&err];
    if (err != nil) {
        return nil;
    }
    // The engine is stopped by the system when the app resigns; restart rather
    // than leaving a dead engine cached, which is silent and permanent.
    __weak CHHapticEngine* weakE = e;
    e.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        (void)reason;
        (void)weakE;
    };
    e.resetHandler = ^{
        NSError* rerr = nil;
        [weakE startAndReturnError:&rerr];
    };
    sHaptic[hand] = e;
    return e;
}

void SohSense_Haptic(int hand, float intensity, float sharpness, float durationS) {
    if (hand < 0 || hand >= SOHSENSE_HANDS) {
        return;
    }
    sHapticRequests++;
    if (intensity < 0.0f) {
        intensity = 0.0f;
    } else if (intensity > 1.0f) {
        intensity = 1.0f;
    }
    if (sharpness < 0.0f) {
        sharpness = 0.0f;
    } else if (sharpness > 1.0f) {
        sharpness = 1.0f;
    }
    if (durationS < 0.005f) {
        durationS = 0.005f;
    } else if (durationS > 0.5f) {
        durationS = 0.5f;
    }
    CHHapticEngine* e = sohsense_haptic_engine(hand);
    if (e == nil) {
        return; // no hardware, no engine, no complaint
    }
    CHHapticEventParameter* pi = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                                              value:intensity];
    CHHapticEventParameter* ps = [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                                              value:sharpness];
    CHHapticEvent* ev = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                                      parameters:@[ pi, ps ]
                                                    relativeTime:0
                                                        duration:durationS];
    NSError* err = nil;
    CHHapticPattern* pat = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err];
    if (pat == nil || err != nil) {
        return;
    }
    id<CHHapticPatternPlayer> pl = [e createPlayerWithPattern:pat error:&err];
    if (pl == nil || err != nil) {
        return;
    }
    if ([pl startAtTime:0 error:&err]) {
        sHapticPlayed++;
    }
}

unsigned int SohSense_HapticCount(void) {
    return sHapticRequests;
}

// ---------------------------------------------------------------------------
// Dump
// ---------------------------------------------------------------------------

// A snapshot read of the two pad slots under the list lock (see the R5
// threading note above); both the state string and the accessory count in the
// dump are read on the VR loop thread while the main queue may be mutating them.
static int sohsense_have_pad(void) {
    int r;
    os_unfair_lock_lock(&sListLock);
    r = (sPad[SOHSENSE_LEFT] != nil || sPad[SOHSENSE_RIGHT] != nil);
    os_unfair_lock_unlock(&sListLock);
    return r;
}

const char* SohSense_Dump(void) {
    static char buf[1800];
    int sohAccCount;
    os_unfair_lock_lock(&sListLock);
    sohAccCount = sAccessoryCount;
    os_unfair_lock_unlock(&sListLock);
    const char* state = "absent";
    if (sHandValid[SOHSENSE_LEFT] || sHandValid[SOHSENSE_RIGHT]) {
        state = (sHandInjected[SOHSENSE_LEFT] || sHandInjected[SOHSENSE_RIGHT]) ? "injected" : "tracked";
    } else if (sohsense_have_pad()) {
        state = "paired";
    }
    int n = snprintf(buf, sizeof(buf),
                     "state=%s started=%d ctl_seen=%d spatial=%d auth=%d loads=%d fails=%d fail_code=%d "
                     "accessories=%d anchors=%d polls=%u updates=%u doffs=%d vel_src=%.0f "
                     "euro=[%.2f,%.2f,%.2f] haptic_req=%u haptic_played=%u "
                     "gripspace=%.0f grip_src=%d,%d prov=%d,%d",
                     state, sStarted, sCtlSeen, sSpatialSeen, sAuthState, sLoadOK, sLoadFail, sLoadFailCode,
                     sohAccCount, sLastAnchorCount, sPollCount, sUpdates, sDoffEvents, sT.velSource, sT.velCutoff,
                     sT.velBeta, sT.velDCutoff, sHapticRequests, sHapticPlayed, sT.gripSpace,
                     sGripSrc[SOHSENSE_LEFT], sGripSrc[SOHSENSE_RIGHT], sPadProvisional[SOHSENSE_LEFT],
                     sPadProvisional[SOHSENSE_RIGHT]);
    for (int h = 0; h < SOHSENSE_HANDS && n > 0 && n < (int)sizeof(buf); h++) {
        simd_float3 p = sohsense_pos(sHandWorld[h]);
        simd_quatf q = sohsense_rot(sHandWorld[h]);
        simd_float3 qi = simd_imag(q);
        n += snprintf(buf + n, sizeof(buf) - (size_t)n,
                      " | %s valid=%d held=%d inj=%d btn=0x%02x stick=%.2f,%.2f "
                      "pos=%.3f,%.3f,%.3f quat=%.3f,%.3f,%.3f,%.3f "
                      "vel=%.3f,%.3f,%.3f |v|=%.3f angvel=%.3f,%.3f,%.3f |w|=%.3f "
                      "rt=%d rtv=%.3f dvv=%.3f rtw=%.3f dvw=%.3f "
                      "anchor=%.3f,%.3f,%.3f gripoff=%.4f,%.4f,%.4f",
                      h == SOHSENSE_LEFT ? "L" : "R", sHandValid[h], sHandHeld[h], sHandInjected[h], sHandBtn[h],
                      sHandStickX[h], sHandStickY[h], p.x, p.y, p.z, qi.x, qi.y, qi.z, simd_real(q), sHandVel[h].x,
                      sHandVel[h].y, sHandVel[h].z, simd_length(sHandVel[h]), sHandAngVel[h].x, sHandAngVel[h].y,
                      sHandAngVel[h].z, simd_length(sHandAngVel[h]), sHaveRuntimeVel[h],
                      simd_length(sVelRuntime[h]), simd_length(sVelDerived[h]), simd_length(sAngVelRuntime[h]),
                      simd_length(sAngVelDerived[h]), sAnchorWorld[h].columns[3].x, sAnchorWorld[h].columns[3].y,
                      sAnchorWorld[h].columns[3].z, sAnchorFromGrip[h].columns[3].x,
                      sAnchorFromGrip[h].columns[3].y, sAnchorFromGrip[h].columns[3].z);
    }
    return buf;
}
