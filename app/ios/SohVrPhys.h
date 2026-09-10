// SohVrPhys.h — Layer 0 of the donor's motion combat (VR-DONOR-MAP §8),
// reduced to the self-contained part, run at HEADSET rate on the VR loop
// thread.
//
// PROVENANCE. The donor's layer 0 is `libultraship-vr/src/fast/vr_physics.cpp`
// (1703 lines). Two of its three halves are portable and are ported here:
//
//   - the SPRING-DAMPER hand->object model, including the decision that makes
//     the whole design work (the spring advances a TARGET pose driven by the
//     hand alone; the object then walks toward that target), the implicit
//     (backward) Euler integrator, and the DERIVED-never-integrated velocity
//     rule that means nothing in the model stores energy and so nothing rings;
//   - the SWING tier state machine and the visual weight lag.
//
//   - R5 adds the CONTACT SOLVER: the flat-rectangle blade collider (spine +
//     two edge segments + two corner segments over a tip taper), the
//     target/sim split walked in non-penetrating substeps, `pivotOnly`
//     resolution about the grip with the donor's lever let-through, the two
//     ghost-collision guards (deep-recognize and the convex-lip exemption via
//     triangle adjacency), passthrough with cut drag, and friction. It solves
//     against the GAME's own collision mesh, harvested by the game side at the
//     tick and handed here in TRACKING METRES -- the donor's
//     `gVrPhysVisualMesh=0` path, which DONOR-MAP §8 records as "a fully
//     self-contained fallback living entirely in VrSwing.cpp". The renderer's
//     visual-mesh harvest (DONOR-MAP §10) is still NOT ported and is not
//     wanted: the donor's own handoff calls the collision-mesh path the stable
//     one.
//
//   - NOT ported, deliberately, and listed in docs/VR-R5-NOTES.md: bone
//     capsules and limb puppetry. The donor's own comment (VrSwing.cpp:499-507)
//     settles it -- "Damage is unaffected either way" -- and with no puppet the
//     donor itself falls back to pushing enemies' AC colliders as solid prims,
//     which is the pre-M3 behaviour it shipped for months.
//
// INTERFACE VERSION. The donor's `VR_PhysGetInterfaceVersion()==14` handshake
// exists because its game side and its LUS fork are separate repos that can
// drift. Ours is the same idea over the same seam (shell <-> overlay), but it
// is OUR interface, not the donor's, so it carries its OWN number and never
// claims 14 — a reduced port answering "14" would be a lie the game side would
// believe. The game side (overlay 0046) refuses to run unless the number it was
// compiled against is the number the shell reports.
//
// PORTABILITY. Like the donor's, this file is plain C with only <math.h> and
// <string.h>. No Metal, no CompositorServices, no GameController, no simd. That
// is what lets `scripts/vrphys-suite.sh` drive it from a host binary with no
// headset and no simulator (donor `tools/vrphys-suite/`, whose own trick is
// `#include "fast/vr_physics.cpp"`).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define SOHVRPHYS_INTERFACE_VERSION 1

// Hands, in the order everything uses: 0 = LEFT, 1 = RIGHT.
#define SOHVRPHYS_HAND_L 0
#define SOHVRPHYS_HAND_R 1

// Swing tiers (donor VrSwing.cpp:1118-1141).
#define SOHVRPHYS_TIER_IDLE 0
#define SOHVRPHYS_TIER_ARMED 1
#define SOHVRPHYS_TIER_HOT 2

// Contact-prim kinds, mirroring the donor's `PrimId(kind << 12 | detail)`
// tagging (VrSwing.cpp:142). Only WALL is produced in R5; the others exist so
// the id plumbing does not have to change when actor colliders are pushed.
#define SOHVRPHYS_PRIM_WALL 1
#define SOHVRPHYS_PRIM_HARD 2
#define SOHVRPHYS_PRIM_FLESH 3

// The solver's working set. The donor selects the nearest 32 triangles per
// step out of a 4096-entry harvest (vr_physics.cpp:340); ours is fed a
// pre-ranked set by the game side, so 32 IS the harvest.
#define SOHVRPHYS_MAX_TRI 32
#define SOHVRPHYS_MAX_CONTACTS 4
#define SOHVRPHYS_MAX_EVENTS 8

typedef struct {
    float x, y, z;
} SohV3;
typedef struct {
    float x, y, z, w;
} SohQ4;

// One hand's tracked state, in TRACKING space, metres and radians/second.
// `vel` and `angVel` are the FILTERED velocities — see SohSense.m for where
// they come from and why deriving them is the one piece of the donor's design
// with no free equivalent on this platform (DONOR-MAP §8e).
typedef struct {
    int valid;
    SohV3 pos;
    SohQ4 quat;
    SohV3 vel;
    SohV3 angVel;
} SohVrPhysHand;

// Contact-prim SHAPES (R6). The donor's `VrContactPrim` is a tagged union of
// exactly these three (VrSwing.cpp:664-855): the static scene and the dynapoly
// probe rays produce TRIANGLES, an actor's AC cylinder produces a CAPSULE, and
// each element of a JntSph collider produces a SPHERE.
#define SOHVRPHYS_SHAPE_TRI 0
#define SOHVRPHYS_SHAPE_CAPSULE 1
#define SOHVRPHYS_SHAPE_SPHERE 2

// One contact primitive, in TRACKING METRES. For a TRIANGLE, `a`/`b`/`c` are
// the verts and the winding gives the outward normal n = (b-a) x (c-a); for a
// CAPSULE, `a` and `b` are the two axis endpoints and `radius` is its radius;
// for a SPHERE, `a` is the centre and `radius` the radius. `id` is
// (kind << 12) | detail. The name is R5's and is kept so every call site and
// patch context stays put -- it is a prim, not only a triangle, since R6.
typedef struct {
    SohV3 a, b, c;
    int id;
    int shape;    /* SOHVRPHYS_SHAPE_* */
    float radius; /* capsule/sphere only; 0 for a triangle */
} SohVrPhysTri;

// A contact that BEGAN this step -- the donor's VRPHYS_EV_CONTACT_BEGIN
// (vr_physics.cpp:1281-1300). One per contact EPISODE per hand: `inContact` is
// a single flag, so a second surface touched while already in contact produces
// no new event. That is the donor's behaviour and it is what makes "one strike
// per swing" hold without a hit list.
typedef struct {
    unsigned int seq; // monotonic; the game side keeps its own last-seen value
    int hand;
    SohV3 pos;    // tracking metres
    SohV3 normal; // unit, pointing OUT of the surface toward the blade
    float impact; // m/s, the speed the target ran away from the sim pose at
    int id;       // the triangle's id (kind << 12 | detail)
} SohVrPhysEvent;

// What the game side reads back for one hand.
typedef struct {
    int tier;               // SOHVRPHYS_TIER_*
    float midSpeed;         // blade-midpoint speed, m/s (the tier input)
    float handSpeed;        // raw hand speed, m/s (the damage floor input)
    unsigned int swingSeq;  // bumps ONCE per rising edge into HOT
    float swingSpeed;       // midSpeed at that edge
    int swingJumpSlash;     // 1 if that edge was above the jump-slash speed
    SohV3 visPos;           // held-object pose WITH the visual weight lag
    SohQ4 visQuat;
    SohV3 simPos;           // the un-lagged sim pose (what damage would read)
    SohQ4 simQuat;
    // R5: the blade line the sim pose implies, tracking metres, and the one it
    // implied on the PREVIOUS step. The swept damage quad's four corners are
    // exactly these (donor RegisterQuad's vanilla vertex order: newBase,
    // newTip, prevBase, prevTip).
    SohV3 bladeBase, bladeTip;
    SohV3 prevBase, prevTip;
    int contactCount;       // contacts holding the blade back this step
    int passthrough;        // 1 while the blade is fast enough to pass through
    float bladeOffset;      // metres the sim pose is held back from the target
} SohVrPhysOut;

// Tunables, all live-settable from `vr set` (donor names in comments).
typedef struct {
    float posHz, posZeta;    // position spring (donor posSpringHz / zeta)
    float rotHz, rotZeta;    // orientation spring
    float bladeLenM;         // grip -> tip, metres (the midpoint lever is half)
    float tierArmed;         // 2.0 m/s
    float tierHot;           // 5.0 m/s
    float tierIdle;          // 0.8 m/s
    float handFloor;         // 1.2 m/s raw-hand damage floor
    float jumpSlash;         // 8.0 m/s -> the enemy table's column 1
    float visualLagS;        // 0.055 s
    float visualSnapHz;      // 9.0 Hz, zeta fixed at 0.55 (see .c)
    float sensitivity;       // 0.5 .. 2.0, divides every speed threshold
    float peakHoldS;         // 0.10 s speed peak hold — NOT the donor's; see .c
    // --- R5: the contact solver (donor vr_physics.cpp defaults) --------------
    int contactEnabled;      // donor gVrPhysBladeInertia, 1
    int pivotOnly;           // donor gVrPhysPivotOnly, 1
    float bladeRadiusM;      // donor kBladeRadiusM 0.012 m
    float touchTolM;         // donor kTouchToleranceM 0.008 m
    float bladeHalfWidthM;   // 0 => round capsule; donor gVrPhysBladeWidth
    float tipTaper;          // donor gVrPhysBladeTipTaper 0.2
    float friction;          // donor gVrPhysBladeFriction 0.5 (pivotOnly only)
    float passthroughMps;    // donor gVrPhysPassthroughSpeed 2.2
    float cutDrag;           // donor gVrPhysCutDragWorld/Flesh, both 0.73
} SohVrPhysCfg;

int SohVrPhys_GetInterfaceVersion(void);
void SohVrPhys_Reset(void);
SohVrPhysCfg* SohVrPhys_Cfg(void); // live, mutable, defaults already applied

// One step, at the runtime's display period. `dt` is clamped to [1/144, 1/45]
// s exactly as the donor does (vr_physics.cpp:476-480) — a hitched frame must
// not be integrated as a metre of hand travel.
// Hand the solver the collision triangles to solve against, in TRACKING
// METRES, already ranked and culled by the producer (the game side harvests
// them from OoT's own `colCtx.colHeader->polyList` at the tick; the shell
// converts game units to metres through the same seat the eyes use). Passing
// count 0 turns contact off for the next steps without changing any tunable --
// which is exactly what happens on a scene change, in a flat context, and
// whenever the game side has not run a tick yet.
void SohVrPhys_SetMesh(const SohVrPhysTri* tris, int count);

// Tell the solver a damage quad LANDED. The donor demotes HOT -> ARMED on the
// first quad that reports AT_HIT (VrSwing.cpp:1522-1530), which is what makes
// "one strike per swing" true with no hit list: to strike again the blade must
// re-cross the hit speed. The game side is the only thing that knows a quad
// landed, and it learns it a tick late, so this has to come back inward.
void SohVrPhys_NotifyHit(int hand);

void SohVrPhys_Step(float dt, const SohVrPhysHand hands[2]);

// Drain contact-begin events. Returns how many were written.
int SohVrPhys_DrainEvents(SohVrPhysEvent* out, int max);

// Read back one hand. Returns 0 and leaves `out` zeroed if that hand is not
// tracked.
int SohVrPhys_Get(int hand, SohVrPhysOut* out);

// Diagnostics: one flat key=value line per hand, for `vr hands`.
int SohVrPhys_Describe(int hand, char* buf, int cap);

#ifdef __cplusplus
}
#endif
