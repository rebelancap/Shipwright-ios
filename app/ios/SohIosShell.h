// SohIosShell — the iOS app-shell that grafts onto SDL's UIWindow.
// Lives in the Shipwright-ios repo (NOT vendor); added to the soh target by
// overlay 0012. LUS calls SohIos_OnWindowCreated after SDL_CreateWindow.
#ifndef SOH_IOS_SHELL_H
#define SOH_IOS_SHELL_H

#ifdef __cplusplus
extern "C" {
#endif

struct SDL_Window;

// Called (once) right after LUS creates its SDL window on iOS. Grafts the
// window onto the active UIWindowScene, forces landscape, and installs the
// on-screen touch-control overlay.
void SohIos_OnWindowCreated(struct SDL_Window* window);

// R10 verdict 5: read the Sense pair's BUTTONS AND STICKS outside VR and publish
// them into the gSohVRSense* words overlay 0047 merges from. Called once per pad
// read from overlay 0047 (game thread); a no-op while the VR compositor loop is
// running, and on every target that does not build SohSense.m.
void SohVR_SenseFlatPump(void);

#ifdef __cplusplus
}
#endif

#endif // SOH_IOS_SHELL_H
