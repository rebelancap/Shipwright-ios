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

#ifdef __cplusplus
}
#endif

#endif // SOH_IOS_SHELL_H
