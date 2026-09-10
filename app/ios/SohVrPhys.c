// SohVrPhys.c — layer 0 of the donor's motion combat, reduced. See SohVrPhys.h
// for the provenance and for what is deliberately NOT ported (the contact
// solver). Plain C99, <math.h>/<string.h>/<stdio.h> only, so the offline suite
// can `#include` this file from a host binary with no headset — the donor plays
// the same trick (`tools/vrphys-suite/vrphys_suite.cpp` includes
// `fast/vr_physics.cpp`).

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "SohVrPhys.h"

// ---------------------------------------------------------------------------
// Constants that are NOT tunables. Each one is a donor number; changing any of
// them changes feel in a way the donor's users already rejected.
// ---------------------------------------------------------------------------

static const float kTwoPi = 6.28318530717958647692f;

// donor vr_physics.cpp:716-740 — angular acceleration ceiling on the spring.
static const float kMaxAngAccel = 3000.0f;

// donor vr_physics.cpp default `max_accel_mps2`. The donor's own note reads DO
// NOT RAISE: above this the spring turns a tracking sample into jitter.
static const float kMaxLinAccel = 400.0f;

// donor vr_physics.cpp:1240-1269 — the weight-lag spring is deliberately
// UNDERDAMPED. The overshoot is the wiggle; a critically damped lag just makes
// the sword feel late instead of heavy.
static const float kVisZeta = 0.55f;

// donor vr_physics.cpp:1240-1269 — cap on the lag offset, radians.
static const float kVisOffCap = 0.4f;

// donor vr_physics.cpp:476-480 — a hitched frame must not integrate as a metre
// of hand travel.
static const float kDtMin = 1.0f / 144.0f;
static const float kDtMax = 1.0f / 45.0f;

// The blade axis convention: the blade extends along the hand's -Z (grip
// forward), so the midpoint sits at (0, 0, -bladeLenM * 0.5) in hand space.
// This sign is the one number the first headset session is most likely to want
// changed; it is isolated here for that reason.
static const float kBladeAxisZ = -0.5f;

// ---------------------------------------------------------------------------
// Vector / quaternion helpers. Hand-rolled because this file may not include
// <simd/simd.h> — the donor hand-rolls its own V3/Q4 for the same reason.
// ---------------------------------------------------------------------------

static SohV3 v3(float x, float y, float z) {
    SohV3 r;
    r.x = x;
    r.y = y;
    r.z = z;
    return r;
}

static SohV3 v3add(SohV3 a, SohV3 b) {
    return v3(a.x + b.x, a.y + b.y, a.z + b.z);
}

static SohV3 v3sub(SohV3 a, SohV3 b) {
    return v3(a.x - b.x, a.y - b.y, a.z - b.z);
}

static SohV3 v3scale(SohV3 a, float s) {
    return v3(a.x * s, a.y * s, a.z * s);
}

static float v3dot(SohV3 a, SohV3 b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

static SohV3 v3cross(SohV3 a, SohV3 b) {
    return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

static float v3len(SohV3 a) {
    return sqrtf(v3dot(a, a));
}

static SohQ4 q4(float x, float y, float z, float w) {
    SohQ4 r;
    r.x = x;
    r.y = y;
    r.z = z;
    r.w = w;
    return r;
}

static SohQ4 q4identity(void) {
    return q4(0.0f, 0.0f, 0.0f, 1.0f);
}

static SohQ4 q4mul(SohQ4 a, SohQ4 b) {
    return q4(a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
              a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z);
}

static SohQ4 q4conj(SohQ4 a) {
    return q4(-a.x, -a.y, -a.z, a.w);
}

static SohQ4 q4normalize(SohQ4 a) {
    float n = sqrtf(a.x * a.x + a.y * a.y + a.z * a.z + a.w * a.w);
    if (!(n > 1e-12f)) {
        return q4identity();
    }
    n = 1.0f / n;
    return q4(a.x * n, a.y * n, a.z * n, a.w * n);
}

// v' = v + 2 * qv x (qv x v + w*v)
static SohV3 q4rotate(SohQ4 q, SohV3 v) {
    SohV3 qv = v3(q.x, q.y, q.z);
    SohV3 t = v3add(v3cross(qv, v), v3scale(v, q.w));
    return v3add(v, v3scale(v3cross(qv, t), 2.0f));
}

// Scaled-axis rotation error, donor vr_physics.cpp `q_error_vec`: d = target x
// conj(q), hemisphere-corrected so the shortest path is always taken, then
// axis/|axis| * (2*atan2(|axis|, d.w)). Returns a rotation VECTOR (rad).
static SohV3 q4errorVec(SohQ4 target, SohQ4 q) {
    SohQ4 d = q4mul(target, q4conj(q));
    if (d.w < 0.0f) {
        d = q4(-d.x, -d.y, -d.z, -d.w);
    }
    SohV3 axis = v3(d.x, d.y, d.z);
    float len = v3len(axis);
    if (len < 1e-8f) {
        return v3(0.0f, 0.0f, 0.0f);
    }
    float angle = 2.0f * atan2f(len, d.w);
    return v3scale(axis, angle / len);
}

// Exponential map: a rotation vector (rad) to the quaternion applying it.
static SohQ4 q4fromRotVec(SohV3 r) {
    float a = v3len(r);
    if (a < 1e-8f) {
        return q4identity();
    }
    float h = 0.5f * a;
    float s = sinf(h) / a;
    return q4(r.x * s, r.y * s, r.z * s, cosf(h));
}

// Clamp a per-step velocity delta to an acceleration ceiling.
static SohV3 clampAccel(SohV3 oldVel, SohV3 newVel, float maxAccel, float dt) {
    if (!(maxAccel > 0.0f)) {
        return newVel;
    }
    SohV3 dv = v3sub(newVel, oldVel);
    float lim = maxAccel * dt;
    float m = v3len(dv);
    if (m > lim && m > 1e-12f) {
        return v3add(oldVel, v3scale(dv, lim / m));
    }
    return newVel;
}

// The donor's implicit (backward) Euler spring, vr_physics.cpp:716-740, applied
// to one 3-vector. Backward Euler is what makes this unconditionally stable at
// the 30 Hz frequencies the orientation spring runs at.
static void springStep(SohV3* pos, SohV3* vel, SohV3 targetPos, SohV3 targetVel, float freqHz, float zeta,
                       float maxAccel, float dt) {
    float f = (freqHz > 0.1f) ? freqHz : 0.1f; // donor: max(lin_freq_hz, 0.1)
    float wl = kTwoPi * f;
    float k = wl * wl;
    float c = 2.0f * zeta * wl;
    float denom = 1.0f + dt * c + dt * dt * k;

    SohV3 num = v3add(*vel, v3add(v3scale(v3sub(targetPos, *pos), dt * k), v3scale(targetVel, dt * c)));
    SohV3 nv = v3scale(num, 1.0f / denom);
    nv = clampAccel(*vel, nv, maxAccel, dt);

    *vel = nv;
    *pos = v3add(*pos, v3scale(nv, dt));
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

typedef struct {
    int active;

    SohV3 pos; // sprung sim pose (the un-lagged pose every threshold reads)
    SohQ4 quat;

    SohV3 prevPos; // for the DERIVED-never-integrated velocity rule
    SohQ4 prevQuat;
    SohV3 linVel;
    SohV3 angVel;

    SohV3 visOff; // weight-lag offset, a rotation vector, and its spring state
    SohV3 visOffVel;

    float midSpeed; // held peaks (see the peak-hold note in stepHand)
    float handSpeed;
    float midInst; // this step's raw values, diagnostics only
    float handInst;
    float midAge;
    float handAge;

    int tier;
    unsigned int swingSeq;
    float swingSpeed;
    int swingJumpSlash;

    // --- R5: the target/sim split ------------------------------------------
    // `tgtPos`/`tgtQuat` is the spring's output, driven by the HAND alone and
    // never touched by a contact (donor :701-714). `pos`/`quat` above is the
    // SIM pose: it walks toward the target in non-penetrating substeps, and it
    // is what the hand matrix, the blade line and every damage quad read. When
    // nothing is in the way the two are identical, which is why R4's numbers
    // still hold with the solver switched on.
    SohV3 tgtPos;
    SohQ4 tgtQuat;
    SohV3 tgtVel; // the spring integrator's OWN state (donor sl.tgt_vel_mps)
    SohV3 tgtAng;

    int passthrough;
    int inContact;
    int contactCount;
    SohV3 contactPts[SOHVRPHYS_MAX_CONTACTS];
    SohV3 contactNs[SOHVRPHYS_MAX_CONTACTS];
    float contactPens[SOHVRPHYS_MAX_CONTACTS];
    int contactIds[SOHVRPHYS_MAX_CONTACTS];

    SohV3 bladeBase, bladeTip;
    SohV3 prevBase, prevTip;
    int haveBlade;
    float bladeOffset;

    // Set by SohVrPhys_NotifyHit when a damage quad LANDED, consumed on the
    // next step to demote HOT -> ARMED (donor VrSwing.cpp:1522-1530).
    int hitAck;
} SohVrPhysState;

static SohVrPhysState gState[2];
static SohVrPhysCfg gCfg;
static int gCfgInit = 0;

static void applyDefaults(SohVrPhysCfg* c) {
    memset(c, 0, sizeof(*c));
    c->posHz = 14.0f;  // donor Sword1HFreq
    c->posZeta = 1.0f; // critically damped: the position spring must not ring
    c->rotHz = 30.0f;  // donor SwordAngFreq
    c->rotZeta = 1.0f;
    // donor's Master Sword blade is 35 GAME UNITS and the spec's world scale
    // is 35 units/metre, so 35/35 = 1.0 m.
    c->bladeLenM = 1.0f;
    c->tierArmed = 2.0f;   // donor VrSwing.cpp:1119-1142, m/s
    c->tierHot = 5.0f;     // donor, m/s — this tier is the damaging one
    c->tierIdle = 0.8f;    // donor, m/s
    c->handFloor = 1.2f;   // donor, m/s raw-hand floor; gates HOT only
    c->jumpSlash = 8.0f;   // donor, m/s -> the enemy damage table's column 1
    c->visualLagS = 0.0f;  // donor ships WeightLagMs 0: machinery on, effect off
    c->visualSnapHz = 2.0f; // donor WeightSnapHz
    c->sensitivity = 1.0f;
    c->peakHoldS = 0.10f;
    // --- R5 contact solver, the donor's shipped defaults -------------------
    c->contactEnabled = 1;   // donor gVrPhysBladeInertia 1
    c->pivotOnly = 1;        // donor gVrPhysPivotOnly 1
    c->bladeRadiusM = 0.012f; // donor kBladeRadiusM
    c->touchTolM = 0.008f;   // donor kTouchToleranceM
    // donor gVrPhysBladeWidth 4.0 game units FULL width -> half-width 2.0
    // units, and at the spec's 35 units/m that is 0.057 m.
    c->bladeHalfWidthM = 0.057f;
    c->tipTaper = 0.2f;      // donor gVrPhysBladeTipTaper
    c->friction = 0.5f;      // donor gVrPhysBladeFriction (pivotOnly only)
    c->passthroughMps = 2.2f; // donor gVrPhysPassthroughSpeed
    c->cutDrag = 0.73f;      // donor gVrPhysCutDragWorld
}

static SohVrPhysCfg* cfg(void) {
    if (!gCfgInit) {
        applyDefaults(&gCfg);
        gCfgInit = 1;
    }
    return &gCfg;
}

int SohVrPhys_GetInterfaceVersion(void) {
    return SOHVRPHYS_INTERFACE_VERSION;
}

SohVrPhysCfg* SohVrPhys_Cfg(void) {
    return cfg();
}

void SohVrPhys_Reset(void) {
    memset(gState, 0, sizeof(gState));
    applyDefaults(&gCfg);
    gCfgInit = 1;
}

void SohVrPhys_NotifyHit(int hand) {
    if (hand < 0 || hand > 1) {
        return;
    }
    gState[hand].hitAck = 1;
}

// ---------------------------------------------------------------------------
// R5: THE CONTACT SOLVER (donor vr_physics.cpp, the ~900 lines R4 left out).
//
// The design decision that makes the whole thing work, and the one to keep in
// mind reading everything below (donor :701-714): THE SPRING DOES NOT MOVE THE
// OBJECT. It advances a TARGET pose driven by the hand alone that never sees a
// contact; the object then WALKS toward that target in non-penetrating
// substeps. An impulse solver preceded it in the donor and was abandoned as
// unfixable -- "the spring and contacts are adversaries".
//
// Everything here operates in TRACKING METRES. The mesh is handed in already
// converted (SohImmersive.m puts the game's harvested collision polys through
// the same seat the eyes use), so nothing in this file knows about game units,
// world scale, or Link.
// ---------------------------------------------------------------------------

// donor kDeepRecognizeM :278 -- how far behind a one-sided face still counts as
// "inside the solid". Capped so the FAR side of a thin wall cannot push the
// blade back through the near side.
static const float kDeepRecognizeM = 0.35f;

// donor kCorrectionCapM :281 -- max positional correction per contact per
// relaxation iteration.
static const float kCorrectionCapM = 0.15f;

// donor kLipGuardM :286 -- how close to a triangle's boundary edge a
// behind-plane contact must be before the convex-lip exemption is even
// considered. Inside the face, a behind-plane contact is solid, always.
static const float kLipGuardM = 0.06f;

// donor :949 -- point samples along each blade segment. Five, plus the interior
// crossing test, plus three segment-vs-edge tests.
#define SOH_SAMPLES 5

// donor :1089 / :1092 -- at most four contacts recorded per step, deduped by
// normal.
static const float kContactDedupDot = 0.98f;

static SohVrPhysTri gTris[SOHVRPHYS_MAX_TRI];
static int gTriCount = 0;

static SohVrPhysEvent gEvents[SOHVRPHYS_MAX_EVENTS];
static int gEventCount = 0;
static unsigned int gEventSeq = 0;

void SohVrPhys_SetMesh(const SohVrPhysTri* tris, int count) {
    if (count < 0) {
        count = 0;
    } else if (count > SOHVRPHYS_MAX_TRI) {
        count = SOHVRPHYS_MAX_TRI;
    }
    if (tris != NULL && count > 0) {
        memcpy(gTris, tris, sizeof(SohVrPhysTri) * (size_t)count);
    }
    gTriCount = count;
}

int SohVrPhys_DrainEvents(SohVrPhysEvent* out, int max) {
    int n = gEventCount;
    if (n > max) {
        n = max;
    }
    if (out != NULL && n > 0) {
        memcpy(out, gEvents, sizeof(SohVrPhysEvent) * (size_t)n);
    }
    gEventCount = 0;
    return n;
}

static void pushEvent(int hand, SohV3 pos, SohV3 n, float impact, int id) {
    gEventSeq++;
    if (gEventCount >= SOHVRPHYS_MAX_EVENTS) {
        return; // the seq still advanced: a dropped event is visible as a gap
    }
    SohVrPhysEvent* e = &gEvents[gEventCount++];
    e->seq = gEventSeq;
    e->hand = hand;
    e->pos = pos;
    e->normal = n;
    e->impact = impact;
    e->id = id;
}

// --- small geometry helpers (donor vr_physics.cpp:13-236 equivalents) -------

static SohV3 closestOnSeg(SohV3 p, SohV3 a, SohV3 b) {
    SohV3 ab = v3sub(b, a);
    float d = v3dot(ab, ab);
    if (d < 1e-12f) {
        return a;
    }
    float t = v3dot(v3sub(p, a), ab) / d;
    if (t < 0.0f) {
        t = 0.0f;
    } else if (t > 1.0f) {
        t = 1.0f;
    }
    return v3add(a, v3scale(ab, t));
}

// Closest pair between two segments. Writes the point on segment 1.
static void closestSegSeg(SohV3 p1, SohV3 q1, SohV3 p2, SohV3 q2, SohV3* out1, SohV3* out2) {
    SohV3 d1 = v3sub(q1, p1), d2 = v3sub(q2, p2), r = v3sub(p1, p2);
    float a = v3dot(d1, d1), e = v3dot(d2, d2), f = v3dot(d2, r);
    float s = 0.0f, t = 0.0f;
    if (a < 1e-12f && e < 1e-12f) {
        *out1 = p1;
        *out2 = p2;
        return;
    }
    if (a < 1e-12f) {
        t = f / e;
    } else {
        float c = v3dot(d1, r);
        if (e < 1e-12f) {
            s = -c / a;
        } else {
            float b = v3dot(d1, d2);
            float denom = a * e - b * b;
            s = (denom > 1e-12f) ? ((b * f - c * e) / denom) : 0.0f;
            if (s < 0.0f) {
                s = 0.0f;
            } else if (s > 1.0f) {
                s = 1.0f;
            }
            t = (b * s + f) / e;
        }
    }
    if (t < 0.0f) {
        t = 0.0f;
    } else if (t > 1.0f) {
        t = 1.0f;
    }
    if (a > 1e-12f) {
        s = (v3dot(d1, v3add(v3scale(d2, t), v3sub(p2, p1)))) / a;
        if (s < 0.0f) {
            s = 0.0f;
        } else if (s > 1.0f) {
            s = 1.0f;
        }
    }
    *out1 = v3add(p1, v3scale(d1, s));
    *out2 = v3add(p2, v3scale(d2, t));
}

static int pointInTri(SohV3 p, SohV3 a, SohV3 b, SohV3 c, SohV3 n) {
    SohV3 e0 = v3cross(v3sub(b, a), v3sub(p, a));
    SohV3 e1 = v3cross(v3sub(c, b), v3sub(p, b));
    SohV3 e2 = v3cross(v3sub(a, c), v3sub(p, c));
    return (v3dot(e0, n) >= 0.0f && v3dot(e1, n) >= 0.0f && v3dot(e2, n) >= 0.0f) ||
           (v3dot(e0, n) <= 0.0f && v3dot(e1, n) <= 0.0f && v3dot(e2, n) <= 0.0f);
}

static SohV3 closestOnTri(SohV3 p, SohV3 a, SohV3 b, SohV3 c, SohV3 n) {
    float sd = v3dot(v3sub(p, a), n);
    SohV3 proj = v3sub(p, v3scale(n, sd));
    if (pointInTri(proj, a, b, c, n)) {
        return proj;
    }
    SohV3 best = closestOnSeg(p, a, b);
    float bd = v3len(v3sub(p, best));
    SohV3 q = closestOnSeg(p, b, c);
    float d = v3len(v3sub(p, q));
    if (d < bd) {
        best = q;
        bd = d;
    }
    q = closestOnSeg(p, c, a);
    d = v3len(v3sub(p, q));
    if (d < bd) {
        best = q;
    }
    return best;
}

// donor same_vert :883 -- 1 mm vertex identity, no adjacency precomputation.
static int sameVert(SohV3 a, SohV3 b) {
    return v3len(v3sub(a, b)) < 1e-3f;
}

// donor find_shared_tri :884-900 -- the triangle sharing the edge (e0,e1) with
// `self`. Linear scan; with 32 triangles that is the right structure.
static int findSharedTri(int self, SohV3 e0, SohV3 e1) {
    for (int j = 0; j < gTriCount; j++) {
        if (j == self || gTris[j].shape != SOHVRPHYS_SHAPE_TRI) {
            continue; /* R6: a capsule has no verts to share an edge with */
        }
        SohV3 vv[3] = { gTris[j].a, gTris[j].b, gTris[j].c };
        int h0 = -1, h1 = -1;
        for (int k = 0; k < 3; k++) {
            if (sameVert(vv[k], e0)) {
                h0 = k;
            }
            if (sameVert(vv[k], e1)) {
                h1 = k;
            }
        }
        if (h0 >= 0 && h1 >= 0 && h0 != h1) {
            return j;
        }
    }
    return -1;
}

// donor convex_lip_exempt :906-934 -- THE hard-won guard, and the donor's own
// handoff says never remove it. A contact behind a face near one of its
// boundary EDGES, where the neighbouring face across that edge shows the probe
// point is OUTSIDE it, is the blade wrapping a convex lip (a ledge, a step, a
// doorframe) rather than being inside a solid. Ejecting it would fling the
// blade. No neighbour at all means SOLID -- never open a hole.
static int convexLipExempt(int self, SohV3 cpp, SohV3 probe, float guard) {
    SohV3 vv[3] = { gTris[self].a, gTris[self].b, gTris[self].c };
    float best = 1e9f;
    int be = -1;
    for (int e = 0; e < 3; e++) {
        SohV3 q = closestOnSeg(cpp, vv[e], vv[(e + 1) % 3]);
        float d = v3len(v3sub(cpp, q));
        if (d < best) {
            best = d;
            be = e;
        }
    }
    if (be < 0 || best > guard) {
        return 0; // face interior => solid
    }
    int nb = findSharedTri(self, vv[be], vv[(be + 1) % 3]);
    if (nb < 0) {
        return 0;
    }
    SohV3 qn = v3cross(v3sub(gTris[nb].b, gTris[nb].a), v3sub(gTris[nb].c, gTris[nb].a));
    float ql = v3len(qn);
    if (ql < 1e-9f) {
        return 0;
    }
    return v3dot(v3sub(probe, gTris[nb].a), v3scale(qn, 1.0f / ql)) > 1e-4f;
}

// One step's blade geometry, in WORLD (tracking) metres: the donor's flat
// rectangle as up to five capsule segments of radius `r` -- spine, two edges
// out to the taper point, two corners converging on the tip (donor :762-792).
// With zero half-width it degenerates to the single round capsule the donor
// ships by default for anything but a sword.
typedef struct {
    SohV3 root[5], tip[5];
    int n;
    float r;
    float len;
} SohVrBlade;

static void buildBlade(SohVrBlade* bl, SohV3 pos, SohQ4 q, const SohVrPhysCfg* c) {
    SohV3 rootL = v3(0.0f, 0.0f, 0.0f);
    SohV3 tipL = v3(0.0f, 0.0f, c->bladeLenM * (kBladeAxisZ * 2.0f));
    bl->r = (c->bladeRadiusM > 0.0f) ? c->bladeRadiusM : 0.012f;
    bl->len = v3len(v3sub(tipL, rootL));
    bl->n = 0;
    if (!(bl->len > 1e-4f)) {
        return;
    }
    SohV3 seg[5][2];
    int n = 0;
    seg[n][0] = rootL;
    seg[n][1] = tipL;
    n++;
    float hw = c->bladeHalfWidthM;
    if (hw > 1e-4f) {
        float taper = c->tipTaper;
        if (taper < 0.0f) {
            taper = 0.0f;
        } else if (taper > 1.0f) {
            taper = 1.0f;
        }
        SohV3 taperPt = v3add(rootL, v3scale(v3sub(tipL, rootL), 1.0f - taper));
        for (int e = 0; e < 2; e++) {
            SohV3 off = v3((e == 0) ? hw : -hw, 0.0f, 0.0f);
            seg[n][0] = v3add(rootL, off);
            seg[n][1] = v3add(taperPt, off);
            n++;
            if (taper > 0.01f && n < 5) {
                seg[n][0] = v3add(taperPt, off);
                seg[n][1] = tipL;
                n++;
            }
        }
    }
    for (int i = 0; i < n; i++) {
        bl->root[i] = v3add(pos, q4rotate(q, seg[i][0]));
        bl->tip[i] = v3add(pos, q4rotate(q, seg[i][1]));
    }
    bl->n = n;
}

// The relaxation pass. Returns 1 if anything moved. `record` is true only on
// the LAST substep -- recording on every substep would report contacts the
// blade has already been walked out of (donor :1087).
/* R6: the record-and-resolve tail of one contact, shared by the TRIANGLE loop
 * and the CAPSULE/SPHERE loop below. It is the donor's code unchanged, only
 * lifted out of the triangle loop so the actor prims can reach it -- the donor
 * reaches the same resolution for every prim type through its own tagged-union
 * loop (vr_physics.cpp:1100-1184). Returns 1 if the blade actually moved.
 * `sr`/`stp` are rebuilt in place because a resolution rotates the blade, and
 * the sample loop that called us keeps using them. */
static int applyContact(SohVrPhysState* st, const SohVrPhysCfg* c, SohVrBlade* bl, int si, SohV3* sr, SohV3* stp,
                        float inertia, float minLever, int record, int* outTouch, float pen, SohV3 n, SohV3 cp,
                        int id) {
    if (record && pen > -c->touchTolM) {
        if (outTouch != NULL) {
            (*outTouch)++;
        }
        int dup = 0;
        for (int k = 0; k < st->contactCount; k++) {
            if (v3dot(st->contactNs[k], n) > kContactDedupDot) {
                dup = 1;
                break;
            }
        }
        if (!dup && st->contactCount < SOHVRPHYS_MAX_CONTACTS) {
            st->contactPts[st->contactCount] = cp;
            st->contactNs[st->contactCount] = n;
            st->contactPens[st->contactCount] = pen;
            st->contactIds[st->contactCount] = id;
            st->contactCount++;
        }
    }
    if (pen <= 0.0f) {
        return 0; // touching, not penetrating: recorded, not corrected
    }

    SohV3 r = v3sub(cp, st->pos);
    SohV3 rxn = v3cross(r, n);
    float depth = (pen > kCorrectionCapM) ? kCorrectionCapM : pen;

    if (c->pivotOnly) {
        // donor :1126-1141. The grip is nailed to the hand: resolve by
        // ROTATING about it only, never by pushing the hand back. A contact
        // with no usable lever cannot be cleared by any rotation, so it is LET
        // THROUGH -- a dead-straight stab with your hand past a wall clips, by
        // design, rather than churning the blade.
        float den = v3dot(rxn, rxn);
        if (den < minLever * minLever) {
            /* LET THROUGH -- but still counted as "moved" so the relaxation
             * loop keeps iterating, exactly as R5's inline code did (the flag
             * was set ahead of this gate). */
            return 1;
        }
        SohV3 dth = v3scale(rxn, depth / den);
        float dl = v3len(dth);
        if (dl > 0.15f) {
            dth = v3scale(dth, 0.15f / dl);
        }
        st->quat = q4normalize(q4mul(q4fromRotVec(dth), st->quat));
    } else {
        float kn = 1.0f + v3dot(rxn, rxn) / inertia;
        float lambda = depth / kn;
        st->pos = v3add(st->pos, v3scale(n, lambda));
        SohV3 dth = v3scale(rxn, lambda / inertia);
        float dl = v3len(dth);
        if (dl > 0.2f) {
            dth = v3scale(dth, 0.2f / dl);
        }
        st->quat = q4normalize(q4mul(q4fromRotVec(dth), st->quat));
    }
    buildBlade(bl, st->pos, st->quat, c);
    *sr = bl->root[si];
    *stp = bl->tip[si];
    return 1;
}

static int depenetrate(SohVrPhysState* st, const SohVrPhysCfg* c, int iterations, int record, int* outTouch) {
    int movedAny = 0;
    if (record) {
        st->contactCount = 0;
    }
    for (int it = 0; it < iterations; it++) {
        int moved = 0;
        SohVrBlade bl;
        buildBlade(&bl, st->pos, st->quat, c);
        if (bl.n == 0) {
            return movedAny;
        }
        float inertia = bl.len * bl.len / 3.0f;
        if (inertia < 0.02f) {
            inertia = 0.02f;
        }
        float minLever = 0.15f * bl.len;
        for (int i = 0; i < gTriCount; i++) {
            if (gTris[i].shape != SOHVRPHYS_SHAPE_TRI) {
                continue; // R6: capsules and spheres are solved in their own loop below
            }
            SohV3 ta = gTris[i].a, tb = gTris[i].b, tc = gTris[i].c;
            SohV3 tnRaw = v3cross(v3sub(tb, ta), v3sub(tc, ta));
            float tnLen = v3len(tnRaw);
            if (tnLen < 1e-9f) {
                continue;
            }
            SohV3 tn = v3scale(tnRaw, 1.0f / tnLen);
            for (int si = 0; si < bl.n; si++) {
                SohV3 sr = bl.root[si], stp = bl.tip[si];
                if (v3len(v3sub(stp, sr)) < 1e-6f) {
                    continue;
                }
                for (int m = 0; m < SOH_SAMPLES + 4; m++) {
                    float pen = -1.0f;
                    SohV3 n = v3(0.0f, 0.0f, 0.0f);
                    SohV3 cp = v3(0.0f, 0.0f, 0.0f);
                    if (m < SOH_SAMPLES) {
                        float t = (float)m / (float)(SOH_SAMPLES - 1);
                        SohV3 p = v3add(sr, v3scale(v3sub(stp, sr), t));
                        float sd = v3dot(v3sub(p, ta), tn);
                        if (sd < 0.0f) {
                            // BEHIND the face. Three gates, in order, donor :974-988.
                            if (sd < -kDeepRecognizeM) {
                                continue; // another volume entirely
                            }
                            SohV3 proj = v3sub(p, v3scale(tn, sd));
                            if (!pointInTri(proj, ta, tb, tc, tn)) {
                                continue; // off the face
                            }
                            if (convexLipExempt(i, proj, p, kLipGuardM)) {
                                continue; // wrapping a convex lip
                            }
                            pen = bl.r - sd; // full ejection back to the front side
                            n = tn;
                            cp = proj;
                        } else {
                            SohV3 pt = closestOnTri(p, ta, tb, tc, tn);
                            SohV3 d = v3sub(p, pt);
                            float dist = v3len(d);
                            if (dist < 1e-6f) {
                                continue;
                            }
                            pen = bl.r - dist;
                            n = v3scale(d, 1.0f / dist);
                            cp = pt;
                        }
                    } else if (m == SOH_SAMPLES) {
                        // INTERIOR CROSSING, donor :1013-1038: the segment
                        // passes clean through the face between two samples.
                        // Without this a fast blade tunnels a thin wall.
                        float sd0 = v3dot(v3sub(sr, ta), tn);
                        float sd1 = v3dot(v3sub(stp, ta), tn);
                        if ((sd0 >= 0.0f) == (sd1 >= 0.0f)) {
                            continue;
                        }
                        float denom = sd0 - sd1;
                        if (denom > -1e-9f && denom < 1e-9f) {
                            continue;
                        }
                        SohV3 x = v3add(sr, v3scale(v3sub(stp, sr), sd0 / denom));
                        if (!pointInTri(x, ta, tb, tc, tn)) {
                            continue;
                        }
                        float side = (sd0 >= 0.0f) ? 1.0f : -1.0f;
                        SohV3 deepEnd = (side > 0.0f) ? stp : sr;
                        float deep = (side > 0.0f) ? -sd1 : sd1;
                        SohV3 projDeep = v3sub(deepEnd, v3scale(tn, v3dot(v3sub(deepEnd, ta), tn)));
                        if (!pointInTri(projDeep, ta, tb, tc, tn)) {
                            continue;
                        }
                        if (convexLipExempt(i, projDeep, deepEnd, 1e9f)) {
                            continue;
                        }
                        pen = bl.r + ((deep > 0.0f) ? deep : 0.0f);
                        n = v3scale(tn, side);
                        cp = x;
                    } else {
                        // SEGMENT-VS-EDGE, donor :1066-1084. The five point
                        // samples leave gaps a triangle edge slips between.
                        int e = m - SOH_SAMPLES - 1;
                        SohV3 ea = (e == 0) ? ta : (e == 1) ? tb : tc;
                        SohV3 eb = (e == 0) ? tb : (e == 1) ? tc : ta;
                        SohV3 p1, p2;
                        closestSegSeg(sr, stp, ea, eb, &p1, &p2);
                        SohV3 d = v3sub(p1, p2);
                        float dist = v3len(d);
                        if (dist < 1e-6f) {
                            continue;
                        }
                        pen = bl.r - dist;
                        n = v3scale(d, 1.0f / dist);
                        cp = p2;
                        // An edge normal with no component along the FACE
                        // normal would drag the blade through the face.
                        if (v3dot(n, tn) < 0.02f) {
                            continue;
                        }
                    }

                    if (applyContact(st, c, &bl, si, &sr, &stp, inertia, minLever, record, outTouch,
                                     pen, n, cp, gTris[i].id)) {
                        moved = 1;
                        movedAny = 1;
                    }
                }
            }
        }
        /* R6: CAPSULES AND SPHERES -- an enemy's AC cylinder, and every element
         * of a JntSph collider. The donor pushes exactly these two shapes when
         * no bone puppet exists (VrSwing.cpp:812-851), and we never have one.
         *
         * Convex and closed, so none of the triangle machinery applies: there
         * is no back face to be deeply behind, no convex lip to wrap, no thin
         * shell to tunnel. Closest point between the blade's own segment and
         * the prim's axis (a sphere is a zero-length axis) IS the contact, and
         * the outward normal falls straight out of it. That is why this loop is
         * a tenth the size of the one above and not a simplification of it. */
        for (int i = 0; i < gTriCount; i++) {
            int shape = gTris[i].shape;
            if (shape != SOHVRPHYS_SHAPE_CAPSULE && shape != SOHVRPHYS_SHAPE_SPHERE) {
                continue;
            }
            float pr = gTris[i].radius;
            if (!(pr > 0.0f)) {
                continue;
            }
            SohV3 pa = gTris[i].a;
            SohV3 pb = (shape == SOHVRPHYS_SHAPE_CAPSULE) ? gTris[i].b : pa;
            for (int si = 0; si < bl.n; si++) {
                SohV3 sr = bl.root[si], stp = bl.tip[si];
                if (v3len(v3sub(stp, sr)) < 1e-6f) {
                    continue;
                }
                SohV3 p1, p2;
                closestSegSeg(sr, stp, pa, pb, &p1, &p2);
                SohV3 d = v3sub(p1, p2);
                float dist = v3len(d);
                if (dist < 1e-6f) {
                    continue; /* blade axis dead through the axis: no usable
                               * direction. The next sub-step's motion resolves
                               * it, and inventing one here picks a random side. */
                }
                float pen = (bl.r + pr) - dist;
                if (pen <= -c->touchTolM) {
                    continue;
                }
                SohV3 n = v3scale(d, 1.0f / dist);
                SohV3 cp = v3add(p2, v3scale(n, pr)); /* on the prim's SURFACE */
                if (applyContact(st, c, &bl, si, &sr, &stp, inertia, minLever, record, outTouch, pen, n, cp,
                                 gTris[i].id)) {
                    moved = 1;
                    movedAny = 1;
                }
            }
        }
        if (!moved) {
            break;
        }
    }
    return movedAny;
}

// Friction, donor :1186-1233 -- and note the donor's own footgun, recorded in
// its source and preserved here: friction is silently pivotOnly-ONLY. The
// slide is measured from the TARGET's velocities (the hand's intent), never
// the blade's actual motion, because the latter feeds the friction rotation
// back into next step's slide and winds up.
static void applyFriction(SohVrPhysState* st, const SohVrPhysCfg* c, float dt) {
    if (!c->pivotOnly || !(c->friction > 0.0f) || st->contactCount == 0) {
        return;
    }
    SohVrBlade bl;
    buildBlade(&bl, st->pos, st->quat, c);
    if (bl.n == 0) {
        return;
    }
    float fric = c->friction;
    if (fric > 1.0f) {
        fric = 1.0f;
    }
    float minLever = 0.15f * bl.len;
    int dragged = 0;
    for (int k = 0; k < st->contactCount; k++) {
        if (st->contactPens[k] <= -c->touchTolM) {
            continue; // in the touch band, not pressing
        }
        SohV3 cp = st->contactPts[k];
        SohV3 n = st->contactNs[k];
        SohV3 r = v3sub(cp, st->pos);
        SohV3 vPt = v3add(st->tgtVel, v3cross(st->tgtAng, r));
        SohV3 disp = v3scale(vPt, dt);
        SohV3 slide = v3sub(disp, v3scale(n, v3dot(disp, n)));
        float mag = v3len(slide);
        if (mag < 1e-6f) {
            continue;
        }
        SohV3 t = v3scale(slide, 1.0f / mag);
        SohV3 lever = v3cross(r, t);
        float den = v3dot(lever, lever);
        if (den < minLever * minLever) {
            continue;
        }
        SohV3 dth = v3scale(lever, -fric * mag / den);
        float dl = v3len(dth);
        if (dl > 0.05f) {
            dth = v3scale(dth, 0.05f / dl);
        }
        st->quat = q4normalize(q4mul(q4fromRotVec(dth), st->quat));
        dragged = 1;
    }
    if (dragged) {
        depenetrate(st, c, 2, 0, NULL); // the drag may have re-pressed a surface
    }
}

// ---------------------------------------------------------------------------
// Step
// ---------------------------------------------------------------------------

// Peak hold. DEVIATION from the donor, recorded deliberately: the donor takes a
// per-tick MAXIMUM over the 24 tracking samples it collects between 20 Hz game
// ticks (VrSwing.cpp:1088-1105). We step once per headset frame and have no
// such sample path, so instead we hold each speed's peak for cfg->peakHoldS
// (0.10 s) — that is what stops a 20 Hz reader from stepping over a spike that
// occurred between two of its reads.
static float holdPeak(float cur, float* peak, float* age, float holdS, float dt) {
    if (cur >= *peak) {
        *peak = cur;
        *age = 0.0f;
    } else {
        *age += dt;
        if (*age >= holdS) {
            *peak = cur;
            *age = 0.0f;
        }
    }
    return *peak;
}

static void decayHand(SohVrPhysState* st) {
    st->active = 0;
    // Never leave a stale HOT tier behind a tracking loss: the game side would
    // read it as a live swing the moment the hand comes back.
    st->tier = SOHVRPHYS_TIER_IDLE;
    st->midSpeed = 0.0f;
    st->handSpeed = 0.0f;
    st->midInst = 0.0f;
    st->handInst = 0.0f;
    st->midAge = 0.0f;
    st->handAge = 0.0f;
    st->linVel = v3(0.0f, 0.0f, 0.0f);
    st->angVel = v3(0.0f, 0.0f, 0.0f);
    st->visOff = v3(0.0f, 0.0f, 0.0f);
    st->visOffVel = v3(0.0f, 0.0f, 0.0f);
    // R5: no hand means no blade. A stale contact set would otherwise let the
    // first frame after a re-acquire fire a contact-begin event from geometry
    // the blade was nowhere near.
    st->contactCount = 0;
    st->inContact = 0;
    st->passthrough = 0;
    st->haveBlade = 0;
    st->bladeOffset = 0.0f;
    st->hitAck = 0;
    st->tgtVel = v3(0.0f, 0.0f, 0.0f);
    st->tgtAng = v3(0.0f, 0.0f, 0.0f);
    // swingSeq is a monotonic counter and is NOT reset here; only
    // SohVrPhys_Reset clears it, so a dropout cannot replay an old edge.
}

static void stepHand(SohVrPhysState* st, const SohVrPhysHand* h, const SohVrPhysCfg* c, float dt) {
    if (!h->valid) {
        decayHand(st);
        return;
    }

    if (!st->active) {
        // Snap on acquisition: springing in from the origin would read as a
        // metres-per-second swing on the first frame.
        st->pos = h->pos;
        st->quat = q4normalize(h->quat);
        st->tgtPos = st->pos;
        st->tgtQuat = st->quat;
        st->tgtVel = v3(0.0f, 0.0f, 0.0f);
        st->tgtAng = v3(0.0f, 0.0f, 0.0f);
        st->contactCount = 0;
        st->inContact = 0;
        st->passthrough = 0;
        st->haveBlade = 0;
        st->bladeOffset = 0.0f;
        st->hitAck = 0;
        st->prevPos = st->pos;
        st->prevQuat = st->quat;
        st->linVel = v3(0.0f, 0.0f, 0.0f);
        st->angVel = v3(0.0f, 0.0f, 0.0f);
        st->visOff = v3(0.0f, 0.0f, 0.0f);
        st->visOffVel = v3(0.0f, 0.0f, 0.0f);
        st->tier = SOHVRPHYS_TIER_IDLE;
        st->midSpeed = 0.0f;
        st->handSpeed = 0.0f;
        st->active = 1;
    }

    SohQ4 handQ = q4normalize(h->quat);

    // ---- 1. THE TARGET. Sprung from the hand, blind to every contact -------
    // donor vr_physics.cpp:716-751. R4 sprang the pose the game reads directly;
    // R5 springs a TARGET and walks the sim toward it, which is the one
    // decision that lets a spring and a contact solver coexist.
    springStep(&st->tgtPos, &st->tgtVel, h->pos, h->vel, c->posHz, c->posZeta, kMaxLinAccel, dt);
    {
        float f = (c->rotHz > 0.1f) ? c->rotHz : 0.1f;
        float wl = kTwoPi * f;
        float k = wl * wl;
        float cc = 2.0f * c->rotZeta * wl;
        float denom = 1.0f + dt * cc + dt * dt * k;
        SohV3 err = q4errorVec(handQ, st->tgtQuat);
        SohV3 num = v3add(st->tgtAng, v3add(v3scale(err, dt * k), v3scale(h->angVel, dt * cc)));
        SohV3 nv = v3scale(num, 1.0f / denom);
        nv = clampAccel(st->tgtAng, nv, kMaxAngAccel, dt);
        st->tgtAng = nv;
        // The error is expressed in the parent frame, so the delta composes on
        // the LEFT.
        st->tgtQuat = q4normalize(q4mul(q4fromRotVec(v3scale(nv, dt)), st->tgtQuat));
    }

    // ---- 2. PASSTHROUGH, decided from the HAND, not the blade --------------
    // donor :804-820. The speed that decides whether a blade cuts through is
    // taken from the hand's own velocities at the blade midpoint, so a blade
    // already snagged on something cannot gate its own release. 70% hysteresis.
    {
        SohV3 midR = q4rotate(st->tgtQuat, v3(0.0f, 0.0f, c->bladeLenM * kBladeAxisZ));
        float sp = v3len(v3add(h->vel, v3cross(h->angVel, midR)));
        if (c->passthroughMps > 0.0f) {
            if (st->passthrough) {
                if (sp < c->passthroughMps * 0.7f) {
                    st->passthrough = 0;
                }
            } else if (sp > c->passthroughMps) {
                st->passthrough = 1;
            }
        } else {
            st->passthrough = 0;
        }
    }

    // ---- 3. THE WALK -------------------------------------------------------
    SohV3 prevSimPos = st->pos;
    SohQ4 prevSimQuat = st->quat;
    int nTouch = 0;
    int solving = (c->contactEnabled != 0) && (gTriCount > 0) && !st->passthrough;
    if (!solving) {
        // Not solving. While PASSING THROUGH, the blade is held back by cut
        // drag rather than stopped (donor :857-872): `retention` is the
        // fraction of the offset kept per 1/90 s, so the same feel holds at 72,
        // 90 and 120 Hz. Otherwise the sim IS the target.
        float drag = 0.0f;
        if (st->passthrough && (c->contactEnabled != 0) && gTriCount > 0 && c->cutDrag > 0.0f) {
            SohVrBlade bl;
            buildBlade(&bl, st->pos, st->quat, c);
            for (int i = 0; i < gTriCount && bl.n > 0; i++) {
                SohV3 ta = gTris[i].a, tb = gTris[i].b, tc = gTris[i].c;
                SohV3 tnRaw = v3cross(v3sub(tb, ta), v3sub(tc, ta));
                float tnLen = v3len(tnRaw);
                if (tnLen < 1e-9f) {
                    continue;
                }
                SohV3 tn = v3scale(tnRaw, 1.0f / tnLen);
                SohV3 pt = closestOnTri(bl.tip[0], ta, tb, tc, tn);
                SohV3 pr = closestOnTri(bl.root[0], ta, tb, tc, tn);
                float d = v3len(v3sub(bl.tip[0], pt));
                float d2 = v3len(v3sub(bl.root[0], pr));
                if (d2 < d) {
                    d = d2;
                }
                if (d < bl.r + 0.01f) {
                    drag = c->cutDrag;
                    break;
                }
            }
        }
        if (drag > 0.0f) {
            float retention = powf(drag, dt * 90.0f);
            st->pos = v3add(st->tgtPos, v3scale(v3sub(st->pos, st->tgtPos), retention));
            SohV3 aerr = q4errorVec(st->tgtQuat, st->quat);
            st->quat = q4normalize(q4mul(q4fromRotVec(v3scale(aerr, 1.0f - retention)), st->quat));
        } else {
            st->pos = st->tgtPos;
            st->quat = st->tgtQuat;
        }
        st->contactCount = 0;
    } else {
        // donor :1163-1184. Substep size is one blade radius of travel, so a
        // fast swing cannot step over a wall; capped, and capped LOWER when
        // passthrough is configured at all because that is the expensive case.
        SohV3 dpos = v3sub(st->tgtPos, st->pos);
        SohV3 drot = q4errorVec(st->tgtQuat, st->quat);
        SohVrBlade bl0;
        buildBlade(&bl0, st->pos, st->quat, c);
        float travel = v3len(dpos) + v3len(drot) * bl0.len;
        float step = (c->bladeRadiusM > 0.002f) ? c->bladeRadiusM : 0.002f;
        int nsub = (int)(travel / step) + 1;
        int maxSub = (c->passthroughMps > 0.0f) ? 8 : 32;
        if (nsub > maxSub) {
            nsub = maxSub;
        }
        float inv = 1.0f / (float)nsub;
        SohV3 dposStep = v3scale(dpos, inv);
        SohV3 drotStep = v3scale(drot, inv);
        for (int s = 0; s < nsub; s++) {
            st->pos = v3add(st->pos, dposStep);
            st->quat = q4normalize(q4mul(q4fromRotVec(drotStep), st->quat));
            depenetrate(st, c, 3, (s == nsub - 1), &nTouch);
        }
        applyFriction(st, c, dt);
    }

    st->bladeOffset = v3len(v3sub(st->tgtPos, st->pos));

    // ---- 4. CONTACT-BEGIN event -------------------------------------------
    // donor :1271-1300. One event per contact EPISODE, not per contact and not
    // per frame: `inContact` is a single flag, which is exactly what makes "one
    // strike per swing" hold on the game side with no hit list.
    if (nTouch > 0) {
        if (!st->inContact && st->contactCount > 0) {
            float impact;
            SohVrBlade blI;
            buildBlade(&blI, st->pos, st->quat, c);
            if (c->pivotOnly) {
                impact = v3len(q4errorVec(st->tgtQuat, st->quat)) * blI.len / dt * 0.25f;
            } else {
                SohV3 vSim = v3scale(v3sub(st->pos, prevSimPos), 1.0f / dt);
                SohV3 vTgt = v3scale(v3sub(st->tgtPos, prevSimPos), 1.0f / dt);
                impact = v3len(v3sub(vSim, vTgt));
            }
            pushEvent((st == &gState[0]) ? SOHVRPHYS_HAND_L : SOHVRPHYS_HAND_R, st->contactPts[0],
                      st->contactNs[0], impact, st->contactIds[0]);
        }
        st->inContact = 1;
    } else {
        st->inContact = 0;
    }

    // The design decision that makes the whole model safe, donor
    // vr_physics.cpp:1236-1238: velocities are DERIVED from the pose change,
    // never integrated. Nothing stores energy, so nothing can ring. They are
    // derived from the SIM pose, so a blade held against a wall reports the
    // velocity it actually has -- while the TIER below still reads the hand,
    // so a pinned blade still reads as a fast swing (donor VrSwing.cpp:1091).
    st->linVel = v3scale(v3sub(st->pos, prevSimPos), 1.0f / dt);
    st->angVel = v3scale(q4errorVec(st->quat, prevSimQuat), 1.0f / dt);
    st->prevPos = st->pos;
    st->prevQuat = st->quat;

    // ---- 5. the blade line, for the swept damage quad ----------------------
    {
        SohV3 tipL = v3(0.0f, 0.0f, c->bladeLenM * (kBladeAxisZ * 2.0f));
        SohV3 base = st->pos;
        SohV3 tip = v3add(st->pos, q4rotate(st->quat, tipL));
        if (st->haveBlade) {
            st->prevBase = st->bladeBase;
            st->prevTip = st->bladeTip;
        } else {
            st->prevBase = base;
            st->prevTip = tip;
            st->haveBlade = 1;
        }
        st->bladeBase = base;
        st->bladeTip = tip;
    }

    // Visual weight lag, donor vr_physics.cpp:1240-1269. Target offset is
    // -angVel * lag, magnitude-capped, sprung underdamped at kVisZeta. It
    // touches visQuat ONLY — simQuat and every threshold read the un-lagged pose.
    {
        SohV3 want = v3scale(st->angVel, -c->visualLagS);
        float m = v3len(want);
        if (m > kVisOffCap && m > 1e-12f) {
            want = v3scale(want, kVisOffCap / m);
        }
        float f = (c->visualSnapHz > 0.1f) ? c->visualSnapHz : 0.1f;
        springStep(&st->visOff, &st->visOffVel, want, v3(0.0f, 0.0f, 0.0f), f, kVisZeta, 0.0f, dt);
    }

    // Blade-midpoint speed, donor VrSwing.cpp:1088-1105. Deliberately NOT a
    // finite difference of blade positions: (1) the tracked velocities exclude
    // locomotion, snap turn and anchor motion, so running never reads as a
    // swing; (2) no noise amplification down the lever; (3) the midpoint halves
    // a wrist flick's lever, which is what makes handFloor meaningful.
    SohV3 midLocal = v3(0.0f, 0.0f, c->bladeLenM * kBladeAxisZ);
    SohV3 r = q4rotate(handQ, midLocal);
    SohV3 vMid = v3add(h->vel, v3cross(h->angVel, r));
    st->midInst = v3len(vMid);
    st->handInst = v3len(h->vel);
    float mid = holdPeak(st->midInst, &st->midSpeed, &st->midAge, c->peakHoldS, dt);
    float hand = holdPeak(st->handInst, &st->handSpeed, &st->handAge, c->peakHoldS, dt);

    // Sensitivity DIVIDES every threshold, so higher = easier to trigger.
    float sens = c->sensitivity;
    float armed = c->tierArmed / sens;
    float hot = c->tierHot / sens;
    float idle = c->tierIdle / sens;
    float floorS = c->handFloor / sens;
    float jump = c->jumpSlash / sens;

    // Tier machine, donor VrSwing.cpp:1118-1141. handFloor gates HOT only: a
    // pure wrist flick may ARM (trail, SFX, enemy windup) but must never damage.
    int prevTier = st->tier;
    int nextTier = prevTier;
    if (mid < idle) {
        nextTier = SOHVRPHYS_TIER_IDLE;
    } else if (mid >= hot && hand >= floorS) {
        nextTier = SOHVRPHYS_TIER_HOT;
    } else if (prevTier == SOHVRPHYS_TIER_IDLE && mid >= armed) {
        nextTier = SOHVRPHYS_TIER_ARMED;
    }
    st->tier = nextTier;

    if (nextTier == SOHVRPHYS_TIER_HOT && prevTier != SOHVRPHYS_TIER_HOT) {
        st->swingSeq++; // once per RISING edge, never per frame spent HOT
        st->swingSpeed = mid;
        st->swingJumpSlash = (mid >= jump) ? 1 : 0;
    }

    // ONE STRIKE PER SWING, donor VrSwing.cpp:1522-1530. The game side is the
    // only thing that can know a damage quad LANDED, and it learns it a tick
    // late; when it tells us, the tier drops HOT -> ARMED. To strike again the
    // blade must re-cross the hit speed, which is what a second swing IS. No
    // hit list, no per-actor bookkeeping, and it cannot leak across a tracking
    // dropout because decayHand clears the flag.
    if (st->hitAck) {
        st->hitAck = 0;
        if (st->tier == SOHVRPHYS_TIER_HOT) {
            st->tier = SOHVRPHYS_TIER_ARMED;
            // Re-seed the held peak, or the very next frame re-crosses the hit
            // tier off the peak the strike itself left behind.
            st->midSpeed = hot * 0.5f;
            st->midAge = 0.0f;
        }
    }
}

void SohVrPhys_Step(float dt, const SohVrPhysHand hands[2]) {
    SohVrPhysCfg* c = cfg();

    // Clamped on use: the cfg is live-mutable from `vr set`, so this is the only
    // place a written value can be caught.
    if (!(c->sensitivity >= 0.5f)) {
        c->sensitivity = 0.5f;
    } else if (c->sensitivity > 2.0f) {
        c->sensitivity = 2.0f;
    }

    // donor vr_physics.cpp:476-480
    if (!(dt > kDtMin)) {
        dt = kDtMin;
    } else if (dt > kDtMax) {
        dt = kDtMax;
    }

    for (int i = 0; i < 2; i++) {
        stepHand(&gState[i], &hands[i], c, dt);
    }
}

int SohVrPhys_Get(int hand, SohVrPhysOut* out) {
    if (!out) {
        return 0;
    }
    memset(out, 0, sizeof(*out));
    if (hand < 0 || hand > 1) {
        return 0;
    }
    SohVrPhysState* st = &gState[hand];
    if (!st->active) {
        return 0;
    }

    out->tier = st->tier;
    out->midSpeed = st->midSpeed;
    out->handSpeed = st->handSpeed;
    out->swingSeq = st->swingSeq;
    out->swingSpeed = st->swingSpeed;
    out->swingJumpSlash = st->swingJumpSlash;
    out->simPos = st->pos;
    out->simQuat = st->quat;
    out->visPos = st->pos; // the lag is orientation-only, donor:1240-1269
    out->visQuat = q4normalize(q4mul(q4fromRotVec(st->visOff), st->quat));
    out->bladeBase = st->bladeBase;
    out->bladeTip = st->bladeTip;
    out->prevBase = st->prevBase;
    out->prevTip = st->prevTip;
    out->contactCount = st->contactCount;
    out->passthrough = st->passthrough;
    out->bladeOffset = st->bladeOffset;
    return 1;
}

int SohVrPhys_Describe(int hand, char* buf, int cap) {
    if (!buf || cap <= 0) {
        return 0;
    }
    if (hand < 0 || hand > 1) {
        buf[0] = '\0';
        return 0;
    }
    SohVrPhysState* st = &gState[hand];
    int n = snprintf(buf, (size_t)cap,
                     "hand=%s active=%d tier=%d mid=%.3f peak_mid=%.3f hand_spd=%.3f swing_seq=%u "
                     "swing_spd=%.3f jump=%d pos=%.3f,%.3f,%.3f quat=%.3f,%.3f,%.3f,%.3f "
                     "vel=%.3f,%.3f,%.3f angvel=%.3f,%.3f,%.3f "
                     "tris=%d contacts=%d pass=%d blade_off=%.4f",
                     (hand == SOHVRPHYS_HAND_L) ? "L" : "R", st->active, st->tier, (double)st->midInst,
                     (double)st->midSpeed, (double)st->handSpeed, st->swingSeq, (double)st->swingSpeed,
                     st->swingJumpSlash, (double)st->pos.x, (double)st->pos.y, (double)st->pos.z,
                     (double)st->quat.x, (double)st->quat.y, (double)st->quat.z, (double)st->quat.w,
                     (double)st->linVel.x, (double)st->linVel.y, (double)st->linVel.z, (double)st->angVel.x,
                     (double)st->angVel.y, (double)st->angVel.z, gTriCount, st->contactCount, st->passthrough,
                     (double)st->bladeOffset);
    if (n < 0) {
        buf[0] = '\0';
        return 0;
    }
    return (n >= cap) ? cap - 1 : n;
}
