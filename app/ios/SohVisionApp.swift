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
struct Soh3DSettingsView: View {
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
        Form {
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
                    Button(model.immersive ? "Exit 3D" : "3D") {
                        Soh_Enter3D(!model.immersive)
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
            .sheet(isPresented: $model.showSettings) {
                VStack(spacing: 0) {
                    HStack {
                        Text("3D Screen Settings").font(.title3.weight(.semibold))
                        Spacer()
                        // Reset lives in the header row, aligned with the
                        // title — the convention across the ports.
                        Button("Reset") { Soh3DSettingsView.resetAll() }
                            .font(.title3)
                        Button("Done") { model.showSettings = false }
                            .font(.title3)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    Divider()
                    Soh3DSettingsView()
                }
                .frame(minWidth: 700)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[Soh3D] Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        Soh3DSettingsView.applyAll() // panel state before first frame
                        sohStartAudioReanchor()
                        let r = await openImmersiveSpace(id: "Soh3D")
                        NSLog("[Soh3D] Swift: openImmersiveSpace -> \(String(describing: r))")
                        if case .error = r {
                            Soh_Enter3D(false) // roll back engine offscreen mode
                        } else {
                            sohSetAudioFrontStage(true)
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[Soh3D] Swift: dismissed immersive")
                        sohStopAudioReanchor()
                        sohSetAudioFrontStage(false)
                        // The window never deactivates under mixed immersion —
                        // this is the authoritative back-to-2D trigger.
                        Soh_Exit3DFinalize()
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
                let renderThread = Thread { Soh3D_Immersive_Run(layerRenderer) }
                renderThread.name = "Soh3D-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // Mixed = panel floats in passthrough. Merely ALLOWING .progressive
        // changes the drawable contract and encode_present aborts.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
