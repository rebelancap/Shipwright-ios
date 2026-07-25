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
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/QuartzCore.h>
UIView* SohIos_FindMetalViewIn(UIView* v);
UIView* SohIos_FindMetalView(UIWindow* w);
void SohIos_GlueWindowToScene(UIWindow* w, UIWindowScene* scene);
void SohIos_ForceViewChainAdopt(void);
static UIWindow* SohIos_GameWindowWithMetal(UIView** outMv);
#if TARGET_OS_VISION
extern volatile float gSohIosVisionLongEdge;
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
void* volatile gSoh3DEyeTexture[2] = { NULL, NULL };
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
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <SDL.h>
#import <SDL_syswm.h>
#import "SohIosShell.h"

#include <arpa/inet.h>
#include <execinfo.h>
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
    void (^flush)(NSNotification*) = ^(NSNotification* note) { SohIos_FlushConfig("notif"); };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
    [NSNotificationCenter.defaultCenter addObserverForName:UISceneWillDeactivateNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:flush];
}

// Crash backtraces persisted to Documents/crash.txt — springboard sessions
// are otherwise invisible (predecessor pattern).
static void SohIos_CrashHandler(int sig) {
    void* frames[64];
    int n = backtrace(frames, 64);
    char path[1024];
    const char* home = getenv("HOME");
    snprintf(path, sizeof(path), "%s/Documents/crash.txt", home ? home : "/tmp");
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "signal %d\n", sig);
        backtrace_symbols_fd(frames, n, fd);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static void SohIos_InstallCrashHandler(void) {
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        signal(sigs[i], SohIos_CrashHandler);
    }
}

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
// Documents with sane protection/permissions. The in-engine
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
        // User-imported data gets NSFileProtectionNone + sane modes.
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
// Converts "needs hands" into "scriptable" for remote testing.
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
    [self fwd:@selector(applicationWillResignActive:)];
}
- (void)sceneDidEnterBackground:(UIScene*)scene {
    SohIos_FlushConfig("sceneDidEnterBackground");
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
// zero mechanical noise; we want zero effective deadzone). Precompensate:
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
    SDL_SetEventFilter(SohIos_EventFilter, NULL); // soh:// deep links
    UIWindow* window = SohIos_GetSDLWindow(sdlWindow);
    if (window == nil) {
        NSLog(@"[SohIosShell] no UIKit window for SDL window");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        SohIos_InstallSceneDelegate(); // soh:// URL delivery (scene-routed)
        SohIos_EnsureLandscape(window, 0);
        // Native ROM picker if there's nothing to play yet.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ [SohIosOnboarding maybePresentIn:window]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ SohIos_InstallOverlayWhenReady(window, 0); });
    });
}
