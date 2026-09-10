// SohVisionApp.swift — SwiftUI app entry for the visionOS target (D-030).
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit
// can't open one), so the app entry is SwiftUI — but it only HOSTS the
// existing UIKit/SDL engine (SohHostViewController boots it) in a WindowGroup,
// and declares the ImmersiveSpace for stereoscopic 3D. All engine/shell logic
// stays in C/ObjC; this file is scene plumbing only. Adapted from the proven
// vkQuake-ios VKQVisionApp.swift.

import SwiftUI
import CompositorServices
import AVFAudio

final class SohAppModel: ObservableObject {
    static let shared = SohAppModel()
    @Published var immersive = false
    @Published var showSettings = false
    // R10 verdict 6: bumped to ask the 2D sheet to scroll to the section
    // boundary, which is the one part of that layout a screenshot of the top of
    // the page cannot show. `vr settings 2`.
    @Published var settingsScrollToVR = 0
    // R10 verdict 2: and to the temporary left-hand section, which is the row
    // block the user has to read six numbers off and is further down the same
    // undraggable page. `vr settings 3`.
    @Published var settingsScrollToHand = 0
    // VR-spec D3, WITHDRAWN by the user 2026-09-04 (R7 verdict 1): VR is
    // ALWAYS `.full`. The surroundings choice is gone — not defaulted off,
    // removed — because what it chose between was "your real hands and
    // controllers are visible inside Hyrule" and "they are not", and the user's
    // verdict was *"my controllers/hands should not be showing at all. that
    // shouldn't even be an option in settings."* The value survives only so the
    // R0a variant spaces still compile; nothing writes it any more.
    @Published var vrStyle: ImmersionStyle = .full
}

// R7 verdict 1: `vr style` is retained as a REPORTING no-op rather than deleted,
// so an old script or an old note that sends it gets an honest answer instead of
// "unknown command". VR is full immersion, always.
@_cdecl("SohVR_PushStyle")
func SohVR_PushStyle(_ full: Int32) {
    _ = full
    DispatchQueue.main.async { SohAppModel.shared.vrStyle = .full }
}

// R9 part A: open/close the settings sheet from the console bridge. The
// simulator has no scripted tap, so without this the sheet's LAYOUT can only
// ever be compiled and never looked at -- which is precisely the gap R8 part A
// recorded and which the user then found by wearing it. `vr settings 1`.
// R10 verdict 6: `vr settings 2` opens it AND scrolls to the 3D/VR boundary,
// because the defect the user reported is at a boundary 760 points down a page
// the simulator has no way to drag.
@_cdecl("SohVR_ShowSettings")
func SohVR_ShowSettings(_ on: Int32) {
    DispatchQueue.main.async {
        SohAppModel.shared.showSettings = (on != 0)
        if on == 2 {
            SohAppModel.shared.settingsScrollToVR += 1
        } else if on == 3 {
            SohAppModel.shared.settingsScrollToHand += 1
        }
    }
}

// Called from ObjC (SohHostViewController) to flip the SwiftUI state that
// actually opens/dismisses the space.
@_cdecl("Soh_SetImmersiveMode")
func Soh_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { SohAppModel.shared.immersive = on }
}

// In 3D, anchor the app's sound stage to the FRONT (at the panel) instead of
// the parked-aside 2D window. Restored on exit.
private func sohSetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        // SDL configures the session for plain playback; the spatial-experience
        // call can silently no-op under some categories/modes (device symptom:
        // audio stays at the parked window). Assert the compatible setup first.
        if on && session.category != .playback {
            try session.setCategory(.playback, mode: .default)
        }
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .large, anchoringStrategy: .front))
            SohIos_SetAudioAnchorStatus(1)
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[Soh3D] Swift: audio spatial experience -> \(on ? "front" : "automatic")")
    } catch {
        NSLog("[Soh3D] Swift: setIntendedSpatialExperience failed: \(error)")
        SohIos_SetAudioAnchorStatus(2)
    }
}

// Re-apply the front-anchored sound stage every few seconds while in 3D:
// SDL re-configures the audio session behind our back (device symptom: audio
// anchored at the parked-aside window, not the panel).
private var sohAudioTimer: Timer?
private func sohStartAudioReanchor() {
    sohStopAudioReanchor()
    sohSetAudioFrontStage(true)
    sohAudioTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
        sohSetAudioFrontStage(true)
    }
}
private func sohStopAudioReanchor() {
    sohAudioTimer?.invalidate()
    sohAudioTimer = nil
}

struct SohWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SohHostViewController {
        return SohHostViewController()
    }
    func updateUIViewController(_ vc: SohHostViewController, context: Context) {}
}

// Query capabilities so we never request an unsupported combination (which
// makes openImmersiveSpace fail with a generic .error).
struct SohCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // D-036 (3D crispness): dynamic foveation concentrates rasterization
        // density where the eyes look — the same mechanism that makes system
        // windows crisp. Our panel pass renders with the drawable's
        // rasterization rate map (SohImmersive.m). UNCONDITIONAL where the
        // hardware supports it (user call, post-validation: no fps impact,
        // "nobody wants blurry" — the old CVar gate only existed for bring-up).
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        // rev3 (device round: right eye warped): with LAYERED layout the
        // drawable has one multi-layer rate map, and our per-slice passes
        // always rasterize with layer 0's map — left eye fine, right eye
        // fisheye. Dedicated layout gives each eye its own texture AND its
        // own rate map, which our two-pass loop maps correctly.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // D-036 second lever RETIRED (2026-07-22): raising maxRenderQuality
        // aborts the compositor on DEVICE too (crash.txt: CompositorNonUI
        // abort in Soh3D_Immersive_Run at 3D entry), not just the sim.
        // Foveation alone is the shipped lever; do not re-attempt a quality
        // raise without a validation API that doesn't abort.
        if #available(visionOS 26.0, *) {
            NSLog("[Soh3D] Swift: default render quality=\(capabilities.defaultRenderQuality.rawValue)")
        }
        NSLog("[Soh3D] Swift: compositor configured (layered=\(layouts.contains(.layered)) foveation=\(fov))")
    }
}

// Live 3D-panel settings (persisted in UserDefaults, pushed to the loop's
// setters both on change and on immersive entry).
// --- R12 item 3: ONE SCROLLER, AND THE ROWS ARE ROWS -------------------------
//
// the user, on 1.0.1.15: *"In 2D mode the settings were clipped -- couldn't
// scroll past the Right Controller Up row; had to enter VR to see all of
// them."* This is R10 verdict 6's defect a second time, and the second time is
// the evidence that the SHAPE is wrong rather than the number.
//
// The 2D sheet is an outer ScrollView with two pinned-header sections, and each
// section contained a whole `Form` -- itself a scrolling List. A scroller inside
// a scroller eats the outer drag, so R10 disabled the inner scroll and gave the
// Form an explicit height (900 and 2000). A Form clipped to a frame shorter
// than its content simply CLIPS: everything past that height is unreachable
// from either scroller. R11 added six more sliders and a Reset to the VR
// section -- twelve became twenty-four -- and 2000 stopped covering it, which
// is the row he could not get past.
//
// A hardcoded height is a measurement of a layout, and this program has now
// twice shipped one that the next round invalidated. So the nesting goes: in 2D
// each settings view renders its Sections as PLAIN ROWS in a VStack, with no
// scroll view of its own and no height at all. The outer ScrollView measures
// them, and it reaches the bottom by construction -- there is nothing left to
// clip. In an immersive space, where the settings view IS the whole sheet, it
// is still a Form and looks exactly as it did.
//
// The two views stay SPLIT (R8's finding, still load-bearing: merging the two
// Form bodies into one expression puts the Swift type checker over its limit).
// This adds no merge -- each view's body is the same single expression it
// already was, wrapped in one container that chooses between Form and VStack.
struct SohSettingsGroup<Content: View>: View {
    let flat: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if flat {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        } else {
            Form {
                content
            }
        }
    }
}

struct Soh3DSettingsView: View {
    // R12 item 3: true only in the plain-2D sheet, where this view is one
    // section of an outer scroller rather than the whole page.
    var flat: Bool = false
    @AppStorage("vp3dDist") private var dist = 3.6
    @AppStorage("vp3dHalfW") private var halfW = 2.75
    @AppStorage("vp3dHalfH") private var halfH = 1.55
    @AppStorage("vp3dHeight") private var height = 0.0
    @AppStorage("vp3dDim") private var dim = 0.8
    @AppStorage("vp3dDepth200") private var depth200 = 100.0
    @AppStorage("vp3dUseFeet") private var useFeet = false

    static func resetAll() {
        let d = UserDefaults.standard
        d.set(3.6, forKey: "vp3dDist"); d.set(2.75, forKey: "vp3dHalfW")
        d.set(1.55, forKey: "vp3dHalfH"); d.set(0.0, forKey: "vp3dHeight")
        d.set(0.8, forKey: "vp3dDim"); d.set(100.0, forKey: "vp3dDepth200")
        applyAll()
    }

    static func applyAll() {
        let d = UserDefaults.standard
        func f(_ k: String, _ def: Double) -> Float {
            return Float(d.object(forKey: k) != nil ? d.double(forKey: k) : def)
        }
        Soh3D_SetPanel(f("vp3dDist", 3.6), f("vp3dHalfW", 2.75), f("vp3dHalfH", 1.55))
        Soh3D_SetHeight(f("vp3dHeight", 0.0))
        Soh3D_SetDim(f("vp3dDim", 0.8)) // 80% default (user-requested)
        // 100% = 3.25% eye-offset fraction — the user's device-tuned preference
        // (was 130% on the old 2.5% scale; whole scale raised 1.3x so their
        // choice is the new center with headroom both ways).
        // Focus bias pinned at 100% (removed from UI; aiming auto-adapts it).
        Soh3D_SetStereoParams(f("vp3dDepth200", 100.0) / 100.0 * 0.0325, 1.0)
    }

    private func fmt(_ meters: Double) -> String {
        return useFeet ? String(format: "%.1f ft", meters * 3.28084)
                       : String(format: "%.1f m", meters)
    }

    var body: some View {
        SohSettingsGroup(flat: flat) {
            Section("Screen") {
                LabeledContent("Distance  \(fmt(dist))") {
                    Slider(value: $dist, in: 1.0...8.0) { _ in }
                }
                LabeledContent("Width  \(fmt(halfW * 2))") {
                    Slider(value: $halfW, in: 0.6...4.0)
                }
                LabeledContent("Height  \(fmt(halfH * 2))") {
                    Slider(value: $halfH, in: 0.4...3.0)
                }
                // range reaches ceiling placement for lying-down play
                LabeledContent("Position height  \(fmt(height))") {
                    Slider(value: $height, in: -1.5...5.0)
                }
                LabeledContent("Units") {
                    Picker("", selection: $useFeet) {
                        Text("m").tag(false)
                        Text("ft").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
            }
            Section("Stereo Depth") {
                // Convergence auto-follows the game camera (Link stays on the
                // panel plane); Depth is the one knob most users touch.
                // 0-200% convention shared with the other ports.
                LabeledContent("Depth  \(Int(depth200))%") {
                    Slider(value: $depth200, in: 0.0...200.0)
                }
            }
            Section("Surroundings") {
                LabeledContent("Dim  \(Int(dim * 100))%") {
                    Slider(value: $dim, in: 0.0...1.0)
                }
            }
            Section {
                Button("Recenter Screen") { Soh3D_Recenter() }
            }
        }
        .onChange(of: dist) { Self.applyAll() }
        .onChange(of: halfW) { Self.applyAll() }
        .onChange(of: halfH) { Self.applyAll() }
        .onChange(of: height) { Self.applyAll() }
        .onChange(of: dim) { Self.applyAll() }
        .onChange(of: depth200) { Self.applyAll() }
    }
}

// VR settings (VR-spec D6/D9: manual recenter gets a UI from day one — the
// donor never gave it one, and its own notes call that the single most-needed
// missing VR affordance). Persisted in UserDefaults and pushed to the loop both
// on change and on VR entry, exactly like the 3D panel's.
//
// R8 (the user, wearing 1.0.1.10). SIX SETTINGS LEFT THIS ROUND, and each one for
// the same reason: it was not a preference. The hand calibration (twelve
// sliders), the world scale, the eye height and head trim (two knobs for one
// quantity), "hide Link's body", the HUD distance, the HUD-plane switch, "turn
// the world toward a Z-target", "show the world behind menus" and the
// pre-rendered-room picker are all gone. What replaces the height pair is ONE
// trim against a calibration the app performs for you; what replaces the rest
// is a constant.
//
// A NOTE ON REMOVING A SETTING, because it is the part that bites: deleting the
// row is not enough. A key already written into UserDefaults keeps being read by
// applyAll() and would overwrite the new constant on the next VR entry, so the
// PUSH has to go with the row. That is why applyAll below no longer mentions
// vrWorldScale, vrHandL*/vrHandR*, vrHideBody, vrEyeHeightOffset, vrHudDistance,
// vrHudPlane, vrLockOnFraming, vrFlatWorld or vrRoomMode at all: a stale value
// for any of them is now inert.

// --- R14 item 3: THE HAND CALIBRATION SLIDERS ARE GONE ----------------------
//
// the user, on 1.0.1.17: "Remove all the sliders for sword, shield, off hand --
// it's dialed in." R13 froze the twenty-four numbers (four rolls moved and
// nothing else, which is what convergence looks like) and D-053's rule says a
// knob that existed to FIND a number is retired when the number is found.
//
// Three things went with the section, because deleting the rows alone is how a
// constant quietly stops being a constant:
//   * SohVRHandCalKeys and the vrHand3_ namespace, so nothing reads a stored
//     value any more. The dead keys are removed in resetAll's dead list.
//   * applyAll()'s push. That push was ALSO what swapped the calibration when
//     the Sword-hand picker changed, so SohVR_SetLeftHanded in the shell loads
//     the configuration's row itself now -- one writer, and the swap survives
//     the sliders it used to depend on.
//   * `vr settings 3`, which scrolled to this section, now opens on the
//     "leftHandCal" anchor -- which R17 item 5 moved onto the Aiming section,
//     the last row left of three retired calibration sections.
// `vr handcal` and `vr set hand*` stay: a console dial is not a settings knob,
// and the suite reads the frozen table through them.
//
// R17 item 5: AND NOW THE HELD-ITEM SECTION IS GONE TOO, along with the aim
// trims. the user dialled the hookshot's pitch (-55) and the bow/slingshot split
// on 1.0.1.21; the numbers are frozen in the shell and the sections said what
// they were for.

// R14 item 3: the hand-calibration keys of every generation, removed once and
// then never read again. A key nobody reads is inert, but a key nobody reads is
// also a value that will surprise whoever revives the section, so it goes.
enum SohVRDeadHandCalKeys {
    static func purge() {
        let d = UserDefaults.standard
        if d.bool(forKey: "vrHandCalRetiredR14") {
            return
        }
        let axes = ["offX", "offY", "offZ", "yaw", "pitch", "roll"]
        for prefix in ["vrHand_", "vrHand2_", "vrHand3_"] {
            for lh in ["LH", "RH"] {
                for h in ["L", "R"] {
                    for a in axes {
                        d.removeObject(forKey: "\(prefix)\(lh)_\(h)_\(a)")
                    }
                }
            }
        }
        d.removeObject(forKey: "vrHandCalPurgedR13")
        d.set(true, forKey: "vrHandCalRetiredR14")
    }
}

// --- R17 item 5: THE CALIBRATION SECTIONS ARE GONE --------------------------
//
// the user, on 1.0.1.21: *"you can remove all calibration settings now, we have
// them dialed."* Two sections went with that sentence -- R14's *Aim calibration
// (TEMPORARY)* (the trims, the `Aim:` read-out and its Reset) and R12's *Held
// item calibration (TEMPORARY)* (twelve sliders and their Reset) -- exactly as
// R14 retired the hand sliders (D-062 section 3).
//
// The rule R14 learned the hard way applies again, and it is the only part of
// this that can silently break: DELETING A SETTINGS ROW WITHOUT MOVING WHAT IT
// DID is how a constant quietly stops being applied. Both pushes are replaced
// by shell-side constructors, which is strictly stronger than a push from Swift
// because they run before any game thread can read the tables:
//
//   * the held-item rows: `sohvr_itemCalInit` in SohImmersive.m already loaded
//     kSohVRItemCal into both configurations at load time -- SohVRItemCalKeys
//     .pushAll() only ever wrote the same numbers back, or a STORED value on
//     top of them, which is the thing R17 wants gone.
//   * the aim trims: new, `sohvr_aimTrimInit` in SohIosShell.m, loading
//     kSohVRAimTrim. R15b's -15 pitch lived in this file's `defaultValue` and
//     nowhere else, so without that constructor the trims would have shipped
//     as zeros.
//
// Neither table is per-configuration-switched: the shell keeps both
// configurations live and the pin picks by gSohVRLeftHanded, so unlike the hand
// calibration there is nothing for SohVR_SetLeftHanded to reload.
//
// The **Aim crosshair** toggle is NOT calibration -- it is a user option, and it
// moves into a plain VR settings section of its own. The console dials
// (`vr itemcal`, `vr set aimyaw|aimpitch|aimreticle|aimreticlescale`, `vr aim`)
// all stay: they are the engineering door, and a door with no UI behind it is
// exactly what a shipped default wants.
enum SohVRDeadCalKeys {
    // Every stored key of both retired sections, removed ONCE. A stored value
    // beats a shipped default, and the user's install carries R13's item rows and
    // R14/R15b's aim trims under these names -- so purging is the same
    // guarantee the round's brief asked for as a `vrItem2_` -> `vrItem3_`
    // namespace bump, in its stronger form: after this there is no reader of an
    // item or aim-trim key at all, in any generation, so no stored value can
    // reach the game side by any path.
    static let itemAxes = ["yaw", "pitch", "roll", "offX", "offY", "offZ"]
    static let aimAxes = ["yaw", "pitch"]
    static let modelCount = 17

    static func purge() {
        let d = UserDefaults.standard
        if d.bool(forKey: "vrCalRetiredR17") {
            return
        }
        for lh in ["LH", "RH"] {
            for m in 0..<modelCount {
                for prefix in ["vrItem_", "vrItem2_", "vrItem3_"] {
                    for a in itemAxes {
                        d.removeObject(forKey: "\(prefix)\(lh)_\(m)_\(a)")
                    }
                }
                for prefix in ["vrAim_", "vrAim2_"] {
                    for a in aimAxes {
                        d.removeObject(forKey: "\(prefix)\(lh)_\(m)_\(a)")
                    }
                }
            }
        }
        d.removeObject(forKey: "vrItemCalPurgedR13")
        d.set(true, forKey: "vrCalRetiredR17")
    }
}

struct SohVRSettingsView: View {
    // R12 item 3: see SohSettingsGroup. In the plain-2D sheet these Sections
    // are rows of the OUTER list; in an immersive space they are a Form.
    var flat: Bool = false
    // R8 item 5: ONE height knob, and it is a TRIM against the app's own
    // calibration. Entering VR (and every first-person re-entry) seats the room
    // origin on the live head so the wearer's eyes land exactly at Link's eye
    // height; THAT state is 0.0 and this is the signed offset from it.
    @AppStorage("vrHeightTrim") private var heightTrim = 0.0
    // R2a: eye render scale, on top of the drawable-derived eye extent.
    @AppStorage("vrEyeScale") private var eyeScale = 1.0
    // R8 item 7: the HUD has two settings. Height is signed metres above eye
    // level (sohvr_hudUp); Size is the plane's width, height following the 4:3
    // framebuffer. The distance is fixed at 2.0 m and has no key.
    @AppStorage("vrHudUp") private var hudUp = 0.0
    @AppStorage("vrHudWidth") private var hudWidth = 3.0
    // R3 (spec D6): ONE turn knob. Index 0 = SMOOTH (the default), 1..5 are
    // the snap angles 15/30/45/60/90. the user, 2026-09-03: "SMOOTH should be an
    // option instead of snap turning (all the way to the left of the slider
    // should be SMOOTH) and smooth turning should be the default."
    @AppStorage("vrTurnIndex") private var turnIndex = 0.0
    // R15, kept by R17 item 5: the aim crosshair. A user option, not
    // calibration, so it outlives the section it was born in.
    @AppStorage("vrAimReticle") private var aimReticle = true
    @AppStorage("vrSmoothTurnSpeed") private var smoothTurnSpeed = 120.0
    // R3 (spec D4, DONOR-MAP 3 + 4b): Link's body follows your head.
    @AppStorage("vrBodyFollowsHead") private var bodyFollowsHead = true
    // R7 verdict 5 / R8 item 8: default ON, his call. One toggle, two moves.
    @AppStorage("vrFlipCam") private var flipCam = true
    // R9 part A item 2: which hand holds the sword. Ships RIGHT (false), which
    // is the donor's gVrLeftHanded 0 and the way Link does it.
    @AppStorage("vrLeftHanded") private var leftHanded = false
    @AppStorage("vrEyeBudget") private var eyeBudget = 4096.0
    // R10 verdict 2 — TEMPORARY, and it is marked temporary in the UI as well.
    //
    // the user, on 1.0.1.13: *"That fix readjusted the LEFT hand. I need the left
    // hand sliders again to fix it and give you the hardcoded defaults."* R9
    // part A moved the published pose onto the accessory's GRIP space and
    // re-based BOTH hands' offsets to zero with it; the right hand landed right
    // and the left did not. These six sliders exist to find six numbers, and
    // when the numbers arrive they get frozen into sohvr_handOffCm /
    // sohvr_handRotDeg and this section is deleted — which is D-053's rule
    // ("a knob that existed to FIND a number is retired when the number is
    // found") applied on purpose rather than by accident.
    //
    // LEFT HAND ONLY. The right hand is the user's verdict "the right hand is
    // good": a slider that can move a correct thing is a way to break it.
    // The keys are R7's own, deliberately: an install that still carries them
    // from before R8 deleted the section reads its old value here rather than
    // silently ignoring it, and `resetAll` is what puts it back to the shipped
    // constant.
    // R11 verdict 2 moved the twelve numbers into a per-configuration section
    // of twenty-four; R14 item 3 RETIRED that section, because the user dialled
    // both configurations and said "it's dialed in". The numbers live in
    // kSohVRHandCal in the shell and nothing in this file reads or writes them
    // any more -- see the R14 note beside SohVRDeadHandCalKeys.

    // 0 = SMOOTH; 1..5 = the snap angles. One function, so the slider label and
    // the value handed to the shell can never disagree.
    static let turnStops: [Double] = [0, 15, 30, 45, 60, 90]
    static func turnDegrees(for index: Double) -> Double {
        let i = max(0, min(turnStops.count - 1, Int(index.rounded())))
        return turnStops[i]
    }
    static func turnLabel(for index: Double) -> String {
        let deg = turnDegrees(for: index)
        return deg <= 0 ? "Smooth" : "Snap \(Int(deg))°"
    }
    // Signed, so "0.0" reads as the calibrated state rather than as a minimum.
    static func signed(_ v: Double, _ unit: String) -> String {
        return String(format: "%+.2f %@", v, unit)
    }

    static func resetAll() {
        let d = UserDefaults.standard
        d.set(0.0, forKey: "vrHeightTrim")
        d.set(1.0, forKey: "vrEyeScale")
        d.set(0.0, forKey: "vrHudUp")
        d.set(3.0, forKey: "vrHudWidth")
        d.set(0.0, forKey: "vrTurnIndex")
        d.set(120.0, forKey: "vrSmoothTurnSpeed")
        d.set(true, forKey: "vrBodyFollowsHead")
        d.set(true, forKey: "vrFlipCam")
        d.set(false, forKey: "vrLeftHanded")
        d.set(4096.0, forKey: "vrEyeBudget")
        // R17 item 5: the two calibration sections are GONE and their rows are
        // shell constants, so there is nothing here to reset -- only the keys to
        // remove, below. The crosshair is a user option and does have a default.
        d.set(true, forKey: "vrAimReticle")
        // R8: keys that no longer have a row are REMOVED rather than rewritten.
        // Leaving a stale value behind for a setting nobody can see is how a
        // hardcoded constant gets quietly overridden on somebody's device six
        // months from now; removeObject makes the old install match a fresh one.
        for dead in ["vrWorldScale", "vrHeight", "vrEyeHeightOffset", "vrHideBody",
                     "vrLockOnFraming", "vrFlatWorld", "vrRoomMode", "vrHudPlane",
                     "vrHudDistance", "vrAnchorGizmo",
                     // R11 verdict 2: R7's and R10's un-suffixed keys are dead.
                     // The calibration is per CONFIGURATION now, so a value
                     // stored under the old names cannot say which of the two
                     // sets it belongs to; keeping it would silently apply a
                     // right-handed dial to a left-handed session.
                     "vrHandLOffX", "vrHandLOffY", "vrHandLOffZ",
                     "vrHandLYaw", "vrHandLPitch", "vrHandLRoll",
                     "vrHandROffX", "vrHandROffY", "vrHandROffZ",
                     "vrHandRYaw", "vrHandRPitch", "vrHandRRoll"] {
            d.removeObject(forKey: dead)
        }
        SohVRDeadHandCalKeys.purge()
        SohVRDeadCalKeys.purge() // R17 item 5
        applyAll()
    }

    static func applyAll() {
        let d = UserDefaults.standard
        func f(_ k: String, _ def: Double) -> Float {
            return Float(d.object(forKey: k) != nil ? d.double(forKey: k) : def)
        }
        func b(_ k: String, _ def: Bool) -> Bool {
            return d.object(forKey: k) != nil ? d.bool(forKey: k) : def
        }
        // R8: NOTHING here pushes the world scale, the hand calibration, the
        // head trim, hide-body, the HUD distance or plane, lock-on framing, the
        // flat-world backdrop or the room mode. Those are constants in the
        // shell now, and a push from a stale key is exactly how they would stop
        // being constants.
        SohVR_SetHeightTrim(f("vrHeightTrim", 0.0))
        SohVR_SetEyeScale(f("vrEyeScale", 1.0))
        SohVR_SetHudUp(f("vrHudUp", 0.0))
        SohVR_SetHudWidth(f("vrHudWidth", 3.0))
        SohVR_SetTurnDegrees(Float(Self.turnDegrees(for: Double(f("vrTurnIndex", 0.0)))))
        SohVR_SetSmoothTurnSpeed(f("vrSmoothTurnSpeed", 120.0))
        SohVR_SetBodyFollowsHead(b("vrBodyFollowsHead", true) ? 1 : 0)
        SohVR_SetFlipCam(b("vrFlipCam", true) ? 1 : 0)
        SohVR_SetAimReticle(b("vrAimReticle", true) ? 1 : 0) // R15
        SohVR_SetLeftHanded(b("vrLeftHanded", false) ? 1 : 0)
        SohVR_SetEyeBudget(f("vrEyeBudget", 4096.0))
        // R11 verdict 2: BOTH controllers, from the CURRENT configuration's set.
        // The push comes after SohVR_SetLeftHanded above deliberately: switching
        // the Sword-hand picker calls applyAll(), so the whole calibration swaps
        // live in the same pass that swaps the roles it belongs to.
        //
        // The stored z is already the negation of the slider's "Forward" (the
        // controller's own forward is −z); the negation happens once, where the
        // slider is read, so nothing downstream has to remember it.
        // R12 item 2: the R11 keys go away BEFORE the push reads anything, so
        // the first push of a session on an upgraded install is already the new
        // frozen constants.
        // R14 item 3: no hand-calibration push. SohVR_SetLeftHanded above loads
        // the configuration's frozen row in the shell, and the stored keys of
        // every generation are removed rather than left to be read by nothing.
        SohVRDeadHandCalKeys.purge()
        // R17 item 5: NO held-item push and NO aim-trim push. Both tables are
        // shell constants loaded by a constructor (sohvr_itemCalInit and
        // sohvr_aimTrimInit) before any game thread can read them, and every
        // stored key of every generation is removed here rather than left for
        // nothing to read. See the note beside SohVRDeadCalKeys.
        SohVRDeadCalKeys.purge()
    }

    var body: some View {
        SohSettingsGroup(flat: flat) {
            Section("Height") {
                // R8 item 5. the user, on 1.0.1.10: after exiting VR and going
                // back in he was TOO TALL. The cause and the fix are both in
                // the shell (the first-person recenter could be consumed on a
                // frame whose head pose was still the identity); what changed
                // here is the MODEL. There is no "eye height" and no "head
                // trim" any more — the app calibrates so your eyes sit at
                // Link's, and this is how far off that you would like to be.
                LabeledContent("Height  \(Self.signed(heightTrim, "m"))") {
                    Slider(value: $heightTrim, in: -0.5...0.5, step: 0.05)
                }
                Button("Re-calibrate VR height") { SohVR_RecalibrateHeight() }
                Text("0.00 m puts your eyes exactly at Link's. Re-calibrate if you stand up, sit down, or change seats.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            // R2b. First person is the VR view — there is no third-person mode
            // any more; the 3D panel mode is the third-person experience.
            Section("Movement & comfort") {
                LabeledContent("Turning  \(Self.turnLabel(for: turnIndex))") {
                    Slider(value: $turnIndex, in: 0.0...5.0, step: 1.0)
                }
                if Self.turnDegrees(for: turnIndex) <= 0 {
                    LabeledContent("Turn speed  \(Int(smoothTurnSpeed))°/s") {
                        Slider(value: $smoothTurnSpeed, in: 30.0...360.0, step: 10.0)
                    }
                }
                Text("The right stick turns you. Hold the right grip and the stick becomes the C-buttons.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Link's body follows your head", isOn: $bodyFollowsHead)
                Toggle("Backflip/Roll camera", isOn: $flipCam)
                Text("Your view somersaults with Link — backward through a Z-target backflip, forward through a roll. Turn it off to keep your head level.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            // R2b (spec D7). The HUD, the scene title card and dialogue are
            // 2D screen draws: at identical pixels in both eyes they land at
            // two different directions and never fuse. Rendered once and hung
            // on a flat plane in front of you, they do.
            // R8 item 7: two settings. The distance is fixed at 2.0 m.
            Section("HUD") {
                LabeledContent("Height  \(Self.signed(hudUp, "m"))") {
                    Slider(value: $hudUp, in: -1.0...1.0, step: 0.05)
                }
                LabeledContent("Size  \(String(format: "%.1f m", hudWidth))") {
                    Slider(value: $hudWidth, in: 0.8...4.0)
                }
            }
            Section("Hands") {
                // R9 part A item 2. One setting, one variable
                // (gSohVRLeftHanded): the drawn hands and their mirror, the
                // physical blade, the shield, the item wheel and the item
                // trigger reservation all derive from it. The anchor gizmo that
                // used to live in this section is GONE — the user, on 1.0.1.12:
                // "the anchors are just a guide, doesn't solve our problem."
                LabeledContent("Sword hand") {
                    Picker("", selection: $leftHanded) {
                        Text("Right").tag(false)
                        Text("Left").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
                Text("Which hand swings the sword. The other hand carries the shield and the item wheel.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            // R17 item 5: what is LEFT of two retired calibration sections --
            // one user option. The scroll anchor keeps its R14 name so
            // `vr settings 3` still lands on a row that exists.
            Section("Aiming") {
                Color.clear.frame(height: 0).id("leftHandCal")
                Toggle("Aim crosshair", isOn: $aimReticle)
                Text("Shows where the shot will land — on whatever surface it would hit, and at the item's maximum range when it would hit nothing. Covers the bow and slingshot, the hookshot and longshot, and the boomerang.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Rendering") {
                LabeledContent("Eye render scale  \(Int(eyeScale * 100))%") {
                    Slider(value: $eyeScale, in: 0.5...1.5)
                }
                // R2b: measured on device — 4096 held 60 fps at 13.4 Mpix/eye
                // and the user found 2048 grainy.
                LabeledContent("Eye resolution  \(Int(eyeBudget)) px") {
                    Slider(value: $eyeBudget, in: 1024.0...4096.0, step: 256.0)
                }
            }
            Section {
                // Deliberately a no-op-style recenter: it re-seats where you
                // are sitting and captures NOTHING into steering. A captured
                // steering offset is the donor's recorded "walking sideways"
                // bug (VR-DONOR-MAP §4f). R8: it is the same code as
                // "Re-calibrate VR height" above, because it always was.
                Button("Recenter") { SohVR_Recenter() }
            }
        }
        .onChange(of: heightTrim) { Self.applyAll() }
        .onChange(of: eyeScale) { Self.applyAll() }
        .onChange(of: hudUp) { Self.applyAll() }
        .onChange(of: hudWidth) { Self.applyAll() }
        .onChange(of: turnIndex) { Self.applyAll() }
        .onChange(of: smoothTurnSpeed) { Self.applyAll() }
        .onChange(of: bodyFollowsHead) { Self.applyAll() }
        .onChange(of: flipCam) { Self.applyAll() }
        .onChange(of: leftHanded) { Self.applyAll() }
        .onChange(of: eyeBudget) { Self.applyAll() }
        .onChange(of: aimReticle) { Self.applyAll() }
    }
}

// R9 part A item 1: THE SHEET SHOWS WHAT THE MODE CAN USE, AND NOTHING ELSE.
//
// the user, on 1.0.1.12: *"I said 3D screen settings should be invisible when in
// VR mode, and VR mode settings should be invisible when in 3D mode. Instead
// you just created tabs… the reset button applies to both settings. It should
// not."* R8 read item 3 as "make both groups REACHABLE" and delivered a
// segmented picker; what he asked for is that each mode shows only its own
// group, and that plain 2D — where neither is running — shows both, as two
// sections of ONE scrolling list with sticky headers.
//
// The mode predicate is the existing state and no new flag: `model.immersive`
// is false in the flat window (both groups), and when it is true
// `SohVR_IsActive()` separates the VR space from the 3D panel space. Those are
// the same two calls the ornament's own 3D/VR/Exit buttons switch on, so the
// sheet cannot disagree with the buttons that opened it.
//
// RESET IS PER SECTION AND ALWAYS WAS SUPPOSED TO BE. In the two immersive
// modes there is exactly one section and one Reset, so the ambiguity he hit
// cannot arise. In 2D each section header carries its own Reset button, pinned
// with the header.
//
// The two Views stay SPLIT (R8's finding, unchanged and still load-bearing): a
// Form body is ONE expression and merging them puts the Swift type checker over
// its time limit outright. The 2D layout is therefore a ScrollView +
// LazyVStack(pinnedViews: [.sectionHeaders]) whose two sections each contain
// one of the existing Views, rather than one merged Form.
private struct SohSettingsHeader: View {
    let title: String
    let reset: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button("Reset", action: reset)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            Divider()
        }
        // R10 verdict 6: the user, on 1.0.1.13 — *"the 'VR Settings … Reset'
        // header line overlaps with the last line of 3D settings (Recenter
        // Screen) in 2D mode."* Three things were wrong and all three are
        // fixed here, because any one of them alone reproduces it:
        //
        //   * `.regularMaterial` is TRANSLUCENT. A pinned header is drawn over
        //     rows that are still scrolling underneath it, and a translucent
        //     backing shows them through — which is what "overlaps" looks like.
        //     It is an opaque fill now, with the material kept on top for the
        //     visionOS look rather than as the only thing between two layers of
        //     text.
        //   * The HStack sized itself to its CONTENT, so the fill it carried
        //     was only as wide as the title plus the button, and the rows
        //     scrolled past on both sides of it. `maxWidth: .infinity`.
        //   * There was no bottom edge, so even opaque the boundary read as one
        //     list, not two sections. The Divider is that edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .background(.regularMaterial)
    }
}

struct SohSettingsSheet: View {
    @ObservedObject var model: SohAppModel

    // 0 = plain 2D (both), 1 = VR only, 2 = 3D panel only.
    private var mode: Int {
        if !model.immersive { return 0 }
        return SohVR_IsActive() != 0 ? 1 : 2
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title3.weight(.semibold))
                Spacer()
                // In an immersive mode the sheet has ONE group, so Reset is
                // unambiguous and lives up here. In 2D there are two groups and
                // Reset belongs to each section header instead — never to both.
                if mode == 1 {
                    Button("Reset") { SohVRSettingsView.resetAll() }.font(.title3)
                } else if mode == 2 {
                    Button("Reset") { Soh3DSettingsView.resetAll() }.font(.title3)
                }
                Button("Done") { model.showSettings = false }
                    .font(.title3)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            if mode == 1 {
                SohVRSettingsView()
            } else if mode == 2 {
                Soh3DSettingsView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                // R12 item 3: NO inner scroll view and NO
                                // height. `flat: true` makes the settings view
                                // render its Sections as plain rows, so this
                                // outer ScrollView measures the real content
                                // and can reach every row of it. The two
                                // hardcoded heights that used to live here
                                // (900 and 2000) were measurements of a layout,
                                // and both were invalidated by the next round
                                // that added a row.
                                Soh3DSettingsView(flat: true)
                                    .padding(.bottom, 24)
                            } header: {
                                SohSettingsHeader(title: "3D Screen") { Soh3DSettingsView.resetAll() }
                            }
                            Section {
                                SohVRSettingsView(flat: true)
                                    .padding(.bottom, 24)
                            } header: {
                                SohSettingsHeader(title: "Vision Pro VR") { SohVRSettingsView.resetAll() }
                                    .id("vrHeader")
                            }
                        }
                    }
                    .onChange(of: model.settingsScrollToHand) {
                        withAnimation(nil) { proxy.scrollTo("leftHandCal", anchor: .center) }
                    }
                    .onChange(of: model.settingsScrollToVR) {
                        // .center, not .top: pinned at the top the header
                        // would sit exactly where it always sits and the rows
                        // it was overlapping would be off screen above it. The
                        // boundary is the thing to photograph.
                        withAnimation(nil) { proxy.scrollTo("vrHeader", anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 700)
    }
}

struct SohRootView: View {
    @ObservedObject private var model = SohAppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        SohWindowView()
            .ignoresSafeArea()
            // 3D + settings in a BOTTOM ornament, pushed fully BELOW the
            // window (the default centered ornament straddles the boundary and
            // overlaps game content).
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    // VR-spec D1: tri-state. Flat offers BOTH immersive
                    // modes; either immersive mode offers one Exit. 3D<->VR is
                    // dismiss-then-open with the engine still running, which is
                    // what tapping Exit then the other button does — the spaces
                    // are never open at the same time.
                    if model.immersive {
                        Button("Exit") {
                            if SohVR_IsActive() != 0 {
                                Soh_EnterVR(false)
                            } else {
                                Soh_Enter3D(false)
                            }
                        }
                    } else {
                        Button("3D") { Soh_Enter3D(true) }
                        Button("VR") { Soh_EnterVR(true) }
                    }
                    // D-041: no "Menu" button in 3D. The enhancements menu is
                    // display-only on the panel (no in-immersive input — that
                    // would need gaze/RealityKit or a second nav model), so
                    // opening it there was a dead end. 3D-panel comfort settings
                    // live in the gear sheet below; for the full menu, tap
                    // "Exit 3D", change it in 2D (fully touch-interactive), and
                    // tap "3D" again — the transition is seamless.
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14)
            }
            // SwiftUI sheet (a UIKit modal silently fails over an open
            // ImmersiveSpace). Width-only frame; own Done bar.
            // R9 part A item 1 (the user, on 1.0.1.12): the sheet shows the
            // group the CURRENT MODE can use — VR settings in VR, 3D screen
            // settings on the panel, and BOTH in the flat window, where
            // neither is running and both are worth setting up before you go
            // in. R8's segmented tabs are gone; so is the single Reset that
            // could be read as resetting the group you were not looking at.
            // See the long note above SohSettingsSheet.
            .sheet(isPresented: $model.showSettings) {
                SohSettingsSheet(model: model)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[Soh3D] Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        // R17 part B item 1(c): the audio watchdog must not close
                        // the device while the space is opening — the open
                        // re-anchors the session (setIntendedSpatialExperience
                        // below), and 1.0.1.21's direct reopen landed 0.25 s
                        // before the mode=vr flip and produced 141,292 queue
                        // failures. Raised BEFORE the re-anchor, dropped after
                        // the space is open or refused.
                        SohIos_SetVrTransition(1)
                        Soh3DSettingsView.applyAll() // panel state before first frame
                        SohVRSettingsView.applyAll() // VR tunables before first frame
                        sohStartAudioReanchor()
                        // VR-spec D1: which space opens is app logic; the
                        // Soh3D space's own declaration/configuration is never
                        // touched. Variant ids exist only for the R0a contract
                        // measurement.
                        let ids = ["SohVR", "SohVRTestA", "SohVRTestB"]
                        let spaceId = (SohVR_IsActive() != 0)
                            ? ids[max(0, min(2, Int(SohVR_SpaceVariant())))] : "Soh3D"
                        let r = await openImmersiveSpace(id: spaceId)
                        NSLog("[Soh3D] Swift: openImmersiveSpace(\(spaceId)) -> \(String(describing: r))")
                        // R17 part B item 2(a): the result of this call was
                        // NSLog-only, so a refused or errored open left NOTHING
                        // in a pull — which is one of the shapes a black entry
                        // could have had.
                        SohIos_VrNote("openImmersiveSpace", "\(spaceId) -> \(String(describing: r))")
                        if case .error = r {
                            Soh_Enter3D(false) // roll back engine offscreen mode
                        } else {
                            sohSetAudioFrontStage(true)
                        }
                        SohIos_SetVrTransition(0)
                    } else {
                        SohIos_SetVrTransition(1)
                        await dismissImmersiveSpace()
                        NSLog("[Soh3D] Swift: dismissed immersive")
                        SohIos_VrNote("dismissImmersiveSpace", "returned")
                        sohStopAudioReanchor()
                        sohSetAudioFrontStage(false)
                        // The window never deactivates under mixed immersion —
                        // this is the authoritative back-to-2D trigger.
                        Soh_Exit3DFinalize()
                        SohIos_SetVrTransition(0)
                    }
                }
            }
    }
}

@main
struct SohVisionApp: App {
    @ObservedObject private var model = SohAppModel.shared
    var body: some Scene {
        WindowGroup {
            SohRootView()
        }
        ImmersiveSpace(id: "Soh3D") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread; the frame loop must
                // NOT (it would block the engine's display-link pump).
                NSLog("[Soh3D] Swift: CompositorLayer ready — spawning render thread")
                // R17 part B item 2(c): REFUSE A SECOND LOOP. This closure runs
                // once per space activation, and it spawned a thread
                // unconditionally; Soh3D_Immersive_Run/SohVR_Immersive_Run then
                // set their running flags unconditionally too, so a re-entry
                // that raced the previous loop's teardown put two threads on one
                // layerRenderer with neither able to see the other. That is
                // ranked cause 3 of the black VR entry, and it is the cheapest
                // of the three to make impossible.
                if SohVR_AnyLoopRunning() != 0 {
                    NSLog("[Soh3D] Swift: REFUSED — an immersive loop is already running")
                    SohIos_VrNote("compositor layer refused", "Soh3D: a loop is already running")
                    return
                }
                let renderThread = Thread { Soh3D_Immersive_Run(layerRenderer) }
                renderThread.name = "Soh3D-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // Mixed = panel floats in passthrough. Merely ALLOWING .progressive
        // changes the drawable contract and encode_present aborts.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // --- VR spaces (VR-spec D1, round R0a) ---------------------------
        // Three SIBLING spaces, one per immersion-style SET, so the
        // style/present contract is MEASURED on this platform and SDK instead
        // of inherited. Adding spaces does not touch `Soh3D` above — the
        // sibling port's lesson was that WIDENING an existing space's style
        // set broke present, not that extra spaces are unsafe.
        ImmersiveSpace(id: "SohVR") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                NSLog("[SohVR] Swift: CompositorLayer ready (SohVR) — spawning render thread")
                if SohVR_AnyLoopRunning() != 0 {
                    NSLog("[SohVR] Swift: REFUSED — an immersive loop is already running")
                    SohIos_VrNote("compositor layer refused", "SohVR: a loop is already running")
                    return
                }
                SohIos_VrNote("compositor layer ready", "SohVR")
                let t = Thread { SohVR_Immersive_Run(layerRenderer) }
                t.name = "SohVR-Immersive"
                t.stackSize = 2 << 20
                t.start()
            }
        }
        // R7 verdict 1 (the user, 2026-09-04). The shipped VR space is FULL
        // immersion with the wearer's own upper limbs HIDDEN. Two separate
        // things, and both are needed: `.full` removes the passthrough ROOM,
        // `upperLimbVisibility(.hidden)` removes the wearer's own hands and
        // arms, which visionOS otherwise keeps punched through even under full
        // immersion. the user's 6.png/7.png show exactly that — his real hand and
        // his real Sense controller sitting inside the shot, with Link's shield
        // floating on top of them.
        //
        // The style is `.constant(.full)` in a ONE-MEMBER set. R0's measured
        // ruling was that a two-member set switched live keeps the drawable
        // contract byte-identical; a one-member set is strictly safer than
        // that, and it is what `Soh3D` has always used.
        //
        // R0's other ruling still holds and is what makes this safe: the parked
        // 2D window, its curtain and the ornament stay visible and interactive
        // under `.full`, so the Exit button is still reachable.
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.hidden)

        ImmersiveSpace(id: "SohVRTestA") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                NSLog("[SohVR] Swift: CompositorLayer ready (SohVRTestA/mixed) — spawning render thread")
                if SohVR_AnyLoopRunning() != 0 {
                    NSLog("[SohVR] Swift: REFUSED — an immersive loop is already running")
                    SohIos_VrNote("compositor layer refused", "SohVRTestA/mixed: a loop is already running")
                    return
                }
                let t = Thread { SohVR_Immersive_Run(layerRenderer) }
                t.name = "SohVR-Immersive"
                t.stackSize = 2 << 20
                t.start()
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        ImmersiveSpace(id: "SohVRTestB") {
            CompositorLayer(configuration: SohCompositorConfiguration()) { layerRenderer in
                NSLog("[SohVR] Swift: CompositorLayer ready (SohVRTestB/full) — spawning render thread")
                if SohVR_AnyLoopRunning() != 0 {
                    NSLog("[SohVR] Swift: REFUSED — an immersive loop is already running")
                    SohIos_VrNote("compositor layer refused", "SohVRTestB/full: a loop is already running")
                    return
                }
                let t = Thread { SohVR_Immersive_Run(layerRenderer) }
                t.name = "SohVR-Immersive"
                t.stackSize = 2 << 20
                t.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.hidden)
    }
}
