// SohHostViewController.m — boots the SDL/SoH engine under the SwiftUI app
// entry (visionOS) and owns the 2D<->3D transition sequencing.
//
// Why SwiftUI at the top: an ImmersiveSpace (stereo rendering) can only be
// declared by a SwiftUI App. SDL2main's UIKit shim is therefore NOT linked on
// visionOS; this VC calls the engine's SDL_main once the SwiftUI window scene
// is live. SDL2 then creates its own UIWindow, the shell grafts it onto the
// active scene (SohIosShell.m — NSNotification-based, delegate-free), and
// everything downstream (display link, touch overlay, bridge) works exactly as
// on the SDL-main path. SoH's main() never returns (game loop); SDL pumps the
// UIKit runloop from PumpEvents each frame, so SwiftUI stays serviced — the
// same proven behavior as the old postFinishLaunch path.
//
// 2D->3D sequencing (order is load-bearing — guide §2.7):
//   enter: gSoh3DMode=1 FIRST (engine goes offscreen: renders the eye
//          framebuffers, never acquires the hidden window's drawable — that
//          acquire stalls forever), THEN open the immersive space.
//   exit:  stop the immersive render thread and WAIT for it (it must never
//          touch a layerRenderer SwiftUI is tearing down), THEN dismiss; only
//          Soh_Exit3DFinalize (after dismissal) puts the engine back onscreen.

#import "SohHostViewController.h"
#import "SohImmersive.h"
#import <AVFAudio/AVFAudio.h>

extern void SDL_SetMainReady(void);
extern int SDL_main(int argc, char* argv[]); // soh's main() (0004: main=SDL_main)
extern void Soh_SetImmersiveMode(bool on);   // SohVisionApp.swift (@_cdecl)

// Engine-visible 3D state lives in SohIosShell.m (compiled on iPhone too, so
// the Fast3D overlay's strong externs always resolve; mode stays 0 there).
extern volatile int gSoh3DMode;
// Diagnostics: drain-timer liveness + GCD main-queue drain proof (bridge `3d`).
volatile int gSoh3DDrainTicks = 0;
volatile int gSoh3DGcdProbe = 0;

int Soh_Get3DMode(void) {
    return gSoh3DMode;
}

// Engine -> compositor bridge globals also live in SohIosShell.m.
extern void* volatile gSoh3DEyeTexture[3];
extern void* volatile gSoh3DEyeDepthTexture[3];
extern volatile int gSoh3DEyeFrames[2];

// R1 depth handoff (VR-spec D2): the eye's DEPTH texture, published by 0031
// rev13 on the same GPU completion as its colour texture. Gated on the same
// per-eye rendered flag for the same reason — before the first draw it is
// undefined garbage, and undefined DEPTH reprojects the world into a smear.
void* Soh3D_GetEyeDepthMTLTexture(int eye) {
    if (eye < 1 || eye > 2) {
        return NULL;
    }
    return gSoh3DEyeFrames[eye - 1] > 0 ? gSoh3DEyeDepthTexture[eye - 1] : NULL;
}

void* Soh3D_GetEyeMTLTexture(int eye) {
    if (eye < 1 || eye > 2) {
        return NULL;
    }
    // Gate on the per-eye rendered flag: the texture is UNDEFINED garbage
    // until first drawn (guide §2.4).
    return gSoh3DEyeFrames[eye - 1] > 0 ? gSoh3DEyeTexture[eye - 1] : NULL;
}

int Soh3D_GetEyeFrames(int eye) {
    return (eye >= 1 && eye <= 2) ? gSoh3DEyeFrames[eye - 1] : 0;
}

static BOOL sohHostBooted = NO;

@implementation SohHostViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (sohHostBooted) {
        return;
    }
    sohHostBooted = YES;
    NSLog(@"[SohHost] window scene live — booting engine (SDL_main)");
    // Boot from a RUNLOOP TIMER, never dispatch_async: soh's main never
    // returns (the N64 graph loop runs on this thread), and a never-ending
    // GCD block would occupy the serial main queue forever — every later
    // main-queue block (all of SwiftUI/MainActor) would starve. A timer
    // callout leaves the queue free; the shell's drain timer services it
    // from inside the game loop.
    [NSTimer scheduledTimerWithTimeInterval:0
                                    repeats:NO
                                      block:^(NSTimer* t) {
                                          SDL_SetMainReady();
                                          static char arg0[] = "soh";
                                          static char* argv[] = { arg0, NULL };
                                          SDL_main(1, argv);
                                          NSLog(@"[SohHost] SDL_main returned (engine quit)");
                                      }];
}

@end

// --- parked 2D window + curtain ("Playing in 3D") --------------------------
static CGSize soh_pre3dSize = { 0, 0 }; // captured at entry START, guarded
static UIView* soh_curtain = nil;

static BOOL Soh_ViewTreeHasMetalLayer(UIView* v, int depth) {
    if (depth > 4) {
        return NO;
    }
    if ([v.layer isKindOfClass:NSClassFromString(@"CAMetalLayer")]) {
        return YES;
    }
    for (UIView* s in v.subviews) {
        if (Soh_ViewTreeHasMetalLayer(s, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

// The GAME window: SDL's UIWindow (hosts the CAMetalLayer view). The key
// window at ornament-tap time is the SwiftUI HOSTING window — curtains and
// geometry aimed at "key" hit the wrong window (device round 2 finding).
static UIWindow* Soh_KeyGameWindow(void) {
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        if (Soh_ViewTreeHasMetalLayer(w, 0)) {
            return w;
        }
    }
    for (UIWindow* w in UIApplication.sharedApplication.windows) {
        if (w.isKeyWindow) {
            return w;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

void Soh_RequestWindowSize(CGSize size) { // non-static: restore controller re-requests
    UIWindow* w = Soh_KeyGameWindow();
    UIWindowScene* scene = w.windowScene;
    if (scene == nil) {
        NSLog(@"[SohHost] geometry request skipped: no scene");
        return;
    }
    @try {
        UIWindowSceneGeometryPreferencesVision* prefs =
            [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:size];
        [scene requestGeometryUpdateWithPreferences:prefs
                                       errorHandler:^(NSError* e) {
                                           NSLog(@"[SohHost] geometry update failed: %@", e);
                                       }];
        NSLog(@"[SohHost] geometry request %.0fx%.0f", size.width, size.height);
    } @catch (NSException* ex) {
        NSLog(@"[SohHost] geometry request THREW: %@", ex);
    }
}

extern volatile int gSohVRMode;

static void Soh_SetCurtain(bool show) {
    UIWindow* w = Soh_KeyGameWindow();
    if (show) {
        if (soh_curtain != nil || w == nil) {
            return;
        }
        UIView* v = [[UIView alloc] initWithFrame:w.bounds];
        v.backgroundColor = UIColor.blackColor;
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UILabel* l = [[UILabel alloc] initWithFrame:v.bounds];
        l.text = gSohVRMode ? @"Playing in VR" : @"Playing in 3D";
        l.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
        l.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
        l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = v.autoresizingMask;
        [v addSubview:l];
        [w addSubview:v];
        soh_curtain = v;
    } else if (soh_curtain != nil) {
        [soh_curtain removeFromSuperview];
        soh_curtain = nil;
    }
}

void Soh_Enter3D(bool on) {
    // UIKit work below (curtain, geometry) — marshal any off-main caller.
    // The GCD main queue drains now (shell 60 Hz drain timer), so this is
    // reliable from any thread, including the console bridge.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ Soh_Enter3D(on); });
        return;
    }
    if (on) {
        if (gSoh3DMode) {
            return;
        }
        NSLog(@"[SohHost] entering 3D: engine offscreen, opening space");
        // D-041: the 3D menu is display-only, and there's no "Menu" button in
        // immersive anymore. If the 2D menu is open when we enter, close it now
        // — while still 2D-focused (before the space opens and steals SDL's
        // input focus), so the esc actually lands — so we never render a dead,
        // non-interactive menu on the panel.
        {
            extern int SohIos_IsMenuOpen(void);
            extern void SohIos_ToggleMenuKey(void);
            if (SohIos_IsMenuOpen()) {
                SohIos_ToggleMenuKey(); // gSoh3DMode still 0 -> esc -> closes it
            }
        }
        // Capture the pre-3D size at entry START, before anything moves, and
        // never re-capture an already-parked size (the "window stays tiny"
        // trap — guide §2.7).
        extern CGSize SohIos_RestorePendingTarget(void);
        extern void SohIos_RestoreCancel(void);
        CGSize pending = SohIos_RestorePendingTarget();
        SohIos_RestoreCancel(); // a live restore timer would fight the parking
        if (soh_pre3dSize.width < 1) {
            if (pending.width >= 1) {
                // Re-entered mid-restore: the scene is a half-restored
                // transient — the in-flight target IS the true pre-3D size.
                soh_pre3dSize = pending;
            } else {
                UIWindowScene* scene = Soh_KeyGameWindow().windowScene;
                soh_pre3dSize = scene ? scene.coordinateSpace.bounds.size : CGSizeZero;
            }
            NSLog(@"[SohHost] captured pre-3D size %.0fx%.0f", soh_pre3dSize.width, soh_pre3dSize.height);
        }
        gSoh3DMode = 1; // BEFORE the space opens (drawable-acquire stall trap)
        Soh_SetImmersiveMode(true);
        // Park AFTER entry settles (a resize animation racing the transition
        // wedged a sibling); curtain immediately — the frozen frame confuses.
        Soh_SetCurtain(true);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (gSoh3DMode) {
                               Soh_RequestWindowSize(CGSizeMake(480, 320));
                           }
                       });
    } else {
        if (!gSoh3DMode) {
            return;
        }
        NSLog(@"[SohHost] exiting 3D: stopping render thread first");
        gSoh3DStop = 1;
        gSohVRStop = 1; // whichever loop is live must leave the layerRenderer
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            // Wait for the loop to leave the layerRenderer (2 s timeout — it
            // paces at the compositor cadence, so this is normally <30 ms).
            for (int i = 0; i < 200 && (gSoh3DRunning || gSohVRRunning); i++) {
                usleep(10 * 1000);
            }
            if (gSoh3DRunning || gSohVRRunning) {
                NSLog(@"[SohHost] WARNING: render thread still running at dismiss");
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                Soh_SetImmersiveMode(false); // Swift dismisses, then finalizes
            });
        });
    }
}

// VR-spec D1 (round R0): entering VR reuses the SAME engine/window
// sequencing as the 3D panel (engine offscreen first, park + curtain after the
// transition settles) — only the immersive SPACE differs, and the Swift side
// picks it from gSohVRMode. Soh3D's space and its configuration are untouched.
//
// R1 (spec D9): the enhancement CVars VR overrides (VR-DONOR-MAP §5b) are
// stashed-then-overridden on the way in and given back on the way out, with the
// stash written to the config synchronously so a SIGKILL in VR cannot leave a
// user's flat game permanently altered (overlay 0040).
extern void SohIos_VRApplyEnhancementCVars(int on);
void Soh_EnterVR(bool on) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ Soh_EnterVR(on); });
        return;
    }
    if (on) {
        if (gSoh3DMode) {
            return; // already immersive (panel or VR) — exit first, D1's dismiss-then-open
        }
        SohIos_VRApplyEnhancementCVars(1); // BEFORE the mode flag: the engine
                                           // must never render one VR frame
                                           // with a pre-rendered 2D backdrop
        gSohVRMode = 1; // set BEFORE the space opens: Swift reads it to pick the id
    } else if (!gSohVRMode) {
        return; // spec D1's tri-state: leaving VR never touches the 3D panel
    }
    Soh_Enter3D(on);
    // gSohVRMode is cleared in Soh_Exit3DFinalize, after the space is dismissed.
}

// R2a: a room-mode change taken mid-session. The 3DSceneRender enhancement
// installs its hooks through RegisterShipInitFunc, so setting the CVar is not
// enough — ShipInit::Init has to re-run, which is what the overlay-0040 helper
// does. Restore-then-override rather than a partial poke: the stash stays the
// single description of "what the user's own settings were", and it is written
// synchronously at both ends (spec D9's crash-safe rule).
void SohVR_ReapplyRoomMode(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ SohVR_ReapplyRoomMode(); });
        return;
    }
    if (!gSohVRMode) {
        return; // nothing overridden outside VR
    }
    SohIos_VRApplyEnhancementCVars(0);
    SohIos_VRApplyEnhancementCVars(1);
}

// Live stereo tuning from the SwiftUI sheet: CVar-backed (the eye passes
// read these every pass), persisted with the rest of the config.
extern void CVarSetFloat(const char* name, float value);
extern void CVarSave(void);
void Soh3D_SetStereoParams(float depthFrac, float convBias) {
    // NOTE round-5 bug: this wrote the OLD CVar names (StereoSep/StereoConv)
    // while the adaptive engine reads StereoDepth/StereoConvBias — the Depth
    // slider was connected to nothing. Names now match the engine.
    CVarSetFloat("gSohIos.StereoDepth", depthFrac);
    CVarSetFloat("gSohIos.StereoConvBias", convBias);
    CVarSave();
}

void Soh_Exit3DFinalize(void) {
    // spec D9: IDEMPOTENT. Crown dismissal, the ornament and the console can
    // all reach here for the same exit, and running the restore controller
    // twice re-captures a parked window size as the "pre-3D" one — the historic
    // "window stays tiny" trap.
    if (!gSoh3DMode && !gSohVRMode) {
        NSLog(@"[SohHost] exit finalize ignored — already flat");
        return;
    }
    NSLog(@"[SohHost] %s exit finalized — engine back onscreen", gSohVRMode ? "VR" : "3D");
    int wasVR = gSohVRMode;
    gSoh3DMode = 0;
    gSohVRMode = 0; // VR-spec D1: cleared only after the space is dismissed
    if (wasVR) {
        // Give the user's own enhancement settings back, and write the config
        // SYNCHRONOUSLY — iOS swipe-kill is SIGKILL and the desktop
        // write-on-quit never runs ( / D9).
        SohIos_VRApplyEnhancementCVars(0);
        CVarSave();
    }
    Soh_SetCurtain(false);
    // Restore to the EXACT size captured before entering 3D (predecessor
    // ports' pattern) — the controller requests the geometry, waits for the
    // scene to land, adopts the view chain, and verifies the engine followed
    // (round 13: blind timed adopts left the engine rendering a stale larger
    // size, top-left cropped).
    extern void SohIos_RestoreWindowTo(CGSize target);
    SohIos_RestoreWindowTo(soh_pre3dSize);
    soh_pre3dSize = CGSizeMake(0, 0); // allow a fresh capture next entry
}

// Crown/system dismissal (loop saw layer invalidated): reconcile the shell +
// SwiftUI state so the ornament button and engine mode match reality.
void Soh3D_Immersive_Ended(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gSoh3DMode) {
            NSLog(@"[SohHost] immersive ended by system — reconciling to 2D");
            Soh_SetImmersiveMode(false);
        }
    });
}
