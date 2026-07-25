// SohHostViewController.h — boots the SDL/SoH engine under the SwiftUI app
// entry (visionOS only) and owns the 2D<->3D transition sequencing (D-030).
#pragma once

#import <UIKit/UIKit.h>

@interface SohHostViewController : UIViewController
@end

#ifdef __cplusplus
extern "C" {
#endif

// Enter/leave the stereoscopic 3D mode. Owns the engine-side sequencing;
// flips the SwiftUI state (Soh_SetImmersiveMode) that opens/dismisses the
// actual ImmersiveSpace.
void Soh_Enter3D(bool on);

// Called from SwiftUI after dismissImmersiveSpace completes — the authoritative
// back-to-2D trigger (the 2D window never deactivates under mixed immersion).
void Soh_Exit3DFinalize(void);

// True while 3D mode is active (engine offscreen, space open or opening).
int Soh_Get3DMode(void);

#ifdef __cplusplus
}
#endif
