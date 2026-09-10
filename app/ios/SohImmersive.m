// SohImmersive.m — visionOS stereoscopic "3D screen" render loop.
//
// Near-verbatim port of vkQuake-ios VKQImmersive.m (proven on this user's
// device), retargeted at SoH/Fast3D: the engine renders BOTH eyes per host
// frame into two offscreen Metal textures (Fast3D framebuffers, overlay-side);
// this loop composites them onto a world-locked quad — left texture to the
// left eye slice, right to the right — with the ARKit head pose placing the
// panel, never the aim.
//
// The loop shape is LOAD-BEARING (guide §2.3): frame pacing via
// cp_time_wait_until(optimal_input_time) + a per-frame ar device anchor set on
// the drawable + cleared/written depth + a command queue created from the
// drawable's own device + @autoreleasepool. Remove any one and the panel is
// black or the process aborts.

#import "SohImmersive.h"
#import "SohSense.h"
#import "SohVrPhys.h"
#import <AVFoundation/AVFoundation.h> // R3: `vr audio` reads the session state
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#include <signal.h>
#include <pthread.h> // R17 part B: the VR entry watchdog's own thread

volatile int gSoh3DStop = 0;
volatile int gSoh3DRunning = 0;
static int soh3d_frameCount = 0;

// --- world-lock math ---------------------------------------------------------
static simd_float4x4 soh3d_translate(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}
static simd_float4x4 soh3d_scale(float x, float y, float z) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x;
    m.columns[1].y = y;
    m.columns[2].z = z;
    return m;
}

// Panel placement: captured from the head pose once tracking converges, then
// world-locked; recomputed from the frozen head each frame so live tuning of
// distance/size moves the panel in real time.
static float soh3d_screenDist = 3.6f;  // metres from the captured head position
static float soh3d_screenHalfW = 2.75f;
static float soh3d_screenHalfH = 1.55f;
static float soh3d_screenHeight = 0.0f; // metres above eye level

void Soh3D_SetPanel(float dist, float halfW, float halfH) {
    if (dist >= 1.0f && dist <= 8.0f)
        soh3d_screenDist = dist;
    if (halfW >= 0.6f && halfW <= 4.0f)
        soh3d_screenHalfW = halfW;
    if (halfH >= 0.4f && halfH <= 3.0f)
        soh3d_screenHalfH = halfH;
}
void Soh3D_SetHeight(float h) {
    if (h >= -1.5f && h <= 10.0f)
        soh3d_screenHeight = h;
}

static bool soh3d_haveScreenAnchor = false;
static simd_float4x4 soh3d_frozenHead;

void Soh3D_Recenter(void) {
    soh3d_haveScreenAnchor = false; // next tracked frame re-captures the pose
}

// Surroundings dimming: fullscreen black layer under the panel. Perceptual
// curve 1-(1-d)^2.2 — linear "doesn't get dark until 80%" (vkQuake-measured).
static float soh3d_dimLevel = 0.0f;
void Soh3D_SetDim(float dim) {
    dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
    soh3d_dimLevel = 1.0f - powf(1.0f - dim, 2.2f);
}

static simd_float4x4 soh3d_make_screen_anchor(simd_float4x4 originFromDevice) {
    simd_float3 headPos = originFromDevice.columns[3].xyz;
    simd_float3 fwd = -originFromDevice.columns[2].xyz; // gaze forward
    fwd.y = 0.0f;                                       // level (no pitch/roll)
    float len = simd_length(fwd);
    fwd = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

    simd_float3 pos = headPos + fwd * soh3d_screenDist;
    pos.y += soh3d_screenHeight;
    simd_float3 normal = simd_normalize(headPos - pos);
    simd_float3 up = simd_make_float3(0, 1, 0);
    simd_float3 right = simd_normalize(simd_cross(up, normal));
    up = simd_cross(normal, right);

    simd_float4x4 m;
    m.columns[0] = simd_make_float4(right, 0.0f);
    m.columns[1] = simd_make_float4(up, 0.0f);
    m.columns[2] = simd_make_float4(normal, 0.0f);
    m.columns[3] = simd_make_float4(pos, 1.0f);
    return m;
}

// Persistent mipmapped per-eye sampling copies of the engine's eye textures.
static id<MTLTexture> soh3d_eyeCopy[2];

// Test pattern shown until the engine's eye framebuffers exist (M2 gate: the
// compositor path is verifiable in the sim before any Fast3D work lands).
static id<MTLTexture> soh3d_testPattern;
static id<MTLTexture> soh3d_make_test_pattern(id<MTLDevice> dev) {
    const int W = 640, H = 360, TILE = 40;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:W
                                                                                 height:H
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t* px = malloc(W * H * 4);
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            bool a = ((x / TILE) + (y / TILE)) & 1;
            // magenta/teal checker: unmistakably "test pattern", never "bug"
            px[y * W + x] = a ? 0xFFB4287D : 0xFF7DB428;
        }
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
    free(px);
    return t;
}

// One-shot fidelity report: measures the ACTUAL panel supersample ratio
// (drawable px/FOV vs panel angular size vs game texture) so resolution is a
// number, not a guess. Written to Documents/vp3d-fidelity.log (OTA-readable).
static bool soh3d_fidelityLogged = false;
static void soh3d_log_fidelity(cp_drawable_t drawable, id<MTLTexture> gameTex) {
    if (soh3d_fidelityLogged || gameTex == nil)
        return;
    cp_view_t view = cp_drawable_get_view(drawable, 0);
    MTLViewport vp = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
    simd_float4x4 proj = matrix_identity_float4x4;
    if (__builtin_available(visionOS 2.0, *))
        proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
    double m00 = fabs(proj.columns[0].x), m11 = fabs(proj.columns[1].y);
    double fovH = (m00 > 1e-6) ? 2.0 * atan(1.0 / m00) : 0.0;
    double fovV = (m11 > 1e-6) ? 2.0 * atan(1.0 / m11) : 0.0;
    if (vp.width < 1 || vp.height < 1 || fovH < 1e-4 || fovV < 1e-4)
        return;
    double pxPerRadH = vp.width / fovH, pxPerRadV = vp.height / fovV;
    double panAngH = 2.0 * atan(soh3d_screenHalfW / soh3d_screenDist);
    double panAngV = 2.0 * atan(soh3d_screenHalfH / soh3d_screenDist);
    double footH = panAngH * pxPerRadH, footV = panAngV * pxPerRadV;
    double ssH = footH > 1 ? gameTex.width / footH : 0.0;
    double ssV = footV > 1 ? gameTex.height / footV : 0.0;

    NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString* report = [NSString
        stringWithFormat:@"Ship of Harkinian Vision Pro 3D fidelity report\n"
                          "===============================================\n"
                          "Compositor drawable (per eye): %.0f x %.0f px\n"
                          "Per-eye FOV: %.1f x %.1f deg\n"
                          "Game render target (per eye): %lu x %lu px\n"
                          "Panel angular size: %.1f x %.1f deg\n"
                          "Panel footprint in drawable: %.0f x %.0f px\n"
                          "SUPERSAMPLE RATIO: %.2fx H, %.2fx V (%s)\n",
                         (double)vp.width, (double)vp.height, fovH * 180.0 / M_PI, fovV * 180.0 / M_PI,
                         (unsigned long)gameTex.width, (unsigned long)gameTex.height, panAngH * 180.0 / M_PI,
                         panAngV * 180.0 / M_PI, footH, footV, ssH, ssV,
                         (ssH >= 1.0 && ssV >= 1.0) ? "supersampling" : "UNDERSAMPLING"];
    [report writeToFile:[docs stringByAppendingPathComponent:@"vp3d-fidelity.log"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:NULL];
    NSLog(@"[Soh3D] fidelity: drawable %.0fx%.0f/eye game %lux%lu supersample %.2fx/%.2fx", (double)vp.width,
          (double)vp.height, (unsigned long)gameTex.width, (unsigned long)gameTex.height, ssH, ssV);
    soh3d_fidelityLogged = true;
}

// Panel quad + dim layer pipelines, compiled at runtime from drawable formats.
static id<MTLRenderPipelineState> soh3d_pipeline;
static id<MTLRenderPipelineState> soh3d_dimPipeline;
static id<MTLDepthStencilState> soh3d_depthState;
static id<MTLDepthStencilState> soh3d_dimDepthState;

static NSString* const kSoh3DQuadShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "vertex VOut soh3d_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 soh3d_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                         constant float& srgbDecode [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n"
     "vertex float4 soh3d_dim_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  return float4(p[vid], 0.9999, 1.0);\n"
     "}\n"
     "fragment float4 soh3d_dim_fs(constant float& dim [[buffer(0)]]) {\n"
     "  return float4(0.0, 0.0, 0.0, dim);\n"
     "}\n";

static void soh3d_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSoh3DQuadShader options:nil error:&err];
    if (!lib) {
        NSLog(@"[Soh3D] shader compile FAILED: %@", err.localizedDescription);
        return;
    }
    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"soh3d_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"soh3d_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    soh3d_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!soh3d_pipeline) {
        NSLog(@"[Soh3D] pipeline FAILED: %@", err.localizedDescription);
        return;
    }
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES; // compositor reprojects on depth; must be real
    soh3d_depthState = [dev newDepthStencilStateWithDescriptor:dd];

    MTLRenderPipelineDescriptor* dp = [MTLRenderPipelineDescriptor new];
    dp.vertexFunction = [lib newFunctionWithName:@"soh3d_dim_vs"];
    dp.fragmentFunction = [lib newFunctionWithName:@"soh3d_dim_fs"];
    dp.colorAttachments[0].pixelFormat = colorFmt;
    dp.colorAttachments[0].blendingEnabled = YES;
    dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    dp.depthAttachmentPixelFormat = depthFmt;
    soh3d_dimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
    if (!soh3d_dimPipeline)
        NSLog(@"[Soh3D] dim pipeline FAILED: %@", err.localizedDescription);
    MTLDepthStencilDescriptor* dd2 = [MTLDepthStencilDescriptor new];
    dd2.depthCompareFunction = MTLCompareFunctionAlways;
    dd2.depthWriteEnabled = YES;
    soh3d_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd2];
    NSLog(@"[Soh3D] quad pipeline built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt,
          (unsigned long)depthFmt);
}

// VR-spec D10: present-cadence observer, shared by BOTH compositor loops so
// `vr pace` is honest in the 3D panel space too. Pure observer — no rendering
// behaviour depends on it (see the SohVR section below for the definition).
static void sohvr_note_present(void);

void Soh3D_Immersive_Run(cp_layer_renderer_t layer_renderer) {
    gSoh3DStop = 0;
    gSoh3DRunning = 1;
    int notifyEnded = 0; // only a system/Crown dismissal reconciles via Ended

    id<MTLCommandQueue> queue = nil;
    soh3d_frameCount = 0;
    soh3d_haveScreenAnchor = false; // re-center each time 3D is entered
    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    soh3d_fidelityLogged = false;

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);

    NSLog(@"[Soh3D] render loop started (ARKit world tracking running)");

    int running = 1;
    while (running) {
        if (gSoh3DStop) {
            NSLog(@"[Soh3D] stop requested, exiting cleanly (frames=%d)", soh3d_frameCount);
            running = 0;
            continue;
        }
        switch (cp_layer_renderer_get_state(layer_renderer)) {
            case cp_layer_renderer_state_paused:
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[Soh3D] layer invalidated, exiting loop (frames=%d)", soh3d_frameCount);
                notifyEnded = 1;
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL)
                continue;

            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));

            cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                // A failed drawable query INVALIDATES the frame — calling
                // end_submission on it ABORTS (guide trap list; device crash
                // 2026-07-16: the window-parking geometry animation at entry
                // +1.5s makes the compositor skip a drawable). Just drop it.
                continue;
            }

            if (queue == nil) {
                id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
                queue = [t0.device newCommandQueue];
                soh3d_build_pipeline(t0.device, t0.pixelFormat,
                                     cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
                soh3d_testPattern = soh3d_make_test_pattern(t0.device);
                NSLog(@"[Soh3D] drawable %lux%lu views=%zu colorFmt=%lu", (unsigned long)t0.width,
                      (unsigned long)t0.height, cp_drawable_get_view_count(drawable),
                      (unsigned long)t0.pixelFormat);
            }

            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            cp_drawable_set_device_anchor(drawable, anchor);

            if (!soh3d_haveScreenAnchor && anchorStatus == ar_device_anchor_query_status_success &&
                soh3d_frameCount > 30) {
                soh3d_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
                soh3d_haveScreenAnchor = true;
                NSLog(@"[Soh3D] screen anchored at head (%.2f,%.2f,%.2f)", soh3d_frozenHead.columns[3].x,
                      soh3d_frozenHead.columns[3].y, soh3d_frozenHead.columns[3].z);
            }

            id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

            // Copy both per-eye engine textures into mipmapped sampling copies
            // (on THIS queue, so copy + sample are coherent). Falls back to the
            // test pattern until the engine's eye framebuffers exist.
            id<MTLTexture> monoTex = nil;
            for (int e = 0; e < 2; e++) {
                id<MTLTexture> src = (__bridge id<MTLTexture>)Soh3D_GetEyeMTLTexture(e + 1);
                if (!src)
                    continue;
                monoTex = src;
                if (soh3d_eyeCopy[e] == nil || soh3d_eyeCopy[e].width != src.width ||
                    soh3d_eyeCopy[e].height != src.height || soh3d_eyeCopy[e].pixelFormat != src.pixelFormat) {
                    MTLTextureDescriptor* td =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                           width:src.width
                                                                          height:src.height
                                                                       mipmapped:YES];
                    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
                    td.storageMode = MTLStorageModePrivate;
                    soh3d_eyeCopy[e] = [src.device newTextureWithDescriptor:td];
                }
                id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
                [blit copyFromTexture:src toTexture:soh3d_eyeCopy[e]];
                if (soh3d_eyeCopy[e].mipmapLevelCount > 1)
                    [blit generateMipmapsForTexture:soh3d_eyeCopy[e]];
                [blit endEncoding];
            }
            if (monoTex == nil)
                monoTex = soh3d_testPattern;

            id<MTLTexture> color = cp_drawable_get_color_texture(drawable, 0);
            id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, 0);
            size_t views = cp_drawable_get_view_count(drawable);

            simd_float4x4 placement = soh3d_haveScreenAnchor ? soh3d_make_screen_anchor(soh3d_frozenHead)
                                                             : soh3d_translate(0.0f, 0.0f, -soh3d_screenDist);
            simd_float4x4 model = simd_mul(placement, soh3d_scale(soh3d_screenHalfW, soh3d_screenHalfH, 1.0f));
            simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

            if (soh3d_haveScreenAnchor && soh3d_frameCount > 60)
                soh3d_log_fidelity(drawable, monoTex);

            float srgbDecode = 0.0f;
            {
                MTLPixelFormat sf = monoTex.pixelFormat, df = color.pixelFormat;
                BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
                BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB || df == MTLPixelFormatRGBA8Unorm_sRGB ||
                                  df == MTLPixelFormatRGBA16Float);
                srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
            }

            for (size_t v = 0; v < views; v++) {
                // D-036 rev3: fully layout-agnostic targeting via the view's
                // texture map (dedicated layout: texture per view, slice 0;
                // layered: texture 0, slice per view). With foveation each
                // DEDICATED view carries its own rate map, indexed by the
                // view's texture index — attaching the wrong eye's map is the
                // round-1 "right eye fisheye that moves with the head".
                cp_view_t soh3dView = cp_drawable_get_view(drawable, v);
                cp_view_texture_map_t soh3dTmap = cp_view_get_view_texture_map(soh3dView);
                size_t soh3dTexIdx = cp_view_texture_map_get_texture_index(soh3dTmap);
                size_t soh3dSlice = cp_view_texture_map_get_slice_index(soh3dTmap);
                MTLViewport soh3dVp = cp_view_texture_map_get_viewport(soh3dTmap);

                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, soh3dTexIdx);
                pass.colorAttachments[0].slice = soh3dSlice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                {
                    size_t soh3dRmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
                    if (soh3dRmCount > 0) {
                        pass.rasterizationRateMap = cp_drawable_get_rasterization_rate_map(
                            drawable, soh3dTexIdx < soh3dRmCount ? soh3dTexIdx : 0);
                    }
                }
                id<MTLTexture> soh3dDepthTex = cp_drawable_get_depth_texture(drawable, soh3dTexIdx);
                if (soh3dDepthTex) {
                    pass.depthAttachment.texture = soh3dDepthTex;
                    pass.depthAttachment.slice = soh3dSlice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 1.0;
                }
                // This eye's texture: its own stereo image if ready, else mono.
                id<MTLTexture> tex = (v < 2 && soh3d_eyeCopy[v]) ? soh3d_eyeCopy[v] : monoTex;

                id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
                // Foveation contract: rasterize in the view's LOGICAL viewport
                // (from the texture map); the rate map compresses to physical.
                [enc setViewport:soh3dVp];
                float dimNow = soh3d_dimLevel;
                if (dimNow > 0.003f && soh3d_dimPipeline) {
                    [enc setRenderPipelineState:soh3d_dimPipeline];
                    [enc setDepthStencilState:soh3d_dimDepthState];
                    [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                if (tex && soh3d_pipeline) {
                    cp_view_t view = cp_drawable_get_view(drawable, v);
                    simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                    simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));
                    simd_float4x4 proj = matrix_identity_float4x4;
                    if (__builtin_available(visionOS 2.0, *))
                        proj = cp_drawable_compute_projection(drawable,
                                                              cp_axis_direction_convention_right_up_back, v);
                    simd_float4x4 mvp = simd_mul(proj, simd_mul(eyeFromOrigin, model));

                    [enc setRenderPipelineState:soh3d_pipeline];
                    [enc setDepthStencilState:soh3d_depthState];
                    [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                    [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                    [enc setFragmentTexture:tex atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
                [enc endEncoding];
            }

            cp_drawable_encode_present(drawable, command_buffer);
            [command_buffer commit];
            sohvr_note_present(); // D10 observer only

            soh3d_frameCount++;
            if (soh3d_frameCount == 3 || (soh3d_frameCount % 600) == 0)
                NSLog(@"[Soh3D] frame %d — source %lux%lu eyeL=%d eyeR=%d framesL=%d framesR=%d srgbDecode=%.0f",
                      soh3d_frameCount, (unsigned long)monoTex.width, (unsigned long)monoTex.height,
                      (int)(soh3d_eyeCopy[0] != nil), (int)(soh3d_eyeCopy[1] != nil), Soh3D_GetEyeFrames(1),
                      Soh3D_GetEyeFrames(2), srgbDecode);

            cp_frame_end_submission(frame);
        }
    }

    soh3d_eyeCopy[0] = soh3d_eyeCopy[1] = nil;
    soh3d_testPattern = nil;
    if (notifyEnded)
        Soh3D_Immersive_Ended();
    gSoh3DRunning = 0; // signal the shell LAST, after cleanup
}

// =============================================================================
// SohVR — VR mode (VR-spec D1/D2/D10, round R0)
// =============================================================================
//
// A SECOND immersive space beside the shipped `Soh3D` panel space. `Soh3D` and
// its configuration are never touched (spec D1). Three space ids are
// declared so R0a can measure the immersion-style/present contract on THIS
// platform and SDK rather than inheriting the sibling port's answer:
//
//   SohVR      .immersionStyle(selection: $style, in: .mixed, .full)  (candidate)
//   SohVRTestA .immersionStyle(.constant(.mixed), in: .mixed)
//   SohVRTestB .immersionStyle(.constant(.full),  in: .full)
//
// All three run THIS loop. Two loop variants (spec R0 a/b):
//   world=0 — clear each eye's slice to a distinct solid colour (the pure
//             space/present contract test; nothing engine-side is involved).
//   world=1 — full-slice blit of the engine's per-eye Fast3D framebuffers,
//             which overlay 0031 rev12 renders with the A.V.P matrix this
//             file composes and publishes.
//
// Eye math (spec D2), all row/column conventions stated explicitly because
// getting one wrong is the classic silent VR bug:
//   * Tracking space and the N64 game frame are BOTH right-handed, Y-up,
//     -Z-forward (VR-DONOR-MAP §3b). There is NO axis flip anywhere; the only
//     conversion is the scalar world scale in game units per metre.
//   * A — game-space placement: anchor (game units) + base yaw gamma. R0 seats
//     the anchor on 0032's exported camera eye and gamma on its forward, so
//     the frozen-pose image is "the stock game in stereo" and therefore
//     recognisable.
//   * V — inverse of the eye's game-space pose. The eye pose comes from
//     origin_from_anchor x cp_view_get_transform, with the TRANSLATION scaled
//     metres -> game units.
//   * P — asymmetric frustum TANGENTS recovered exactly from
//     cp_drawable_compute_projection, with the depth mapping rebuilt FORWARD-Z
//     in game units (see sohvr_classify_depth: the compositor's own matrix is
//     reverse-Z with an infinite far plane, and Fast3D clears depth to 1.0 and
//     tests Less — handing the compositor's matrix straight to the engine
//     would sort the world back to front).
//   * Published as gSohVREyeVP in Fast3D ROW-VECTOR order.

#import <UIKit/UIKit.h>

extern volatile float gSoh3DCamDist, gSoh3DCamP00;
extern volatile float gSoh3DCamRight[3], gSoh3DCamFwd[3], gSoh3DCamEye[3];
extern volatile int gSoh3DPaused, gSoh3DInPlay, gSoh3DAiming;
extern volatile int gSoh3DEyeW, gSoh3DEyeH;
extern volatile int gSoh3DMode;
extern volatile int gSoh3DEyeFrames[2];
extern volatile float gSohIosGpuMs;
extern volatile int gSohVRMode;
extern volatile int gSohVREyeVPValid;
extern volatile float gSohVREyeVP[2][2][16]; // [slot][eye][row-major 4x4]
extern volatile float gSohVREyeTan[2][4]; // R19 part B: [eye][L,R,B,T]
extern volatile unsigned int gSohVRPoseSeq, gSohVREyeSeqDone;
extern volatile int gSohVRPairSlot, gSohVRPairFlat;
extern volatile int gSohVRAnchorValid;
extern volatile float gSohVRAnchorEye[3], gSohVRAnchorFwd[3];
extern volatile int gSohVRCamValid;
extern volatile float gSohVRCamEye[3], gSohVRCamFwd[3], gSohVRCamUp[3], gSohVRCamFovy;
extern volatile int gSohVRFlatLatch, gSohVRFlatRaw;
extern volatile int gSohVRRefreshHz;
// R2a (device round): the PAIR tag. The engine stamps every published eye
// texture with the pose seq its display list was walked for (0031 rev14), and
// the shell presents two eyes only when their tags MATCH. Trap D35 from the
// sibling: two eye textures are not a stereo frame, a PAIR is — the eyes are
// published by independent per-eye GPU completion handlers, so without the tag
// the compositor can hold eye 0 from host frame N and eye 1 from N-1, which
// submits ONE device anchor for two different head poses. That is diplopia
// that no amount of correct projection math can fix, and it is the leading
// candidate for the user's "everything is doubled" on 1.0.1.1.
extern volatile unsigned int gSohVRPairTag;
extern volatile unsigned int gSoh3DEyeTag[3];
// Snapshot BOTH eyes' textures, depths and tags under the engine's publish
// mutex — reading gSoh3DEyeTexture[0] and [1] separately is exactly the torn
// read the tag exists to detect (0031 rev14 defines it in gfx_metal.cpp).
extern void Soh3DEyePairSnapshot(void** tex, void** depth, unsigned int* tag);
// R2a (spec D3 extension): how VR treats a pre-rendered (image-backed)
// room. 0 = panel (the whole room is a flat-screen context on the world-locked
// panel — the authored art, shown as authored), 1 = flat (the backdrop is
// drawn per eye, head-glued), 2 = 3d (SoH's 3DSceneRender enhancement, which
// needs a 3D-backdrop MOD installed or you get the bare placeholder mesh —
// the user's all-green Link's house). Read by overlay 0039 rev2 and 0040 rev2.
extern volatile int gSohVRRoomMode;
extern volatile int gSohVRRoomImage; // diagnostics: the live room-shape test
extern volatile int gSohVRRoomFixedCam; // R16b: the fixed-camera arm of the latch
// --- R2b -----------------------------------------------------------------------
// FIRST PERSON (spec D4, overlay 0041): the anchor the engine computes once
// per tick from Link's actor ROOT plus eye height, and the state that goes with
// it. Third person is NOT a VR mode any more (the user, 2026-09-03: "we are not
// going to need 3rd person mode since we have our 3d stereo mode") — the 3D
// PANEL mode is the third-person experience. What survives is the donor's
// automatic far-camera fallback, which seats on the game camera when the
// director's camera is more than gSohVRFpFallbackDist away; there is no setting
// that reaches it.
extern volatile int gSohVRFpActive, gSohVRFpFar, gSohVRFpEntered, gSohVRFpResumed;
extern volatile float gSohVRFpAnchor[3];
extern volatile float gSohVRFpEyeHeight;
extern volatile int gSohVRFpBodyYaw;
extern volatile float gSohVRHeadHeightOffset, gSohVRHeadOffsetFwd, gSohVRFpFallbackDist;
// STEERING (spec D6, overlay 0042) + snap turn.
extern volatile int gSohVRHeadingValid, gSohVRHeadingYaw;
extern volatile float gSohVRTurnAxis;
extern volatile int gSohVRHideBody, gSohVRBodyFollowsHead;
// R8 item 8: the forward roll, published by overlay 0042 rev6 beside the hop.
extern volatile int gSohVRRollActive;
extern volatile float gSohVRRollSeconds;
extern volatile int gSohVRPinnedYaw, gSohVRDirectTicks, gSohVRKinematicTicks;
extern volatile int gSohVRPadCur, gSohVRPadCMasked;
// R7 verdict 9: the crash-capture reporter in SohIosShell.m. Not fatal by
// itself -- it records a NAMED context that survives into whatever kills us.
extern void SohIos_ReportFatalContext(const char* kind, const char* detail);
extern long SohIos_AvailableMemoryMB(void);
// HUD PLANE (spec D7, overlays 0043 + 0031 rev15).
extern volatile int gSohVRHudPlane;
extern void* volatile gSohVROverlayDL;
extern volatile int gSohVRHudW, gSohVRHudH, gSohVRHudFrames;
extern volatile int gSohVRHudDLRaces;
extern void Soh3DHudSnapshot(void** tex, unsigned int* tag);
// Diagnostics: the active camera's setting (overlay 0037 rev2).
extern volatile int gSohVRCamSetting;
extern int Soh_Get3DMode(void);
// Engine pacing (overlay 0008 rev5): rolling 1 s windows.
extern void SohIos_PacingStats(float* fps, float* tps);

// --- R4: MOTION HANDS (VR-DONOR-MAP 3 "Link's body" + 8) ---------------------
// The two hand matrices, published in the SAME double-buffered slot and under
// the SAME pose seq as the eye VPs, so the hands and both eyes are always the
// same instant of the same pose. That identity is the whole reason the slot
// machinery exists: a hand latched from a different pose than the eye it is
// seen through swims, and swimming hands are the one artefact that reads as
// "these are not my hands".
//
// Row-vector order, like gSohVREyeVP and like OoT's own MtxF: out[i*4+j] =
// m.columns[i][j]. Game units, seated on the same anchor as the head.
extern volatile int gSohVRHandValid[2];
extern volatile float gSohVRHandMat[2][2][16]; // [slot][hand][row-major 4x4]
// R7 verdict 8: the skybox's own per-eye matrix. Same slot, same pair tag, same
// lifetime as gSohVREyeVP -- overlay 0031's VR branch picks between them on
// overlay 0033's skybox sentinel.
extern volatile float gSohVRSkyVP[2][2][16];
// R11 verdict 1: what overlay 0031 dropped (the interpolated game-camera
// translation the game wrote into the skybox model matrix), how often, and the
// FINAL composed MVP of the last skybox draw. `vr sky` projects a canonical
// sphere vertex through that MVP, so the "it cannot pulsate" claim is read off
// the shipped path instead of rebuilt beside it.
extern volatile float gSohVRSkyMDrop[3];
extern volatile unsigned int gSohVRSkyDrops;
extern volatile float gSohVRSkyMP[16];
// R7 verdict 6: the right-grip C-button chord, published by overlay 0039 rev7.
extern volatile int gSohVRGripChord;
// R7 verdict 5: vanilla lock-on engaged, and which lock-on hop is in progress
// (-1 none, 0 fwd, 1 left, 2 BACKFLIP, 3 right) -- published by overlay 0042 rev5.
extern volatile int gSohVRZTarget;
extern volatile int gSohVRHopKind;
extern volatile int gSohVRAuthoredSuppressed;
extern volatile int gSohVRStabTicks, gSohVRStabs, gSohVRStabQuads;
// R8 part B: the Z-target overhead chop, and the shield crouch.
extern volatile int gSohVRChopTicks, gSohVRChops;
// R19 item 1: the Megaton hammer's swing count and vanilla's own ground hit.
extern volatile int gSohVRHammers, gSohVRHammerHits;
extern volatile float gSohVRHammerProbe;
extern volatile int gSohVRCrouch;
extern volatile int gSohVRMotionCovered, gSohVRVanillaQuadsSkipped, gSohVRCoverDrops;
// R9 part B: the shield stance's stops, the swing-setter shim's count, the
// refused vanilla jump slashes, Link's own speed/position/melee animation, and
// the ocarina profile (with its harness override).
extern volatile int gSohVRShieldStops, gSohVRSwingSfx, gSohVRJumpSlashVanilla, gSohVRChopYells;
extern volatile int gSohVRShieldStanceForce;
extern volatile float gSohVRLinkVel;
extern volatile float gSohVRLinkPos[3];
extern volatile int gSohVRMeleeAnim;
extern volatile int gSohVROcarinaOut, gSohVROcarinaForce;
// The settings the limb override reads (donor gVrMotionHands, gVrLeftHanded,
// gVrHandMirrorSword, gVrHandMirrorShield).
extern volatile int gSohVRMotionHands, gSohVRLeftHanded;
extern volatile int gSohVRHandMirrorSword, gSohVRHandMirrorShield;
// The swing detector's output, per hand. gSohVRSwingSeq bumps ONCE per rising
// edge into the HOT tier; the game side compares it against its own last-seen
// value at the 20 Hz tick, which is what makes "one swing, one attack" true
// across a 90/120 Hz producer and a 20 Hz consumer.
extern volatile unsigned int gSohVRSwingSeq[2];
extern volatile float gSohVRSwingSpeed[2], gSohVRSwingMid[2], gSohVRSwingHand[2];
extern volatile int gSohVRSwingJump[2], gSohVRSwingTier[2];
// The six-input taxonomy, merged into the ONE pad snapshot by overlay 0047.
extern volatile int gSohVRSenseActive;
extern volatile unsigned int gSohVRSenseBtn[2];
extern volatile float gSohVRSenseStickX[2], gSohVRSenseStickY[2];
// R6: the Alyx item compass (overlay 0051).
extern volatile int gSohVRItemSel, gSohVRItemSelHandCfg, gSohVRItemSelOpen, gSohVRItemSelHand;
extern volatile int gSohVRItemSelSector, gSohVRItemSelOpens, gSohVRItemSelPicks, gSohVRItemSelDraws;
extern volatile int gSohVRItemSelCalls, gSohVRItemSelAvail;
extern volatile unsigned int gSohVRItemSelBtnSeen;
extern volatile unsigned int gSohVRItemSelBtn, gSohVRItemSelTickSeq;
extern volatile float gSohVRItemSelDistCm, gSohVRWorldScale;
// R18 part C: the wheel's 3D get-item models (D-070).
extern volatile int gSohVRWheel3D, gSohVRItemSelModels;
extern volatile float gSohVRWheelScale;
// R19 part B: 0 none / 1 ring / 2 glow for the selected slot (D-073).
extern volatile int gSohVRWheelHalo;
// R18 part B: the Lens of Truth in VR (overlay 0055, D-071).
extern volatile int gSohVRLensZFar, gSohVRLensDraws, gSohVRLensPasses;
extern volatile float gSohVRLensTint, gSohVRLensScale;
// R19 part B: the mask as a head-locked WORLD quad (overlay 0055 rev2, D-073).
extern volatile int gSohVRLensWorld;
extern volatile float gSohVRLensDist;
// The interface handshake (SohVrPhys.h): the game side refuses to run motion
// combat unless the number it was compiled against is the number we report.
extern volatile int gSohVRPhysVersion;
// Game-side diagnostics: limb pins performed, swings acted on, the N64 bits the
// Sense layer OR'd in, and the item-trigger reservation.
extern volatile int gSohVRHandPins, gSohVRSwingsTaken, gSohVRSensePadBits;

// --- R5: the physical blade (see SohIosShell.m for what each of these is) ---
extern volatile int gSohVRBladeDamage;
extern volatile int gSohVRMeshCount;
extern volatile float gSohVRMeshTri[32][9];
extern volatile int gSohVRMeshId[32];
extern volatile int gSohVRMeshShape[32];
extern volatile float gSohVRMeshRadius[32];
extern volatile unsigned int gSohVRMeshSeq;
extern volatile int gSohVRBladeValid[2];
extern volatile float gSohVRBladeLine[2][2][12];
extern volatile unsigned int gSohVRContactSeq;
extern volatile float gSohVRContactPos[8][3];
extern volatile float gSohVRContactNrm[8][3];
extern volatile float gSohVRContactImpact[8];
extern volatile int gSohVRContactHand[8];
extern volatile int gSohVRContactId[8];
extern volatile unsigned int gSohVRBladeHitSeq[2];
extern volatile int gSohVRBladeQuads, gSohVRBladeHits, gSohVRBladeTris, gSohVRBladeStrikes, gSohVRBladeContacts;
extern volatile int gSohVRBladeDyna, gSohVRBladeBodies;
extern volatile int gSohVRShieldPhysical;
extern volatile float gSohVRShieldQuad[9];
extern volatile float gSohVRShieldFacingDeg;
extern volatile int gSohVRShieldHeld, gSohVRShieldVetoes, gSohVRShieldBlocks;
extern volatile int gSohVRHandLive, gSohVRHandLiveHits, gSohVRHandLiveSearch;
extern volatile int gSohVRHandMtxTag;
extern volatile int gSohVRHandMtxClearReq;
extern volatile int gSohVRHandMtxCount[2];
extern volatile int gSohVRHandRecValid[2];
extern volatile int gSohVRHeldAction, gSohVRBItem;
extern volatile unsigned short gSohVRItemTriggerMask[2];
extern volatile int gSohVRItemTriggerBoth;      /* R18 item 2 */
extern volatile unsigned int gSohVREquipNoUse;  /* R18 item 1 */
// R12 item 4: the per-item hand correction (SohIosShell.m).
extern volatile int gSohVRItemCal;
extern volatile float gSohVRItemRotDeg[SOHVR_ITEMCAL_N][2][3];
extern volatile float gSohVRItemOffU[SOHVR_ITEMCAL_N][2][3];
extern volatile int gSohVRHeldModel[2];
// R12 item 6 (Q-VR26): the harness's one-shot "put a sword on B".
extern volatile int gSohVRForceSword;
extern volatile int gSohVRForcedSwords;
// R13 (Q-VR28): the aim. Reasoning beside gSohVRAim in SohIosShell.m.
#define SOHVR_AIMFRAME_N 2
extern volatile int gSohVRAim;
extern volatile int gSohVRAimFrame;
// R15: the controller's own aim ray, published by the hand loop below.
extern volatile int gSohVRAimRayValid[2];
extern volatile float gSohVRAimRayDir[2][3];
extern volatile float gSohVRAimRayOrg[2][3];
extern volatile float gSohVRAimRayAxis[3];
extern volatile int gSohVRAimReticle;
extern volatile float gSohVRAimReticleRange;
// R16 item 2 / item 4: the boomerang's direct throw, and the body-yaw snap the
// game publishes when it choreographs Link's facing (ladder, ledge, hang).
extern volatile int gSohVRBoomDirect;
extern volatile unsigned int gSohVRBoomDirectThrows;
extern volatile int gSohVRBodyYawSnapDelta;
extern volatile int gSohVRBodyYawSnapSeq;
// R16 item 4: the shell's half. `vr set ladderfollow 0|1`, default 1.
static volatile int sohvr_ladderFollow = 1;
static int sohvr_ladderSeqSeen = 0;
static int sohvr_ladderLastDelta = 0;
static float sohvr_ladderRemain = 0.0f;   // radians still owed to turnYaw
static float sohvr_ladderT = 0.0f;        // seconds left in the ease
static unsigned long long sohvr_ladderFollows = 0;
static int sohvr_aimRaySrc[2] = { -1, -1 };
extern volatile int gSohVRAimHandFixOn;
extern volatile float gSohVRAimSpawnU;
// R14: the trims are per item and per configuration now -- one writer, one
// table, shared by `vr set aimyaw/aimpitch` and the settings sliders.
extern volatile float gSohVRAimTrimDeg[SOHVR_AIMTRIM_N][2][2];
// R17 item 4: the row the aim last read (mesh slot, or the slingshot's).
extern volatile int gSohVRAimTrimRow;
// R17 item 2: the crosshair's size multiplier. 0.5 = half vanilla's.
extern volatile float gSohVRAimReticleScale;
extern volatile float gSohVRAimHandFix[2][9];
extern volatile int gSohVRAimPath;
extern volatile unsigned int gSohVRAimShots;
extern volatile unsigned int gSohVRAimVanillaShots;
extern volatile float gSohVRAimAxis[SOHVR_ITEMCAL_N][3];
extern volatile int gSohVRAimValid[2];
extern volatile float gSohVRAimBasis[2][SOHVR_AIMFRAME_N][9];
extern volatile float gSohVRAimOrigin[2][3];
extern volatile float gSohVRAimDirW[3];
extern volatile float gSohVRAimFwdW[3];
extern volatile float gSohVRAimPosW[3];
extern volatile int gSohVRAimModel;
extern volatile int gSohVRAimHandUsed;
extern volatile int gSohVRAimSite;
extern volatile unsigned int gSohVRAimHits;
const char* SohVR_ItemCalLabel(int model);

volatile int gSohVRStop = 0;
volatile int gSohVRRunning = 0;

// --- tunables (live on the bridge: `vr set ...`) ------------------------------
// R8 item 4 (the user, on 1.0.1.10): 34 game units per metre, HARDCODED. It was
// a slider seeded at the donor's 35; he dialled it in the headset and it is a
// measurement of how big Hyrule is, not a preference, so it is frozen the way
// the hand calibration is. Three places have to agree -- here, gSohVRWorldScale
// in SohIosShell.m (the compass's cm-of-hand-travel maths), and the Swift
// default that no longer exists because the setting is gone. `vr set scale`
// survives for experiments and does NOT persist: nothing writes it back.
static float sohvr_scale = 34.0f;     // game units per metre (R8 item 4, the user)
static unsigned int sohvr_itemSelTickSeen = 0; // R6: compass haptic edge
// R8 item 5: ONE height knob, and it is a TRIM. Entering VR (and every
// first-person re-entry) CALIBRATES: the room origin is seated on the live
// head so the wearer's eyes land exactly at Link's eye height, and that state
// is 0.0. This is the signed offset in metres from there.
static float sohvr_height = 0.0f;     // metres added to the anchor (the trim)
static float sohvr_near = 10.0f;      // game units
static float sohvr_far = 30000.0f;    // game units
static int sohvr_worldMode = 1;       // 1 = blit engine eyes, 0 = clear to colour
static int sohvr_variant = 0;         // 0 SohVR / 1 SohVRTestA / 2 SohVRTestB
// R7 verdict 1 (the user, 2026-09-04): VR is FULL immersion, always, with the
// wearer's own upper limbs hidden. This is no longer a live choice — it is a
// constant that exists so `vr mode` can ASSERT the style rather than assume it.
static int sohvr_styleFull = 1;       // always full (R7 verdict 1)
// R1: pose-rendezvous budget. The compositor publishes a pose, then waits this
// long for the engine to render BOTH eyes from it before presenting. Bounded on
// purpose — a missed rendezvous costs one reprojected frame, a blocking one
// costs the whole cadence.
// 10 ms measured (MEASUREMENTS.md, R1 sweep at 60 Hz in the sim): 2 ms buys a
// 1.5% hit rate, 6 ms 13.8%, 10 ms 36.3%, 14 ms 67.9% — and present_hz stayed
// 60.0 and tick_tps 20.2 at every one of them, because the wait sits before a
// 0.05 ms blit. 10 ms is half a 60 Hz frame: a real improvement over 6 without
// betting the whole budget on a phase relationship nothing enforces. The
// rendering-deadline clamp below is what actually protects the cadence.
static float sohvr_rendezvousMs = 10.0f;
// R1: draw the frozen world behind the flat-context panel (spec D3). The
// world content is stale AND the drawable carries the LIVE anchor (the panel
// must be world-locked), so the backdrop is head-locked while it is up — which
// is why it is dimmed with the user's own surroundings dim. Tunable so the
// headset verdict can turn it off outright.
static int sohvr_flatWorldBackdrop = 1;

// --- R2a: hosting the engine under a 120 Hz compositor (spec D8) ----------
// R1 made GetInterpolationFPS() return the MEASURED headset refresh (overlay
// 0015 rev3). In the simulator that is 60 and everything held. The DEVICE
// compositor presents at 120.02 Hz (the sibling's first device round measured
// exactly that, VR-R6-DEVICE-EVIDENCE §2), so the same code asks OoT for a
// full interpolated display-list walk every 8.3 ms — twice, once per eye. It
// cannot: the 1.0.1.1 device log lands at fps~113 with sim_tps 18.8-19.4
// instead of 20.00, i.e. the game runs ~6% slow and the rendezvous phase
// wanders, which is what a head turn reads as stutter.
//
// The fix is a DIVISOR, not a constant: the engine is hosted at
// present_hz / hostdiv, and the alternate compositor frames re-present the
// previous coherent pair against THAT pair's own anchor (the loop already
// does exactly this on a rendezvous miss, and the compositor reprojects it).
// 0 = auto, which picks the smallest divisor that puts the engine at or below
// 60 fps: 120 -> 2, 90 -> 2 (45), 60 -> 1. `vr set hostdiv N` forces it for
// the headset session; `vr pace` reports what is actually in force.
static int sohvr_hostDiv = 0;    // 0 = auto
static int sohvr_hostDivEff = 1; // what auto (or the override) resolved to
static int sohvr_engineHz = 0;   // the cadence published as gSohVRRefreshHz

// --- R2a: eye framebuffer sizing (spec D8 contingency ladder) -------------
// gSoh3DEyeW/H were never set by the VR loop, so the engine used its 3840x2160
// default: 8.3 Mpix per eye, 16.6 Mpix per host frame, at an aspect (1.78)
// that does not even match the device's per-eye viewport (5087x4081 = 1.246).
// The blit is a fullscreen triangle, so a mismatched aspect stretches the
// image anisotropically in BOTH eyes — the projection is built from the real
// tangents, so the render target must carry the real tangent aspect too.
// Derive the eye extent from the drawable's own viewport (trap D7: eye extents
// are their own sizing domain), clamped to a long-edge BUDGET and multiplied
// by a user render scale. Budget 2048 by default -> 2048x1643 on device, which
// is 3.4 Mpix per eye instead of 20.8. Raise it in the headset once the
// pacing is measured; a fraction of an extent that turns out to be 5087 is how
// the sibling got a 22 fps engine.
// R2b: 4096. the user's device A/B at 1.0.1.2 raised the budget live to 4096
// (eye fb 4096x3284, 13.4 Mpix/eye) and the engine held engine_fps=60.3,
// tick_tps=20.1, gpu_ms=1.9 — 2048 he called grainy. Measured, not guessed.
// R3: BACK TO 2048 AS THE BOOT DEFAULT, 4096 kept as the live setting. That A/B
// was a mid-session raise with the buffers already warm, no HUD framebuffers and
// a 3-slot vertex pool; it measured fps and says nothing about memory. Adopting
// 4096 on the FIRST compositor frame instead allocates ~431 MB of eye colour +
// depth (two eyes, ping-ponged) on top of R2b's two new HUD framebuffers and its
// 8-slot vertex pool — a ~375 MB step taken exactly while the audio session is
// being re-anchored on immersive entry. That is the leading explanation for
// 1.0.1.3's silence (overlay 0044), and a grainier default is the right side to
// fail on until the headset says otherwise.
static double sohvr_eyeBudget = 4096.0;
static float sohvr_eyeScale = 1.0f;
static int sohvr_eyeClamped = 0;
// R2b (scope F, the rainbow polygons): the eye extent is LATCHED for the
// session. R2a recomputed it from the drawable every compositor frame, so any
// change the compositor makes to its per-eye viewport — which is exactly what
// gaze moving onto a system window such as the Mac Virtual Display can do —
// reallocated the engine's render targets underneath a pair that was already
// half-walked. Now a changed extent must persist for kSohVRSizeHold frames
// before it is adopted, and it is never adopted while a pair is in flight.
#define SOHVR_SIZE_HOLD 120
static int sohvr_eyeWWant = 0, sohvr_eyeHWant = 0, sohvr_eyeWantHeld = 0;
static uint64_t sohvr_fbReallocs = 0;
// Contract-change counters (scope F): what actually moves while the user is
// looking at the MVD. Read with `vr contract`.
static uint64_t sohvr_vpChanges = 0, sohvr_tanChanges = 0, sohvr_ratemapChanges = 0;
static uint64_t sohvr_contractMismatch = 0;
static double sohvr_lastVpW = 0, sohvr_lastVpH = 0;
static float sohvr_lastTan[2][4];
static size_t sohvr_lastRatemaps = (size_t)-1;
static int sohvr_contractSeen = 0;

// --- R2b: the HUD plane (spec D7) -----------------------------------------
// OoT's interface is TEXRECT output: screen-space vertices that never touch the
// projection, so both eyes get the SAME PIXELS and, under the device's
// asymmetric frusta, the same pixels are NOT the same direction. Overlay 0043
// routes the overlay display list out of the world list and 0031 rev15 renders
// it once into its own transparent framebuffer; here it is drawn as a FLAT
// PLANE fixed in player space, with each eye's own projection, so it has real
// disparity and fuses. Flat plane, never floating 3D text (spec D7, the
// sm64 diplopia lesson).
// R8 item 7 (the user): the HUD has TWO settings, Height and Size. The distance
// is FIXED at 2.0 m -- its slider and its persisted key are gone. `vr set
// huddist` stays as an experiment knob and does not persist.
static float sohvr_hudDist = 2.0f;  // metres — FIXED (R8 item 7)
// R9 part A item 3 (the user, on 1.0.1.12): the HUD ships 3.0 m wide. Changed in
// ALL FOUR places that must agree -- this static, the @AppStorage default, the
// reset, and applyAll's dd() fallback -- so a fresh install and a Reset give
// the same number.
static float sohvr_hudWidth = 3.0f; // metres wide; height follows the 4:3 fb
static float sohvr_hudUp = 0.0f;    // metres above eye level
// R7 verdict 7: the luminance-key gain, applied above a 6% knee (see the
// shader). 20 takes a texel from the knee to fully opaque over another 5% of
// range, so an icon's body is solid while a glyph's antialiased edge keeps its
// softness. 0 disables the key entirely (the pre-R7 alpha-only path) and is the
// A/B for the engine-side alpha-coverage fix when it lands.
static float sohvr_hudKeyGain = 20.0f;
static id<MTLTexture> sohvr_hudTex;
static unsigned int sohvr_hudTag = 0;
static uint64_t sohvr_hudPresents = 0;

// --- R2b/R3: comfort / movement (spec D4/D6, DONOR-MAP §4c) ----------------
// ONE turn primitive, two styles. sohvr_turnDeg is the single user knob: 0 means
// SMOOTH (the default, and the leftmost stop of the settings slider), any other
// value is the snap angle in degrees. the user, 2026-09-03: "SMOOTH should be an
// option instead of snap turning (all the way to the left of the slider should
// be SMOOTH) and smooth turning should be the default."
// Both styles run HERE, on the loop thread, off the level overlay 0041 rev2
// publishes — the game latches nothing, so a turn can never touch the pad.
static float sohvr_turnDeg = 0.0f;         // 0 = smooth; else snap degrees
static float sohvr_smoothDegPerSec = 120.f; // donor gVrSmoothTurnSpeed
static int sohvr_snapArmed = 0;            // the ONE edge detector
static uint64_t sohvr_snapTurns = 0;
static double sohvr_turnDegTotal = 0.0;    // smooth degrees turned, for `vr fp`
static double sohvr_turnLastT = 0.0;       // for a real dt
static int sohvr_fpEnteredSeen = 0; // last consumed gSohVRFpEntered
static int sohvr_fpResumedSeen = 0; // last consumed gSohVRFpResumed (R16b)
static int sohvr_fpSeated = 0;      // the seat actually used first person

// --- R2a: eye-pair coherence bookkeeping (trap D35) --------------------------
// The presented pair, its tag, and the count of snapshots whose two eyes did
// NOT agree. A split is not presented: the last coherent pair is re-presented
// against its own anchor instead, so the invariant "both presented eyes carry
// the same pose seq, always" holds even through a miss.
static id<MTLTexture> sohvr_pairTex[2];
static id<MTLTexture> sohvr_pairDepth[2];
static unsigned int sohvr_pairTag = 0;
static uint64_t sohvr_pairSplits = 0;   // tagL != tagR at snapshot time
static uint64_t sohvr_pairAccepts = 0;  // a NEW coherent pair was adopted
static uint64_t sohvr_pairRepeats = 0;  // the previous pair was re-presented
static unsigned int sohvr_pairAgeMax = 0;
// The anchor each pose seq was published with, so a re-presented pair can be
// submitted against the anchor it was actually RENDERED for.
// 32 entries is 0.27 s at 120 Hz. It has to outlive the engine's whole
// publication latency (encode + GPU completion + the divisor), which at
// hostdiv 2 on a 120 Hz compositor is several frames — an anchor that has
// aged out silently falls back to the live one, and a stale pair on a LIVE
// anchor is exactly the swim this mechanism exists to prevent.
#define SOHVR_ANCHOR_RING 32
static ar_device_anchor_t sohvr_anchorRing[SOHVR_ANCHOR_RING];
static unsigned int sohvr_anchorRingSeq[SOHVR_ANCHOR_RING];

// --- synthetic pose injection (spec D10) -----------------------------------
// The simulator's CompositorServices reports views=1 with an identity view
// transform, so a stereo assertion has nothing real to assert against.
// Injection wins over the live pose while armed, so a headless assert can
// never be raced by the compositor.
static int sohvr_injectOn = 0;
static float sohvr_injectPos[3] = { 0, 0, 0 };
static float sohvr_injectYawDeg = 0.0f, sohvr_injectPitchDeg = 0.0f;

// --- published diagnostics state ----------------------------------------------
static const float kSohVRHalfIpd = 0.0315f; // metres; 63 mm, the D2 first-light check

typedef struct {
    int valid;
    size_t views, textures, ratemaps;
    unsigned long colorFmt, depthFmt;
    int layout; // 0 dedicated / 1 layered (inferred from texture/slice indices)
    double vpW[2], vpH[2];
    size_t texIdx[2], slice[2];
    float tanL[2], tanR[2], tanB[2], tanT[2];
    float rawC2z[2], rawC3z[2];
    float depthNear[2], depthFar[2];
    int depthKind[2]; // 0 forward-Z / 1 reverse-Z finite / 2 reverse-Z infinite far
    float zndc1m[2], zndc1000m[2];
    float rangeFar, rangeNear; // cp_drawable_get_depth_range, metres (x=far, y=near)
} SohVRContract;
static SohVRContract sohvr_contract;

static simd_float4x4 sohvr_head;          // origin_from_device actually used
static simd_float4x4 sohvr_eyeTrack[2];   // eye pose in TRACKING space
static float sohvr_eyeVPDump[2][16];      // last published row-vector matrices
static int sohvr_anchored = 0;            // a tracked device anchor was obtained
static int sohvr_synthEye2 = 0;           // second eye synthesized (sim: views=1)
static int sohvr_poseSrc = 0;             // 0 identity / 1 anchor / 2 injected
static int sohvr_frameCount = 0;
static uint64_t sohvr_presents = 0;
static double sohvr_presentHz = 0.0;
// R17 part B item 2: THE BLACK VR ENTRY LEFT NO EVIDENCE AND NO SELF-HEAL.
// The heartbeat shows the enter -> exit-within-seconds -> re-enter shape twice
// in four launches of 1.0.1.21, and every breadcrumb in this path was NSLog
// only. In code the black state already has a name -- sohvr_reason is
// "no_eye_texture" when haveWorld is 0, i.e. the compositor is presenting empty
// drawables at 60 fps while the engine's eye pair never arrives -- so what was
// missing is a witness that survives the headset coming off, and a way out that
// is not "the user exits and re-enters by hand".
//
// sohvr_layerState is the compositor state as the LOOP last saw it. The entry
// watchdog reads this instead of calling cp_layer_renderer_get_state itself: the
// layerRenderer belongs to the loop's thread and to SwiftUI's teardown, and a
// diagnostic must not be the thing that touches it off-thread.
static volatile int sohvr_layerState = -1;
// Bumped on every entry, so a watchdog left over from a previous entry retires
// instead of healing the new one.
static volatile unsigned int sohvr_entryGen = 0;
// One heal per app run: a second stall says the workaround is not the answer.
static int sohvr_entryHealedOnce = 0;
static int sohvr_pausedNoted = 0;
static void* SohVR_EntryWatchdogThread(void* arg);
static double sohvr_physLastT = 0.0; // R4: the motion-combat step's own clock
// R5: last-seen value of the game side's "a damage quad landed" counter, per
// hand. Kept HERE and not reset on VR exit for the same reason the swing seq
// is not: a stale ack replayed on re-entry would demote a live swing.
static unsigned int sohvr_bladeHitSeen[2] = { 0, 0 };

// R4 HARNESS: a scripted hand TRAJECTORY, driven by the loop at headset rate.
//
// A swing is 5 m/s of hand motion. A TCP round trip per sample cannot produce
// that, and a hand teleported between two console commands produces a velocity
// that is an artefact of network latency -- so the swing thresholds could only
// ever be asserted in a headset. This drives the injection path from INSIDE the
// loop instead, with the same real dt the hardware path gets, through the same
// SohSense_InjectHand -> commit_pose -> filter -> SohVrPhys_Step chain. What it
// exercises is therefore everything except the ARKit anchor read itself.
//
// The profile is a half-sine in speed (rest -> peak -> rest), which is what a
// real sword swing's velocity looks like and, crucially, has a DECELERATION
// half that a naive step function does not: the "exactly one attack per swing"
// claim is only meaningful if the tier machine survives the way down too.
static struct {
    int active;
    int hand;
    double t0;
    float dur;    // seconds
    float peak;   // peak hand speed, m/s
    float angPeak; // peak wrist angular speed, rad/s
    unsigned int seqAtStart;
} sohvr_script;

// One step of the trajectory. Returns 0 when it has finished (and releases the
// hand, so the no-Sense fallback is what the next frame sees).
static int sohvr_script_tick(double now) {
    if (!sohvr_script.active) {
        return 0;
    }
    float u = (float)((now - sohvr_script.t0) / (double)sohvr_script.dur);
    if (u >= 1.0f) {
        sohvr_script.active = 0;
        SohSense_InjectClear();
        return 0;
    }
    if (u < 0.0f) {
        u = 0.0f;
    }
    const float pi = (float)M_PI;
    // speed(u) = peak * sin(pi*u); position is its integral, which keeps the
    // pose and the velocity consistent -- the derived-velocity path must agree
    // with the injected one or the cross-check in `vr hands` is meaningless.
    float speed = sohvr_script.peak * sinf(pi * u);
    float dist = (sohvr_script.peak * sohvr_script.dur / pi) * (1.0f - cosf(pi * u));
    float angSpeed = sohvr_script.angPeak * sinf(pi * u);
    float angle = (sohvr_script.angPeak * sohvr_script.dur / pi) * (1.0f - cosf(pi * u));
    // Travel along +X at chest height, half a metre in front; rotate about Y,
    // so the blade (which points down the hand's -Z) sweeps horizontally --
    // a right-to-left slash.
    float qy = sinf(angle * 0.5f), qw = cosf(angle * 0.5f);
    SohSense_InjectHand(sohvr_script.hand, dist - 0.3f, 1.2f, -0.4f, 0.0f, qy, 0.0f, qw);
    SohSense_InjectVelocity(sohvr_script.hand, speed, 0.0f, 0.0f);
    SohSense_InjectAngVelocity(sohvr_script.hand, 0.0f, angSpeed, 0.0f);
    return 1;
}
static double sohvr_presentWindowStart = 0.0;
static uint64_t sohvr_presentWindowCount = 0;
static void sohvr_note_present(void) {
    sohvr_presents++;
    if (sohvr_presents == 1) {
        extern void SohIos_VrNote(const char* what, const char* detail);
        char sohDetail[96];
        snprintf(sohDetail, sizeof(sohDetail), "frame=%d pair_accepts=%llu", sohvr_frameCount,
                 (unsigned long long)sohvr_pairAccepts);
        SohIos_VrNote("first present", sohDetail);
    }
    sohvr_presentWindowCount++;
    double now = CACurrentMediaTime();
    if (sohvr_presentWindowStart <= 0.0) {
        sohvr_presentWindowStart = now;
        return;
    }
    double el = now - sohvr_presentWindowStart;
    if (el >= 1.0) {
        sohvr_presentHz = sohvr_presentWindowCount / el;
        sohvr_presentWindowCount = 0;
        sohvr_presentWindowStart = now;
    }
}
static uint64_t sohvr_dumpSeq = 0;
static const char* sohvr_reason = "idle";

// --- R1: pose rendezvous bookkeeping ------------------------------------------
static uint64_t sohvr_rvHits = 0, sohvr_rvMisses = 0;
// R2a: the ENCODE-level rendezvous (gSohVREyeSeqDone) is not the same event as
// the PUBLISH-level one (both eye textures carrying this pose's tag). R1 waited
// on the first and presented whatever textures happened to be published, which
// on device is a pair that may be a frame old, a frame split, or both. Both are
// counted now: enc_hit says the engine finished ENCODING in time, rv_hit says
// the pixels the compositor is about to sample are actually this pose's.
static uint64_t sohvr_encHits = 0, sohvr_encMisses = 0;
static double sohvr_rvWaitMsLast = 0.0, sohvr_rvWaitMsMax = 0.0;
// The device anchor the CURRENT eye-texture content was rendered against. On a
// missed rendezvous we present the stale pair against THIS anchor, not the live
// one: the compositor reprojects from the pose the content was rendered for, so
// handing it a pose the content never used is what makes stale frames swim.
static ar_device_anchor_t sohvr_contentAnchor = NULL;
static double sohvr_contentAnchorTime = 0.0;

// --- R1: recenter / artificial offsets (spec D6, DONOR-MAP §4f) ------------
// The no-op recenter captures NOTHING into steering. It zeroes the artificial
// yaw (nothing writes it yet in R1 — snap turn is R2) and re-seats the
// roomscale origin on the current head translation, which is the one thing a
// player pressing "Recenter" in a chair actually wants.
static float sohvr_turnYaw = 0.0f;
static simd_float3 sohvr_roomOrigin = { 0, 0, 0 };
static int sohvr_recenterReq = 0;
// --- R8 item 5: THE HEIGHT CALIBRATION, AND THE BUG IT FIXES ----------------
//
// the user, on 1.0.1.10: after exiting VR and re-entering it he is TOO TALL.
//
// The mechanism that is supposed to prevent that already existed: on the rising
// edge of first person the shell re-seats sohvr_roomOrigin on the live head, so
// sohvr_to_game maps the head to the anchor exactly and the wearer's eyes land
// at Link's eye height whatever their real height is. Leaving VR drops
// gSohVRFpActive (overlay 0041 gates it on gSohVRMode), so re-entering DOES
// raise the edge and the recenter DOES fire.
//
// It fires too early. The edge is consumed on whichever compositor frame
// happens to carry it, and on the first frames after an immersive space opens
// the world-tracking provider has not converged: the anchor query fails,
// sohvr_poseSrc is 0, and `head` is the IDENTITY. Seating the room origin on an
// identity head puts it at the floor at the tracking origin, so the moment
// tracking DOES converge the wearer's real standing height -- 1.5 m or so --
// is added on top of Link's eye height. At 34 units/m that is about 51 game
// units of extra stature, which is precisely "too tall", and it is intermittent
// in exactly the way a race is.
//
// So the calibration is a REQUEST that waits for a real pose. It is raised by
// VR entry, by the first-person rising edge, by the manual recenter and by the
// settings sheet's "Re-calibrate VR height" button, and it is serviced on the
// first frame that has a pose worth trusting. sohvr_heightCals counts the ones
// that actually happened, which is what makes the difference assertable.
static int sohvr_heightCalReq = 0;
// R16 part B: THE YAW RESET IS NOT THE HEIGHT CALIBRATION. the user, wearing
// 1.0.1.20: "running forward, stop, pause, unpause — it always flips me
// around." The calibration used to zero sohvr_turnYaw as well, and turnYaw 0 is
// not "no change": it is the ABSOLUTE statement "the wearer's forward is the
// game's -Z". Running north, that is exactly 180 degrees, and overlay 0042's
// facing pin then turned Link's body to match. The pause raises overlay 0039's
// flat latch, first person drops for its duration, and the return used to
// arrive as a first-person ENTRY (fixed in 0041 rev3) that requested the
// calibration. So the two requests are separate now: the height calibration
// re-seats the room ORIGIN, which every return may legitimately want; the yaw
// is zeroed ONLY by the explicit recenter and by VR entry, which are the two
// places a wearer has actually asked to face -Z again. The settings sheet's
// "Re-calibrate VR height" button deliberately does NOT set this.
static int sohvr_yawResetReq = 0;
static uint64_t sohvr_heightCals = 0;
static uint64_t sohvr_heightCalDeferred = 0;
static simd_float3 sohvr_eyeGame[2];
static simd_float3 sohvr_eyeFwd[2]; // R9 part B: the eye's world forward, post-flip
static uint64_t sohvr_recenters = 0;

// --- R1: flat-screen contexts (spec D3) ------------------------------------
static int sohvr_flatActive = 0;                 // this compositor frame is flat
static int sohvr_flatPrev = 0;                   // edge detector
static id<MTLTexture> sohvr_frozenWorld[2];      // world pair captured on the edge
static uint64_t sohvr_flatEnters = 0;

// --- R1: depth-handoff contract (spec D2 / D-044) --------------------------
// Fast3D renders forward-Z; the compositor's depth texture is reverse-Z with an
// INFINITE far plane. The blit therefore CONVERTS, and these are the constants
// it converts with. z_ndc_fwd = f*(n - d) / ((n - f) * d)  =>
//   d = f*n / (z*(n - f) + f)        (game units)
//   z_rev = near_m / (d / scale) = (near_m * scale) / d
static float sohvr_depthNearM = 0.1f; // compositor near plane, metres (measured)
static int sohvr_depthValid = 0;

// --- eye readback (pixel proof; engine-side beats a window screenshot) --------
static volatile int sohvr_captureReq = 0;
// R7 verdict 7: the HUD-plane probe rides the SAME request/ack pair as the eye
// dump, so it runs on the loop thread that owns the Metal queue.
static volatile int sohvr_hudProbeReq = 0;
static volatile int sohvr_hudProbeDone = 0;
static volatile int sohvr_captureDone = 0;
static uint32_t sohvr_captureHash[2] = { 0, 0 };
static uint32_t sohvr_captureMean[2] = { 0, 0 };
static int sohvr_captureW[2] = { 0, 0 }, sohvr_captureH[2] = { 0, 0 };

// --- small matrix helpers ------------------------------------------------------
static simd_float4x4 sohvr_rotY(float rad) {
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = simd_make_float4(c, 0, -s, 0);
    m.columns[2] = simd_make_float4(s, 0, c, 0);
    return m;
}
static simd_float4x4 sohvr_rotX(float rad) {
    float c = cosf(rad), s = sinf(rad);
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[1] = simd_make_float4(0, c, s, 0);
    m.columns[2] = simd_make_float4(0, -s, c, 0);
    return m;
}

// Classify the compositor's OWN depth convention, measured rather than assumed
// (spec R0 finding ii). Column-major simd: columns[c][r] is row r, col c.
//   forward-Z metal : c2z = f/(n-f) < 0,      c3z = n*f/(n-f) < 0
//   reverse-Z finite: c2z = n/(f-n) > 0,      c3z = n*f/(f-n) > 0
//   reverse-Z, far=inf: c2z = 0,              c3z = n
static void sohvr_classify_depth(simd_float4x4 pc, int* kind, float* outNear, float* outFar) {
    float c2z = pc.columns[2][2], c3z = pc.columns[3][2];
    if (fabsf(c2z) < 1e-6f) {
        *kind = 2;
        *outNear = fabsf(c3z);
        *outFar = INFINITY;
    } else if (c2z < 0.0f) {
        *kind = 0;
        float n = c3z / c2z;
        *outNear = n;
        *outFar = (fabsf(1.0f + c2z) > 1e-6f) ? (c2z * n / (1.0f + c2z)) : INFINITY;
    } else {
        *kind = 1;
        float f = c3z / c2z;
        *outFar = f;
        *outNear = (fabsf(1.0f + c2z) > 1e-6f) ? (c2z * f / (1.0f + c2z)) : 0.0f;
    }
}

// Forward-Z (z_ndc 0 at near, 1 at far — Metal/Fast3D's convention) perspective
// from asymmetric tangents. Column-major simd, right-handed, looking down -Z.
static simd_float4x4 sohvr_projection(float tL, float tR, float tB, float tT, float n, float f) {
    simd_float4x4 p;
    memset(&p, 0, sizeof(p));
    float w = tR - tL, h = tT - tB;
    if (fabsf(w) < 1e-6f || fabsf(h) < 1e-6f || fabsf(n - f) < 1e-6f) {
        return matrix_identity_float4x4;
    }
    p.columns[0][0] = 2.0f / w;
    p.columns[1][1] = 2.0f / h;
    p.columns[2][0] = (tR + tL) / w;
    p.columns[2][1] = (tT + tB) / h;
    p.columns[2][2] = f / (n - f);
    p.columns[2][3] = -1.0f;
    p.columns[3][2] = f * n / (n - f);
    return p;
}

// --- A: the tracking-space -> game-space seat --------------------------------
// Computed ONCE per compositor frame so both eyes and the head pose that gets
// pushed back into the game View all share it exactly.
typedef struct {
    simd_float4x4 Rg;   // playspace base yaw (gamma) + artificial turn
    simd_float3 anchor; // game-space origin of the playspace
    float gamma;
} SohVRSeat;

// --- R7 verdict 5: THE FLIP CAMERA -------------------------------------------
//
// the user, 2026-09-04, asked for Z-targeting to behave as vanilla -- lock on,
// strafe, side-hop, backflip -- "and a backflip camera option, default ON:
// during backflip/side-hop the VR view follows the authored flip the way
// SpaghettiKart/sm64coopdx do it".
//
// The sibling that solved exactly this move is sm64coopdx, and its round notes
// are mostly a list of ways to get it wrong. Both of its recorded bugs came
// from the same root and both are avoided here by construction:
//
//   * INTEGRATE AGAINST THE CLOCK, NOT THE CALL COUNT. Its first cut advanced a
//     fixed step per call, and this runs once per RENDERED frame rather than
//     once per game tick -- at 90 Hz against a step sized for about 18 ticks, a
//     single backflip spun the view several full turns. the user's report was
//     "it just flickers and does a first person somersault view like MANY
//     times, and isn't smooth at all". Same sentence covers the second bug: a
//     per-frame step is frame-rate dependent, so the same move spans a
//     different arc under different load.
//   * STOP DEAD AT ONE REVOLUTION. A full turn IS the identity rotation, so
//     finishing one means snapping to zero. Easing back down through the arc
//     just travelled reads as an unwind, which is not what the body did.
//
// dt is clamped: a stall (a load, a menu) must not teleport the view a third of
// a turn on the frame it ends.
//
// WHICH MOVES. The backflip only, and that is a considered narrowing of the
// ask rather than an omission. `gSohVRHopKind` distinguishes the four lock-on
// hops, and in OoT only the backturn hop (kind 2) is a SOMERSAULT -- the side
// hops are sideways skips with no rotation in them at all, so there is no
// authored flip for the view to follow and rolling the horizon during one would
// be inventing motion, which is the definition of a comfort cost with no
// payoff. A roll for the side-hops is one constant away if the user wants it.
//
// Comfort off is the exact identity: the angle is forced to zero, the branch
// below is skipped, and the head stays level.
//
// R8 item 8: AND THE FORWARD ROLL. the user asked for the same camera on Link's
// forward somersault (Player_Action_Roll), turning the OPPOSITE way. It is the
// same integrator with two differences, and both matter:
//
//   * THE SENSE IS INVERTED. A backflip pitches the body backward and a roll
//     pitches it forward, so the two accumulate with opposite signs about the
//     eye's own X. One toggle covers both, because they are one behaviour.
//   * THE DURATION IS THE ROLL'S OWN. The backflip's 0.60 s is a constant we
//     chose; the roll's comes from the animation, published by overlay 0042
//     rev6 at Player_SetupRoll as endFrame / playSpeed / 20 Hz. A constant
//     would have drifted the moment the play speed changed, which it does --
//     sWaterSpeedFactor halves it in water -- and a camera that finishes early
//     or late is exactly the "isn't smooth at all" the sibling recorded.
//
// The two moves are mutually exclusive in the game (a hop is not a roll), and
// the integrator is one variable, so there is nothing to arbitrate: whichever
// is running owns it, and a revolution in progress always finishes.
#define SOHVR_FLIP_SECONDS 0.60f
#define SOHVR_FLIP_TWO_PI 6.28318531f
#define SOHVR_ROLL_SECONDS_FALLBACK 0.85f
static int sohvr_flipCam = 1; // R7 verdict 5 / R8 item 8: default ON, per the user
static float sohvr_flipAngle = 0.0f;
static int sohvr_flipWas = 0;
static uint64_t sohvr_flips = 0;
static uint64_t sohvr_rolls = 0;
static float sohvr_flipRatePerSec = 0.0f; // the rate the CURRENT turn is using
static int sohvr_flipKind = 0;            // 0 none, 1 backflip, 2 forward roll
static int sohvr_flipForce = -1;          // R9 part B: -1 follows the game, 0/1/2 forces

static float sohvr_roll_seconds(void) {
    float s = gSohVRRollSeconds;
    if (!(s > 0.05f && s < 5.0f)) {
        return SOHVR_ROLL_SECONDS_FALLBACK;
    }
    return s;
}

static void sohvr_update_flip(float dt) {
    if (dt > 0.1f) {
        dt = 0.1f;
    }
    // 1 = backflip (view somersaults BACKWARD), 2 = forward roll (FORWARD).
    int kind = 0;
    if (sohvr_flipCam) {
        if (gSohVRHopKind == 2) {
            kind = 1;
        } else if (gSohVRRollActive) {
            kind = 2;
        }
        // R9 part B test hook (`vr flip back|roll|off|auto`): -1 follows the
        // game. A backflip needs a Z-target and a roll needs somewhere to roll,
        // and the SIGN of the camera is the thing under test -- an assertion
        // that can only run where the harness happens to have left Link
        // standing is an assertion about the harness.
        if (sohvr_flipForce >= 0) {
            kind = sohvr_flipForce;
        }
    }
    int turning = (kind != 0);
    if (turning && !sohvr_flipWas) {
        sohvr_flipAngle = 0.0f;
        sohvr_flipKind = kind;
        if (kind == 1) {
            sohvr_flipRatePerSec = SOHVR_FLIP_TWO_PI / SOHVR_FLIP_SECONDS;
            sohvr_flips++;
        } else {
            sohvr_flipRatePerSec = -SOHVR_FLIP_TWO_PI / sohvr_roll_seconds();
            sohvr_rolls++;
        }
    }
    sohvr_flipWas = turning;
    if (!sohvr_flipCam) {
        sohvr_flipAngle = 0.0f;
        sohvr_flipKind = 0;
        return;
    }
    if (turning || sohvr_flipAngle != 0.0f) {
        // Landing mid-turn FINISHES the revolution rather than rewinding it,
        // which is why this runs on both sides of the `turning` test.
        sohvr_flipAngle += sohvr_flipRatePerSec * dt;
        if (sohvr_flipAngle >= SOHVR_FLIP_TWO_PI || sohvr_flipAngle <= -SOHVR_FLIP_TWO_PI) {
            sohvr_flipAngle = 0.0f; // one turn is the identity: snap, never ease
            sohvr_flipKind = 0;
        }
    }
}

// Applied on the RIGHT of the eye's game pose, so the eye somersaults about its
// own origin instead of orbiting the anchor.
//
// R9 part B: THE SIGN WAS INVERTED, ON BOTH MOVES. the user: "the roll camera
// turns the wrong way (like a backflip)". The two moves are opposite by
// construction here -- the backflip integrates a POSITIVE rate and the roll a
// negative one -- so if the roll looked like a backflip, the backflip had to be
// wrong too, and he had never said so because a backflip is a rare move.
//
// The arithmetic, which is what settled it rather than a convention. Rotating a
// pose about its own +X by theta takes its forward (0,0,-1) to (0, sin(theta),
// -cos(theta)): positive theta pitches the view UP. R8 wrote
// simd_quaternion(-angle, X), so the backflip's positive angle pitched the view
// DOWN -- and leaning back to somersault backwards is the wearer looking UP.
// One sign, and now BOTH senses are asserted (S21: the eye's world forward must
// gain +Y through a backflip and -Y through a forward roll), because a check
// that only names one of them is how this survived two rounds.
static simd_float4x4 sohvr_apply_flip(simd_float4x4 gamePose) {
    if (sohvr_flipAngle == 0.0f) {
        return gamePose;
    }
    simd_quatf q = simd_quaternion(sohvr_flipAngle, simd_make_float3(1, 0, 0));
    return simd_mul(gamePose, simd_matrix4x4(q));
}

// --- R8 part B: THE ATTACK ENVELOPES, and the shield crouch ------------------
//
// the user, on the button attack: "the only animation your sword sees is like a
// swish... it should actually physically move your sword forward like you're
// attacking. then a user can either swing their fist or just hit the button and
// it has the same immersive feedback."
//
// R7's withdrawal of func_8083BB20 is what made a button press silent: no
// authored animation runs for a covered weapon, so a B press opened a damage
// window around a sword that never moved. The answer is NOT to bring the
// animation back -- that is the R5 lesson, two attacks per press, one where the
// hand is and one along an authored arc. It is to move the HAND.
//
// It is done at the SINGLE pose seam, immediately after the grip->hand
// calibration and before sohvr_to_game, for exactly the reason the calibration
// itself is done there: the drawn hand, the drawn sword and shield, the vanilla
// sword trail (which is computed through the hand limb matrix) and the solver's
// blade all read one pose. Splitting them is how R5 shipped a sword that damaged
// somewhere it was not.
//
// Two things it is deliberately NOT:
//
//   * NOT a per-frame constant. It integrates against CACurrentMediaTime, the
//     same rule as the flip camera, because the compositor runs at 90-120 Hz and
//     a constant per frame is a different envelope on every device.
//   * NOT restartable at will. Mashing B would otherwise re-seat the phase every
//     press and the sword would judder in place instead of thrusting. A new
//     envelope is accepted only once the running one is 70% done; earlier
//     triggers are counted and dropped, so "it ignored my press" is a number.
// --- R9 part B: ONE SLASH, and it is defined against the WORLD ---------------
//
// the user, on 1.0.1.12, about R8's thrust: "it doesn't move forward enough, and
// it should angle down as well (like a true sword attack). We aren't pushing
// enemies forward with the handle of our sword! If you code it correctly it
// should look normal when holding the sword sideways as well."
//
// R8's envelope was a TRANSLATION ALONG THE BLADE with 15 degrees of tip-down.
// Written out like that the defect is obvious: if the blade is pointing to the
// left, "along the blade" is a push to the left, handle first. It was a lunge
// expressed in the sword's own frame, and a sword's own frame is exactly what a
// wearer is free to rotate arbitrarily.
//
// This one is expressed in the WEARER's frame instead -- world up and body
// forward -- so the same three numbers describe the same visible motion however
// the wrist is rolled:
//
//   * WINDUP  (first 25% of the OUT phase): the blade tip rotates from wherever
//     it is toward WORLD UP, by SLASH_ARC degrees.
//   * STRIKE  (the rest of the OUT phase, ease-out): it rotates from there to
//     BODY FORWARD, tilted SLASH_DOWN degrees below the horizon, while the grip
//     pivot translates SLASH_REACH along body forward and SLASH_DROP down.
//   * HOLD    (SLASH_HOLD seconds): the transform is held at the finish. A
//     swing with no hold reads as a twitch -- the eye needs a beat at the end
//     of the arc to see where the blade got to.
//   * RETURN  (SLASH_BACK seconds): the whole rigid transform eases back to
//     identity, so the hand finishes exactly where tracking says it is.
//
// R10 (the user, on 1.0.1.13): *"I still need the point or tip of the sword to
// point forward as part of the movement. Otherwise it's like a little attack...
// it feels like a half swing, not a full swing."* Four changes, all of them in
// the numbers rather than in the shape, because the shape was right:
//
//   * THE WINDUP GOES TO VERTICAL, ALWAYS. R9 shipped a 70 degree arc, which
//     from a blade already held high lifted it a few degrees and from a blade
//     held low never reached the sky. The arc default is 180 now, and the
//     clamp that stops the windup at world up (`wf > 1`) is what makes that
//     mean "start from vertical, wherever you were holding it". The dial is
//     kept, because a wearer who wants a shorter windup should have it.
//   * THE FINISH IS 35 DEGREES BELOW THE HORIZON, not 20: a full swing ends
//     with the tip down past the target, not level with it.
//   * THE GRIP TRAVELS 50 cm AND DROPS 12 cm, not 40 cm on the flat.
//   * THE TIMING IS OUT / HOLD / BACK -- 0.40 s out, 0.08 s held, 0.30 s back
//     -- so the tip is pointing forward at about 60% of the whole envelope and
//     stays there long enough to be seen. R9's single 0.35 s duration spent
//     30% of itself easing back, which is what made it read as a half swing.
//
// The rotation is built as "the rotation that takes the CURRENT blade direction
// to the target direction", so a sideways-held sword ends tip-forward like any
// other -- which is the half of the user's ruling that a blade-frame envelope can
// never satisfy.
//
// ONE envelope, two sizes: the Z-target jump attack is the same shape with a
// bigger arc and more time, plus vanilla's jump-slash damage column (overlay
// 0048 rev4, unchanged). "These two should mirror each other" -- his words.
#define SOHVR_SLASH_SECONDS 0.40f   // the OUT phase: windup + strike
#define SOHVR_SLASH_HOLD_SECONDS 0.08f
#define SOHVR_SLASH_BACK_SECONDS 0.30f
#define SOHVR_SLASH_ARC_DEG 180.0f  // >= 180 means "all the way to vertical, from any hold"
#define SOHVR_SLASH_DOWN_DEG 60.0f  // R11 verdict 4: was 35 -- the user wants the tip further down
#define SOHVR_SLASH_REACH_M 0.25f   // R11 verdict 4: HALVED from 0.50 -- "halve the forward travel"
#define SOHVR_SLASH_DROP_M 0.12f    // and how far it drops while it goes
#define SOHVR_JUMP_SECONDS 0.50f
#define SOHVR_JUMP_ARC_DEG 180.0f
#define SOHVR_JUMP_REACH_M 0.65f
#define SOHVR_SLASH_WINDUP_FRAC 0.25f // of the OUT phase, not of the whole envelope
// --- R19 item 1: A THIRD SIZE OF THE SAME ENVELOPE -- THE HAMMER'S CHOP -----
//
// the user, wearing 1.0.1.23: *"The Megaton hammer works with either trigger and
// I see the wind/swish animation, but the hammer doesn't do the
// hitting-the-ground swing animation. It stays in my arm, upright."*
//
// The cause is R9's cause, in a weapon R9 did not cover. R18 gave the hammer
// back vanilla's AUTHORED swing (PLAYER_MWA_HAMMER_FORWARD / _SIDE), which is
// the swish he hears -- and an authored swing moves the ARM, while the arm in
// VR is the controller: overlay 0042 replaces the L_HAND limb matrix with
// gSohVRHandMat and zeroes the skeleton's own pos/rot. Nothing the animation
// asks of the arm can reach the hammer. So the hammer is moved the way the
// sword is moved: HERE, at the one pose seam, as a third kind of the same
// envelope, off gSohVRHammers (overlay 0042 rev20).
//
// R20 item 1: WHAT R19 GOT WRONG, AND IT WAS THE AXIS.
//
// the user, wearing 1.0.1.24: *"the hammer now makes an animation, but the wrong
// animation. It comes down vertically so that the butt of the handle hangs on
// the ground. That is not how the vanilla animation works. It needs to be like
// you are holding it, only the TOP or the HAMMER end of it swings or rotates
// all the way down like you are hitting with a hammer."*
//
// R19 rotated the hand about `hpose.columns[0]` -- the CALIBRATED CONTROLLER
// pose's +X -- on the argument that vanilla's hammer tip (2500, 400, 0) runs up
// the LIMB frame's +X. The premise is right and the conclusion is wrong,
// because hpose's frame is NOT the limb frame. Between them sit two fixed
// transforms that overlay 0042 applies AFTER installing gSohVRHandMat:
//
//     limb = hpose  .  Mirror(-1, 1, 1)   [right-handed play, gSohVRHandMirrorSword]
//                   .  ItemCal[model]     [IDENTITY for the hammer, row 5]
//
// so a limb-frame direction d reaches shell space as hpose_R . M . d and NOT as
// d's own components of hpose. For the hammer that is a SIGN FLIP on the
// dominant term -- the head runs along MINUS hpose +X in right-handed play --
// and R19 therefore rotated the hammer as though the head were where the BUTT
// is. "The butt of the handle hangs on the ground" is that sentence from the
// wearer's side, and it is exactly a half turn away from what was wanted.
//
// So kind 3 no longer falls back on modelX at all. `sohvr_limb_dir` carries
// vanilla's own tip vector through the map above, and `vr room` prints two
// cosines that say whether the map is the map:
//
//   atk_hamdot  cos(head axis, hpose +X)  -- about -0.988 right-handed, +0.988
//               left-handed, i.e. the head IS (minus) the calibration's +X and
//               R19's fallback had the sign backwards.
//   atk_swlimb  the same derivation applied to the SWORD's limb tip
//               (5000, 400, 0), dotted with the SOLVER's blade line. This is
//               the honest number and it is NOT 1: the solver's blade is the
//               raw grip frame's local -Z (SohVrPhys.c, kBladeAxisZ) and the
//               hand calibration puts the drawn blade about 55 degrees off it
//               (0.57 at the shipped constants). The two have disagreed since
//               R8 -- `atk_axdot` is the same disagreement measured against
//               modelX -- and nothing in this round changes either of them; the
//               sword still swings about the SOLVER's blade, which is what
//               the user has worn and approved. It is printed so the next round
//               that wants to close that gap has the number in front of it.
//
// A HAMMER IS NOT A SWORD, and the numbers say so. The sword's slash ends with
// its tip pointing forward and 60 degrees below the horizon, having travelled
// 25 cm along body forward -- a cut through a standing enemy. A hammer chop, in
// the user's own description, is a WRIST FLEX: the hand stays where the
// controller is and the head goes over the top and all the way down.
//
//   * WINDUP  25 degrees of lift, not "all the way to vertical". The wearer's
//     real arm is where it is, and a 180-degree lift would tear the mesh away
//     from the hand it is supposed to be held in.
//   * STRIKE  to 90 degrees BELOW the horizon -- STRAIGHT DOWN, which is what
//     "hitting the ground" means.
//   * NO TRAVEL. R20: the forward reach and the grip drop are both ZERO. R19
//     shipped 15 cm forward and 40 cm down, and the drop is half of what the user
//     saw: the whole hammer sank 40 cm while turning about the wrong axis, so
//     the handle reached the floor. "Like you're holding it" is a pivot at the
//     hand and nothing else. Both dials are KEPT (`hammerreach`, `hammerdrop`)
//     so some can be added back from a headset.
//   * TIMING  the OUT phase is 0.35 s. That is not a taste: vanilla fires the
//     hammer's ground effect (func_80842A28 -- the quake, the rumble,
//     NA_SE_IT_HAMMER_HIT -- and EffectSsBlast_SpawnWhiteShockwave) at
//     animation frame 7 of PLAYER_MWA_HAMMER_FORWARD, and the game ticks at
//     20 Hz, so frame 7 is 0.35 s after the swing starts. The head is at the
//     bottom of its arc when the ground answers.
//
// Everything downstream of the pose is vanilla's and is reached for free: the
// melee AT quads are registered by z_player_lib.c (motion combat does not cover
// weapon 5, so vanilla's own quads are NOT skipped for the hammer), and both
// they and func_80842DF4's ground line test are built from
// meleeWeaponInfo[0].tip, which vanilla computes through the L_HAND limb matrix
// -- through the controller, and therefore through this envelope. The hammer
// hits where it is seen to land without one line of collider code.
//
// THE ONE THING A ZERO DROP COSTS is the ground hit, and R20 pays it in overlay
// 0042 rev21 rather than by putting the drop back: with the pivot at the hand,
// a wearer chopping at waist height finishes with the head 20-40 cm ABOVE the
// floor and vanilla's line test -- which runs from 10 units behind the base to
// the TIP and no further -- never reaches it. `gSohVRHammerProbe` extends the
// probe BEYOND the tip by 15 game units (0.44 m at the shipped world scale of
// 34 units/m), VR + motion-hands + hammer only. `vr set hammerprobe 0..40`.
//
// UNMEASURED. Every number above except the 0.35 s is a first plausible default
// reasoned from vanilla's own timing and from what a chop is; none of it has
// been worn. The dials are `vr set hammerarc|hammerdown|hammerreach|hammerdrop|
// hammersecs|hammerhold|hammerback|hammerprobe`, and Q-VR39 asks the user for the
// verdict.
#define SOHVR_HAMMER_SECONDS 0.35f      // vanilla's frame 7 at 20 Hz
#define SOHVR_HAMMER_HOLD_SECONDS 0.10f // a beat on the ground
#define SOHVR_HAMMER_BACK_SECONDS 0.25f
#define SOHVR_HAMMER_ARC_DEG 25.0f  // the head rises, it does not go overhead
#define SOHVR_HAMMER_DOWN_DEG 90.0f // R20: STRAIGHT down, not 80
#define SOHVR_HAMMER_REACH_M 0.0f   // R20: a wrist flex travels nowhere
#define SOHVR_HAMMER_DROP_M 0.0f    // R20: and the hand stays where the hand is

static int sohvr_atkKind = 0;   // 0 none, 1 stab, 2 chop, 3 hammer
static float sohvr_atkT = 0.0f; // seconds into the running envelope
static int sohvr_stabSeen = 0;
static int sohvr_chopSeen = 0;
static int sohvr_hammerSeen = 0;
static uint64_t sohvr_stabEnvelopes = 0;
static uint64_t sohvr_chopEnvelopes = 0;
static uint64_t sohvr_hammerEnvelopes = 0;
static uint64_t sohvr_atkDropped = 0;
static float sohvr_atkReach = 0.0f; // metres the pivot is displaced, this frame
static float sohvr_atkDrop = 0.0f;  // R10: and how far DOWN, this frame
static float sohvr_atkAngle = 0.0f; // radians the blade tip sits ABOVE the horizon
// R9 part B: the four numbers the envelope is built from, console-tunable
// (`vr set slasharc|slashdown|slashreach|slashsecs|jumparc|jumpsecs`).
static float sohvr_slashArcDeg = SOHVR_SLASH_ARC_DEG;
static float sohvr_slashDownDeg = SOHVR_SLASH_DOWN_DEG;
static float sohvr_slashReachM = SOHVR_SLASH_REACH_M;
static float sohvr_slashSecs = SOHVR_SLASH_SECONDS;
static float sohvr_jumpArcDeg = SOHVR_JUMP_ARC_DEG;
static float sohvr_jumpSecs = SOHVR_JUMP_SECONDS;
// R10: the follow-through. `vr set slashdrop|slashhold|slashback|jumpreach`.
static float sohvr_slashDropM = SOHVR_SLASH_DROP_M;
static float sohvr_slashHoldSecs = SOHVR_SLASH_HOLD_SECONDS;
static float sohvr_slashBackSecs = SOHVR_SLASH_BACK_SECONDS;
static float sohvr_jumpReachM = SOHVR_JUMP_REACH_M;
// R19 item 1: the hammer's own seven, all dialled by `vr set hammer*`.
static float sohvr_hammerSecs = SOHVR_HAMMER_SECONDS;
static float sohvr_hammerHoldSecs = SOHVR_HAMMER_HOLD_SECONDS;
static float sohvr_hammerBackSecs = SOHVR_HAMMER_BACK_SECONDS;
static float sohvr_hammerArcDeg = SOHVR_HAMMER_ARC_DEG;
static float sohvr_hammerDownDeg = SOHVR_HAMMER_DOWN_DEG;
static float sohvr_hammerReachM = SOHVR_HAMMER_REACH_M;
static float sohvr_hammerDropM = SOHVR_HAMMER_DROP_M;
// The peaks the suite reads, in the two terms the user's ruling is written in:
// how far ABOVE the horizon the tip got (the windup), and how close to BODY
// FORWARD it came (the strike). Degrees, max/min since the envelope started.
static float sohvr_atkPeakUpDeg = 0.0f;
static float sohvr_atkBestFwdDeg = 180.0f;
// R10: WHEN in the envelope the tip was closest to body forward, as a fraction
// of the whole thing. the user asked for the tip to be pointing forward "as part
// of the movement", which is a claim about TIMING and cannot be read off an
// angle -- an envelope that ends forward in its last millisecond satisfies
// every angular assertion R9 had and still reads as a twitch.
static float sohvr_atkBestFwdU = 0.0f;
// The tip's elevation at the instant the envelope started, so "it rose 45
// degrees from where it was" is a difference of two published numbers rather
// than an assumption about where the harness left the hand.
static float sohvr_atkStartUpDeg = 0.0f;
static int sohvr_atkStartCaptured = 0;
// The envelope's phase, split so the SHAPE (time) and the GEOMETRY (world up,
// body forward, the tracked blade) are computed in the two places that have the
// inputs for each.
static float sohvr_atkPhaseWind = 0.0f;
static float sohvr_atkPhaseStrike = 0.0f;
static float sohvr_atkBlend = 0.0f;
// The PEAKS of the envelope now running (or the last one to run). A 0.30 s
// envelope sampled over a TCP round trip is a race -- an assertion that reads
// atk_reach live is asserting that the reply arrived in the right 30 ms, which
// is not a property of the code. These are max-since-the-envelope-started, so
// the claim "the palm travelled 28 cm along the blade and the damage quad went
// with it" survives being read whenever the reply happens to land.
static float sohvr_atkPeakTravel = 0.0f;  // metres the published palm moved
static float sohvr_atkPeakDot = 0.0f;     // cos(travel, blade axis) at that peak
static float sohvr_atkBladeShift = 0.0f;  // metres the solver's blade base moved
// Test hook: -1 follows the game's own gSohVRCrouch, 0/1 forces it. The shield
// stance depends on standing somewhere a shield can be raised, which a
// simulator cannot promise; the EASING and the DROP are the shell's and are
// testable without it.
static int sohvr_crouchForce = -1;

// The rigid transform this frame's envelope applies to one hand: rotate about
// the hand's own origin, then translate along the (rotated) blade. Stored
// because the blade LINE is published from the solver's own points further down
// the frame and has to ride the same motion -- the drawn sword and the damaging
// sword are one object or the feature is a lie.
typedef struct {
    int active;
    simd_float3 pivot;
    simd_quatf q;
    simd_float3 t;
    simd_float3 axis; // the blade direction the thrust was built along
} SohVRAtkXf;

static SohVRAtkXf sohvr_atkXf[2];
static SohVRAtkXf sohvr_atkXfPrev[2];

// The OUT phase (windup + strike). The whole envelope is out + hold + back.
//
// R19 item 1: every one of these is now per-KIND, so kind 3 (the hammer) can be
// a different shape without a second copy of the machine. Kinds 1 and 2 return
// exactly what they returned before -- the sword's arithmetic is unchanged by
// construction, which is the only way to add a weapon without re-testing one.
static float sohvr_atk_out_secs(int kind) {
    if (kind == 3) {
        return sohvr_hammerSecs;
    }
    return (kind == 2) ? sohvr_jumpSecs : sohvr_slashSecs;
}

static float sohvr_atk_hold_secs(int kind) {
    return (kind == 3) ? sohvr_hammerHoldSecs : sohvr_slashHoldSecs;
}

static float sohvr_atk_back_secs(int kind) {
    return (kind == 3) ? sohvr_hammerBackSecs : sohvr_slashBackSecs;
}

static float sohvr_atk_duration(int kind) {
    return sohvr_atk_out_secs(kind) + sohvr_atk_hold_secs(kind) + sohvr_atk_back_secs(kind);
}

static float sohvr_atk_arc_deg(int kind) {
    if (kind == 3) {
        return sohvr_hammerArcDeg;
    }
    return (kind == 2) ? sohvr_jumpArcDeg : sohvr_slashArcDeg;
}

static float sohvr_atk_reach_m(int kind) {
    if (kind == 3) {
        return sohvr_hammerReachM;
    }
    return (kind == 2) ? sohvr_jumpReachM : sohvr_slashReachM;
}

static float sohvr_atk_down_deg(int kind) {
    return (kind == 3) ? sohvr_hammerDownDeg : sohvr_slashDownDeg;
}

static float sohvr_atk_drop_m(int kind) {
    return (kind == 3) ? sohvr_hammerDropM : sohvr_slashDropM;
}

static float sohvr_smoothstep(float a) {
    if (a <= 0.0f) {
        return 0.0f;
    }
    if (a >= 1.0f) {
        return 1.0f;
    }
    return a * a * (3.0f - 2.0f * a);
}

static void sohvr_update_attack(float dt) {
    if (dt > 0.1f) {
        dt = 0.1f;
    }
    // The game side counts attacks; the shell owns the timing. A counter rather
    // than a level, because a 20 Hz producer and a 120 Hz consumer cannot share
    // an edge any other way -- the same argument as the swing seq.
    int stabs = gSohVRStabs;
    int chops = gSohVRChops;
    // R19 item 1: the hammer arrives on its own counter, bumped at vanilla's one
    // melee-animation site. Both VR routes into a hammer swing (either trigger,
    // or a physical hand swing) pass through it, so there is one edge per swing
    // here for the same reason there is one per swing for the sword.
    int hammers = gSohVRHammers;
    // How many attacks the game counted since the last compositor frame. A COUNT
    // and not a flag: a 20 Hz producer can bump twice between two frames of a
    // 120 Hz consumer, and the second one is a press the player made that will
    // never become an envelope. `atk_dropped` is every such press, whether it
    // was lost to coalescing or refused as too early a re-trigger, because from
    // the wearer's side those are the same complaint -- "it ignored my press".
    int pressed = (stabs - sohvr_stabSeen) + (chops - sohvr_chopSeen) + (hammers - sohvr_hammerSeen);
    int want = 0;
    // R19: the HAMMER wins the tie, ahead of the chop and the stab. Not a taste
    // either: a hammer swing is the only one of the three whose damage is
    // VANILLA'S OWN quad rather than overlay 0048's blade, so running a
    // sword-shaped envelope on the tick a hammer swing started would move the
    // quad along the wrong arc. The other two cannot legitimately be counted on
    // the same tick anyway -- gSohVRStabs and gSohVRChops are bumped only while
    // motion combat COVERS the weapon, which is swords 1..3, and gSohVRHammers
    // only for weapon 5.
    if (hammers != sohvr_hammerSeen) {
        want = 3;
    } else if (chops != sohvr_chopSeen) {
        want = 2;
    } else if (stabs != sohvr_stabSeen) {
        want = 1;
    }
    // All three counters are consumed either way: a stab that lost to a chop on
    // the same frame must not fire one frame later as a ghost thrust.
    sohvr_hammerSeen = hammers;
    sohvr_chopSeen = chops;
    sohvr_stabSeen = stabs;
    if (want != 0) {
        // R10: a re-trigger is allowed once the STRIKE and its hold are done --
        // i.e. during the ease-back, where the previous swing has already been
        // seen. Expressed against the phases rather than as a fraction of the
        // total, so lengthening the return does not lengthen the dead time.
        if ((sohvr_atkKind == 0) ||
            (sohvr_atkT >= sohvr_atk_out_secs(sohvr_atkKind) + sohvr_atk_hold_secs(sohvr_atkKind))) {
            sohvr_atkKind = want;
            sohvr_atkT = 0.0f;
            sohvr_atkPeakTravel = 0.0f;
            sohvr_atkPeakDot = 0.0f;
            sohvr_atkBladeShift = 0.0f;
            sohvr_atkPeakUpDeg = -180.0f;
            sohvr_atkBestFwdDeg = 180.0f;
            sohvr_atkBestFwdU = 0.0f;
            sohvr_atkStartCaptured = 0;
            sohvr_atkPhaseWind = 0.0f;
            sohvr_atkPhaseStrike = 0.0f;
            sohvr_atkBlend = 1.0f;
            if (want == 3) {
                sohvr_hammerEnvelopes++;
            } else if (want == 2) {
                sohvr_chopEnvelopes++;
            } else {
                sohvr_stabEnvelopes++;
            }
            if (pressed > 1) {
                sohvr_atkDropped += (uint64_t)(pressed - 1);
            }
        } else {
            sohvr_atkDropped += (uint64_t)(pressed > 0 ? pressed : 1);
        }
    }
    if (sohvr_atkKind == 0) {
        sohvr_atkReach = 0.0f;
        sohvr_atkDrop = 0.0f;
        sohvr_atkAngle = 0.0f;
        sohvr_atkPhaseWind = sohvr_atkPhaseStrike = sohvr_atkBlend = 0.0f;
        return;
    }
    sohvr_atkT += dt;
    float dur = sohvr_atk_duration(sohvr_atkKind);
    if (sohvr_atkT >= dur) {
        sohvr_atkKind = 0;
        sohvr_atkT = 0.0f;
        sohvr_atkReach = 0.0f;
        sohvr_atkDrop = 0.0f;
        sohvr_atkAngle = 0.0f;
        sohvr_atkPhaseWind = sohvr_atkPhaseStrike = sohvr_atkBlend = 0.0f;
        return;
    }
    // R9 part B: THE PHASE, and nothing else. The direction the tip is being
    // taken to is world geometry and is built in sohvr_atk_build, where the
    // tracked pose and the head are both in hand; here we only say how far
    // through the three phases we are.
    //   sohvr_atkPhase  0..1 windup, 1..2 strike, 2..3 return (see the build)
    //   sohvr_atkBlend  1 while striking, easing to 0 through the return
    // R10: the phases are SECONDS, not fractions of one duration. out (windup
    // + strike) / hold / back, so each can be dialled without moving the other
    // two -- which is the whole of "it feels like a half swing": R9's single
    // 0.35 s number spent its last 30% easing back out of a strike that had
    // barely landed.
    float out = sohvr_atk_out_secs(sohvr_atkKind);
    float hold = sohvr_atk_hold_secs(sohvr_atkKind);
    float wind = out * SOHVR_SLASH_WINDUP_FRAC;
    float t = sohvr_atkT;
    if (t < wind) {
        sohvr_atkPhaseWind = sohvr_smoothstep(t / wind);
        sohvr_atkPhaseStrike = 0.0f;
        sohvr_atkBlend = 1.0f;
    } else if (t < out) {
        float a = (t - wind) / (out - wind);
        // EASE-OUT: fast off the mark, settling into the finish. A slash that
        // eases IN reads as a shove.
        sohvr_atkPhaseWind = 1.0f;
        sohvr_atkPhaseStrike = 1.0f - (1.0f - a) * (1.0f - a);
        sohvr_atkBlend = 1.0f;
    } else if (t < out + hold) {
        // THE HOLD. Everything at the finish, nothing moving: the beat that
        // makes the end of the arc readable.
        sohvr_atkPhaseWind = 1.0f;
        sohvr_atkPhaseStrike = 1.0f;
        sohvr_atkBlend = 1.0f;
    } else {
        float back = (dur - out - hold);
        float a = (back > 1e-4f) ? ((t - out - hold) / back) : 1.0f;
        sohvr_atkPhaseWind = 1.0f;
        sohvr_atkPhaseStrike = 1.0f;
        sohvr_atkBlend = 1.0f - sohvr_smoothstep(a);
    }
}

// Build the frame's transform for one hand from its calibrated pose and the
// blade direction the solver is actually using. The axis comes from the SOLVER
// when it has a blade, so the thrust travels along the sword rather than along
// whatever the calibration says +X is -- if those two ever disagree the thrust
// would be the first thing to show it, and `vr room`'s atk_axdot is the number
// that says whether they do.
static float sohvr_atkAxDot = 1.0f;

// Rotate `from` toward `to` by fraction s (0 = from, 1 = to), staying on the
// great circle. Degenerate pairs (parallel, antiparallel) fall back to `from`,
// which makes the envelope a no-op rather than a snap.
static simd_float3 sohvr_dir_slerp(simd_float3 from, simd_float3 to, float s) {
    float d = simd_dot(from, to);
    if (d > 0.9999f || d < -0.9999f) {
        return (s >= 0.5f && d < 0.0f) ? to : from;
    }
    simd_quatf q = simd_quaternion(from, to);
    simd_quatf qi = simd_quaternion(0.0f, simd_make_float3(1, 0, 0));
    return simd_act(simd_slerp(qi, q, s), from);
}

// R20 item 1: THE LIMB FRAME, WHICH IS NOT THE HAND POSE'S FRAME.
//
// Overlay 0042 installs gSohVRHandMat as the limb matrix and then applies, in
// this order and in the LIMB's local frame, Matrix_Scale(model), the mesh
// MIRROR (right-handed play only -- the player's right controller drives Link's
// left hand, so the mesh is reflected), and the held-item calibration for the
// model type. The scale is uniform and drops out of a direction; the item row
// for the hammer (kSohVRItemCal[5]) is identity in both configurations. What is
// left is the mirror, and it flips x.
//
// So a vector expressed in vanilla's LIMB frame -- which is the frame every
// number in z_player_lib.c's weapon geometry is written in -- reaches shell
// space as hpose_R . M . d. Getting this wrong by the mirror is a HALF TURN
// about the drawn weapon, which is R19's defect exactly.
static simd_float3 sohvr_limb_dir(simd_float4x4 hpose, simd_float3 dLimb) {
    if ((gSohVRLeftHanded == 0) && (gSohVRHandMirrorSword != 0)) {
        dLimb.x = -dLimb.x;
    }
    simd_float3 v = hpose.columns[0].xyz * dLimb.x + hpose.columns[1].xyz * dLimb.y +
                    hpose.columns[2].xyz * dLimb.z;
    float l = simd_length(v);
    return (l > 1e-5f) ? (v / l) : simd_make_float3(1, 0, 0);
}

// Vanilla's own melee geometry, in the limb frame: D_80126080 is (1, 0.16, 0)
// scaled by sMeleeWeaponLengths[], so the tip of weapon w is
// (sMeleeWeaponLengths[w], 400, 0). Weapon 5 is the Megaton hammer (2500) and
// weapon 1 is the Kokiri sword (5000) -- the second is here only to be MEASURED
// against the solver's blade, never to steer anything.
static const simd_float3 kSohVRHammerTipLimb = { 2500.0f, 400.0f, 0.0f };
static const simd_float3 kSohVRSwordTipLimb = { 5000.0f, 400.0f, 0.0f };

// Reported, never asserted. See the R20 block above SOHVR_HAMMER_SECONDS.
static float sohvr_atkHamDot = 0.0f;
static float sohvr_atkSwLimbDot = 0.0f;

static SohVRAtkXf sohvr_atk_build(simd_float4x4 hpose, const simd_float3* bladeDir, simd_float3 bodyFwd) {
    SohVRAtkXf xf;
    const simd_float3 up = simd_make_float3(0, 1, 0);
    xf.active = 0;
    xf.pivot = hpose.columns[3].xyz;
    xf.q = simd_quaternion(0.0f, simd_make_float3(1, 0, 0));
    xf.t = simd_make_float3(0, 0, 0);
    xf.axis = simd_make_float3(1, 0, 0);
    if (sohvr_atkKind == 0) {
        sohvr_atkReach = 0.0f;
        sohvr_atkDrop = 0.0f;
        sohvr_atkAngle = 0.0f;
        return xf;
    }
    simd_float3 modelX = hpose.columns[0].xyz;
    float mlen = simd_length(modelX);
    modelX = (mlen > 1e-5f) ? (modelX / mlen) : simd_make_float3(1, 0, 0);
    simd_float3 axis = modelX;
    if (sohvr_atkKind == 3) {
        // R20 item 1: THE HAMMER'S HEAD, through the limb map and not through a
        // guess about hpose's own axes. This is the fix for "the butt of the
        // handle hangs on the ground": the head is (minus, when the mesh is
        // mirrored) the calibration's +X, and R19 rotated the opposite end.
        axis = sohvr_limb_dir(hpose, kSohVRHammerTipLimb);
    } else if (bladeDir != NULL) {
        float blen = simd_length(*bladeDir);
        if (blen > 1e-4f) {
            axis = *bladeDir / blen;
        }
    }
    // Reported, never asserted: the cosine between the blade that damages and
    // the axis the hand calibration calls the blade. See VR-R8-NOTES Part B §5.
    sohvr_atkAxDot = simd_dot(axis, modelX);

    // THE TWO WORLD-FRAME TARGETS. Both are built from the wearer's frame, not
    // the sword's, which is the whole of the user's "it should look normal when
    // holding the sword sideways as well".
    //
    // dWind: the tracked blade direction, rotated toward WORLD UP by the arc.
    // Expressed as a fraction of the angle that would take it all the way to
    // up, so the arc is a real number of degrees whatever the start pose is.
    float upAngle = acosf(simd_clamp(simd_dot(axis, up), -1.0f, 1.0f));
    float arc = sohvr_atk_arc_deg(sohvr_atkKind) * (float)M_PI / 180.0f;
    float wf = (upAngle > 1e-4f) ? (arc / upAngle) : 0.0f;
    if (wf > 1.0f) {
        wf = 1.0f; // never past vertical: a windup, not a somersault
    }
    simd_float3 dWind = sohvr_dir_slerp(axis, up, wf);

    // dEnd: BODY FORWARD on the horizon, tilted below it. Body forward is the
    // head's forward flattened to the horizontal plane -- pitch and roll are
    // deliberately dropped, exactly as the seat's own yaw is, so looking at
    // your feet does not aim the slash at them.
    simd_float3 fwdH = simd_make_float3(bodyFwd.x, 0.0f, bodyFwd.z);
    float fl = simd_length(fwdH);
    if (fl < 1e-4f) {
        return xf; // no usable heading this frame: leave the hand alone
    }
    fwdH = fwdH / fl;
    float down = sohvr_atk_down_deg(sohvr_atkKind) * (float)M_PI / 180.0f;
    simd_float3 dEnd = simd_normalize(fwdH * cosf(down) - up * sinf(down));

    // THE PATH: axis -> dWind -> dEnd, then a blended return to identity.
    simd_float3 dNow = sohvr_dir_slerp(axis, dWind, sohvr_atkPhaseWind);
    if (sohvr_atkPhaseStrike > 0.0f) {
        dNow = sohvr_dir_slerp(dNow, dEnd, sohvr_atkPhaseStrike);
    }
    // R10: with the arc at 180 the target can be the exact OPPOSITE of the
    // tracked blade (a sword held straight down, swept to straight up), and
    // simd_quaternion(from, to) is not defined for an antiparallel pair -- it
    // produces NaN, and a NaN in the hand pose is a hand that vanishes. Build
    // the half-turn explicitly about any perpendicular axis instead.
    simd_quatf qFull;
    {
        float ad = simd_clamp(simd_dot(axis, dNow), -1.0f, 1.0f);
        if (ad < -0.9999f) {
            simd_float3 perp = simd_cross(axis, simd_make_float3(0, 1, 0));
            if (simd_length(perp) < 1e-4f) {
                perp = simd_cross(axis, simd_make_float3(1, 0, 0));
            }
            qFull = simd_quaternion((float)M_PI, simd_normalize(perp));
        } else {
            qFull = simd_quaternion(axis, dNow);
        }
    }
    simd_quatf qIdent = simd_quaternion(0.0f, simd_make_float3(1, 0, 0));
    float blend = sohvr_atkBlend;
    xf.axis = axis;
    xf.q = (blend >= 0.999f) ? qFull : simd_slerp(qIdent, qFull, blend);
    // THE TRANSLATION: forward, along the same body forward, ramped with the
    // strike and released with the blend. Zero at both ends by construction, so
    // there is no snap on either edge.
    sohvr_atkReach = sohvr_atk_reach_m(sohvr_atkKind) * sohvr_atkPhaseStrike * blend;
    // R10: and it DROPS while it goes. A full swing finishes low and forward;
    // a lunge that stays at shoulder height is the "little attack" the user
    // described. The drop rides the same ramp so both ends are still zero.
    sohvr_atkDrop = sohvr_atk_drop_m(sohvr_atkKind) * sohvr_atkPhaseStrike * blend;
    xf.t = fwdH * sohvr_atkReach - up * sohvr_atkDrop;
    xf.active = 1;

    // The measurements, in the terms the ruling is written in.
    if (!sohvr_atkStartCaptured) {
        sohvr_atkStartCaptured = 1;
        sohvr_atkStartUpDeg = asinf(simd_clamp(axis.y, -1.0f, 1.0f)) * 180.0f / (float)M_PI;
    }
    simd_float3 tipDir = simd_act(xf.q, axis);
    sohvr_atkAngle = asinf(simd_clamp(tipDir.y, -1.0f, 1.0f));
    float upDeg = sohvr_atkAngle * 180.0f / (float)M_PI;
    if (upDeg > sohvr_atkPeakUpDeg) {
        sohvr_atkPeakUpDeg = upDeg;
    }
    float fwdDeg = acosf(simd_clamp(simd_dot(tipDir, fwdH), -1.0f, 1.0f)) * 180.0f / (float)M_PI;
    if (fwdDeg < sohvr_atkBestFwdDeg) {
        sohvr_atkBestFwdDeg = fwdDeg;
        // R10: and WHEN it happened, as a fraction of the whole envelope.
        {
            float d = sohvr_atk_duration(sohvr_atkKind);
            sohvr_atkBestFwdU = (d > 1e-4f) ? (sohvr_atkT / d) : 0.0f;
        }
    }
    if ((sohvr_atkReach > sohvr_atkPeakTravel) && (sohvr_atkReach > 1e-4f)) {
        sohvr_atkPeakTravel = sohvr_atkReach;
        // R9 part B: the travel is along BODY FORWARD now, not along the blade,
        // because pushing along the blade is pushing with the handle -- which is
        // the defect this envelope replaces. atk_peak_dot therefore measures the
        // claim that still matters: the pivot moves where the wearer is facing.
        sohvr_atkPeakDot = simd_dot(simd_normalize(xf.t), fwdH);
    }
    return xf;
}

// x -> q.(x - pivot) + pivot + t. A pose takes the same rotation on its basis;
// its origin is the pivot, so it lands at pivot + t.
static simd_float3 sohvr_atk_point(const SohVRAtkXf* xf, simd_float3 x) {
    if (!xf->active) {
        return x;
    }
    return simd_act(xf->q, x - xf->pivot) + xf->pivot + xf->t;
}

static simd_float4x4 sohvr_atk_pose(const SohVRAtkXf* xf, simd_float4x4 pose) {
    if (!xf->active) {
        return pose;
    }
    simd_float4x4 r = simd_matrix4x4(xf->q);
    simd_float4x4 out = simd_mul(r, pose);
    out.columns[3] = simd_make_float4(xf->pivot + xf->t, 1.0f);
    return out;
}

// --- the shield crouch -------------------------------------------------------
// the user: "you are crouching as well [in N64], so the perspective or camera
// should go down a little as if you're crouching." A fraction of STANDING eye
// height, eased at compositor rate, applied to the shell's seat and nowhere
// else: the game-tick anchor (overlay 0041) is what the world scale and the
// height calibration are measured against, and lowering it would lower them.
#define SOHVR_CROUCH_SECONDS 0.15f
static float sohvr_crouchFrac = 0.20f; // `vr set crouch 0..0.5`, not persisted
static float sohvr_crouchNow = 0.0f;   // 0..1, the eased level
static uint64_t sohvr_crouches = 0;

static void sohvr_update_crouch(float dt) {
    if (dt > 0.1f) {
        dt = 0.1f;
    }
    int want = (sohvr_crouchForce >= 0) ? sohvr_crouchForce : (gSohVRCrouch != 0);
    float target = want ? 1.0f : 0.0f;
    if ((target > 0.5f) && (sohvr_crouchNow <= 0.0f)) {
        sohvr_crouches++;
    }
    float step = dt / SOHVR_CROUCH_SECONDS;
    if (sohvr_crouchNow < target) {
        sohvr_crouchNow += step;
        if (sohvr_crouchNow > target) {
            sohvr_crouchNow = target;
        }
    } else if (sohvr_crouchNow > target) {
        sohvr_crouchNow -= step;
        if (sohvr_crouchNow < target) {
            sohvr_crouchNow = target;
        }
    }
}

// Game units to subtract from the seat's anchor height this frame.
static float sohvr_crouch_drop(void) {
    float stand = gSohVRFpEyeHeight;
    if (!(stand > 1.0f) || !(stand < 1000.0f)) {
        return 0.0f;
    }
    return sohvr_crouchNow * sohvr_crouchFrac * stand;
}

static SohVRSeat sohvr_seat(void) {
    // R2b (spec D4, VR-DONOR-MAP §3): FIRST PERSON is the VR view. The
    // anchor is the one overlay 0041 computed this tick — Link's actor ROOT
    // plus eye height, never the animated head bone — and the playspace base
    // yaw gamma is ZERO, because in first person the world is not rotated to
    // face a camera: the player's own head decides where they look, and the
    // stick follows it through the steering table (overlay 0042).
    //
    // Pitch and roll are never folded in, in either branch: the horizon must
    // stay level with real gravity (donor vr_openxr.cpp:2138-2157).
    if (gSohVRFpActive) {
        SohVRSeat s;
        s.gamma = 0.0f;
        s.Rg = sohvr_rotY(sohvr_turnYaw);
        s.anchor = simd_make_float3(gSohVRFpAnchor[0],
                                    gSohVRFpAnchor[1] + sohvr_height * sohvr_scale -
                                        sohvr_crouch_drop(),
                                    gSohVRFpAnchor[2]);
        sohvr_fpSeated = 1;
        return s;
    }
    sohvr_fpSeated = 0;
    // FALLBACK ONLY — this is not "third person the mode", which was removed
    // this round. It is the donor's automatic far-camera guard (:1370-1388)
    // plus the no-player case: seat A on overlay 0037's export of the GAME
    // camera's own basis, NOT
    // on 0032's gSoh3DCam* — those are taken inside z_view.c AFTER camera
    // unification has written the head pose into the view, so seating A on them
    // would chase our own HMD offset in a feedback loop (VR-DONOR-MAP §3, the
    // donor's load-bearing comment on its anchor). Falls back to the 0032 basis
    // before the first Camera_Update of a scene.
    float fx, fz, ex, ey, ez;
    if (gSohVRAnchorValid) {
        fx = gSohVRAnchorFwd[0];
        fz = gSohVRAnchorFwd[2];
        ex = gSohVRAnchorEye[0];
        ey = gSohVRAnchorEye[1];
        ez = gSohVRAnchorEye[2];
    } else {
        fx = gSoh3DCamFwd[0];
        fz = gSoh3DCamFwd[2];
        ex = gSoh3DCamEye[0];
        ey = gSoh3DCamEye[1];
        ez = gSoh3DCamEye[2];
    }
    float flen = sqrtf(fx * fx + fz * fz);
    SohVRSeat s;
    s.gamma = (flen > 1e-4f) ? atan2f(-fx / flen, -fz / flen) : 0.0f;
    // Yaw ONLY. Pitch and roll are deliberately never folded in — the horizon
    // must stay level with real gravity (donor, vr_openxr.cpp:2138-2157).
    s.Rg = sohvr_rotY(s.gamma + sohvr_turnYaw);
    s.anchor = simd_make_float3(ex, ey + sohvr_height * sohvr_scale, ez);
    return s;
}

// Place a TRACKING-space pose into game space: roomscale origin removed,
// translation scaled metres -> game units, rotated by the base yaw, seated on
// the anchor. Rotation is NOT scaled (scale is a scalar on translation only —
// R0 finding 6: at a zero head offset the scale is invisible, and that's
// correct).
static simd_float4x4 sohvr_to_game(SohVRSeat seat, simd_float4x4 track) {
    simd_float4x4 m = simd_mul(seat.Rg, track);
    simd_float3 t = (track.columns[3].xyz - sohvr_roomOrigin) * sohvr_scale;
    simd_float3 tg = simd_mul(seat.Rg, simd_make_float4(t, 0.0f)).xyz + seat.anchor;
    m.columns[3] = simd_make_float4(tg, 1.0f);
    return m;
}

// --- R7 verdicts 2 + 3: THE GRIP -> HAND CALIBRATION -------------------------
//
// THE USER'S TWO VERDICTS ARE ONE DEFECT, and the screenshots say so. 6.png has
// the shield sitting at his real hand with the blade poking through it; 7.png
// has the sword blade pointing sideways and flat rather than along his hand.
// He read those as two problems -- "link's hands are too high and don't match
// exactly where my controllers are... also rotated incorrectly", and "the sword
// and shield are just AFFIXED and don't move properly" -- and they are the same
// missing transform.
//
// THE MISSING TRANSFORM. Overlay 0042's pin is correct and matches the donor's
// line for line: it replaces the hand limb's matrix outright, zeroes the
// animated pos/rot so the skeleton contributes nothing, folds Link's model
// scale back in, and mirrors per hand. The held sword and shield ride that same
// matrix, exactly as the donor intends -- so they DO follow the hand. What was
// never there is the correction between the ARKit accessory frame and the hand
// MESH's own frame. We were feeding the raw controller pose straight through
// `sohvr_to_game`.
//
// Those two frames have no reason to agree, and in OoT they emphatically do
// not: the blade extends along the hand model's +X (z_player_lib.c's blade
// vertices are { length, 400, 0 } in hand-model space), while an ARKit
// accessory's own forward is its grip axis. A rotation of roughly a quarter
// turn between them is precisely "the blade lies sideways, flat" -- 7.png -- and
// it is ALSO why the sword read as "affixed": with the basis a quarter turn out,
// the user's wrist rotations map onto blade motions that feel arbitrary, so a
// blade that is in fact following his hand perfectly does not look like it is.
//
// THE FIX, and it is the donor's own shape (vr_openxr.cpp:2339-2405):
//
//     M' = T(p + q*off) * R(q * cal)
//
// -- the offset is rotated INTO the controller's own frame before it is added,
// and the calibration rotation is applied on the RIGHT of the controller's
// rotation, so the hand turns about its own origin rather than orbiting the
// controller. Getting either side wrong is invisible at one pose and wrong
// everywhere else, which is the single most expensive way to be wrong here.
//
// THE DEFAULTS ARE A BEST GUESS AND ARE LABELLED AS ONE. The donor's numbers
// (88, -100, 80 for the mirrored sword hand; -149, 76, 30 for the left) were
// hand-tuned in a headset against Index/Touch grip frames, which are NOT the
// PSVR2 Sense's. The sibling that DID tune a Sense pair on this exact hardware
// is sm64coopdx, whose constants are yaw 89/98, pitch -/+17, roll -20 and a 7 cm
// forward offset out of the grip -- found by the user on device and then frozen
// into the source, because they describe how two models relate and not a
// preference. Those are the numbers seeded below, adapted for Link's hand mesh
// with the extra quarter turn that puts the blade axis where the ARKit grip
// axis points. They are a STARTING POINT for the user to dial, which is what he
// asked for: "give me some temporary settings to adjust them and i can tell you
// what the values should be."
//
// Per hand, and independent -- NOT conjugated. The donor conjugates the right
// hand's euler through the mirror, and that is a real relationship for a
// reflected mesh, but it also means a single wrong guess is wrong in two places
// at once and cannot be dialled out of one hand without disturbing the other.
// With a human doing the dialling, two independent triples converge faster.
//
// Units are what the user will type: CENTIMETRES for the offset, DEGREES for the
// rotation. The conversion happens here, once.
// R8 item 1: FROZEN. the user dialled these in the headset on 1.0.1.10 and they
// are now source constants with no sliders behind them -- the sm64coopdx rule,
// because they describe how the ARKit accessory frame and Link's hand mesh
// relate and not what anybody prefers. The twelve @AppStorage keys are gone
// with the section, deliberately: a stale UserDefaults value surviving the
// slider would silently overwrite the constants on the next applyAll(), which
// is the worst possible failure mode for a number nobody can see.
//
// WHAT HE TYPED, AND WHAT IS STORED. The slider labelled "Forward" displays
// -z (forward is out of the grip, away from you, which is NEGATIVE z), so a
// slider reading of "forward -1" is stored as z = +1. Across and Up are x and y
// exactly as displayed. His numbers, and the translation, once:
//
//   Right: across +1.0   up -9.5   forward -1.0  ->  off_cm = {  +1.0,  -9.5, +1.0 }
//          yaw 90  pitch +8  roll -100           ->  rot_deg = { 90, 8, -100 }
//   Left:  across -13.5  up -11.0  forward +6.5  ->  off_cm = { -13.5, -11.0, -6.5 }
//          yaw 0   pitch 0   roll -100           ->  rot_deg = { 0, 0, -100 }
//
// `vr set handoff L|R ...` and `vr hands` are KEPT, for the next round of
// dialling -- see the roll note below, which is why there will be one.
//
// R9 PART A RE-BASED THESE TO ZERO, and that is a change to the user's numbers,
// so it is written down rather than done quietly. The pose these offsets are
// applied to is no longer the ARKit ANCHOR -- it is the accessory's GRIP
// coordinate space (SohSense.m, `sohsense_publish_pose`), whose ORIGIN is the
// point at which the controller is HELD. The 10-17 cm he dialled were mostly
// the lever arm from the Sense's model origin to that point; with the pose
// already sitting at the grip, re-adding them would put Link's palm 17 cm off
// his own AND restore the orbit, because the orbit radius is the distance from
// the roll pivot to the drawn hand and the roll pivot is now the grip.
//
// The re-base is ZERO rather than `t - g` for one honest reason: `t - g` is
// ALGEBRAICALLY THE OLD BEHAVIOUR. grip * (gripFromAnchor * C) == anchor * C,
// so preserving the neutral pose exactly also preserves the orbit exactly; the
// two cannot be separated. Zero is the choice that actually moves the pivot.
// The cost is that Link's palm will sit where the GRIP is rather than where
// the user's one-pose fit put it, which may want a small true offset added back
// (`vr set handoff L|R px py pz`) -- a few centimetres, dialled against a hand
// that now turns in place.
//
// HIS ROTATIONS ARE UNCHANGED. They may still be wrong -- the grip location can
// carry a rotation of its own, and `atk_axdot` in `vr room` (the cosine between
// the solver's blade direction and the calibrated hand's +X, -0.174 as of R8)
// is the number that says so. It is still the thing to watch while re-dialling.
// --- R11 verdict 2: THE CALIBRATION IS PER CONFIGURATION ---------------------
//
// the user, wearing 1.0.1.14, gave six numbers for the LEFT controller and one for
// the RIGHT, and then said the sword is upside down and the shield faces left
// when the Sword-hand picker is set to LEFT. Those are the same finding from two
// ends, and the mechanism is in overlay 0042's limb override:
//
//   * Link is LEFT-handed. His L_HAND holds the sword, his R_HAND the shield.
//   * RIGHT-handed play: the player's RIGHT controller drives Link's L_HAND, so
//     a controller on one side of the body drives a mesh on the other and 0042
//     applies Matrix_Scale(-1,1,1) -- a MIRROR -- to the limb.
//   * LEFT-handed play: the LEFT controller drives Link's L_HAND, same side, and
//     0042 correctly applies NO mirror (`sohMirror = (gSohVRLeftHanded == 0) &&
//     ...`).
//
// The calibration, however, was one table per CONTROLLER for both
// configurations. So in left-handed play the sword hand was driven by the LEFT
// controller's constants -- which were dialled for the SHIELD -- and the mirror
// that used to sit between the sword constants and the mesh was gone. The
// visible orientation of the sword hand is therefore
//
//   right-handed : Mirror . R(controller R)          = Mirror . R(90, 8, -100)
//   left-handed  :          R(controller L)          =          R( 0, 0, -100)
//
// and those differ by most of a half turn about the blade, which is "the sword
// is upside down" exactly. The same swap gives Link's shield hand the SWORD's
// 90-degree yaw, which is "the shield is facing left".
//
// So the constants are keyed by configuration, and the LEFT-HANDED set is not a
// guess: it is the right-handed set CONJUGATED BY THE MIRROR, which is the
// transform 0042 stops applying. Mirroring about x=0 (M = diag(-1,1,1)) sends a
// rotation R to M R M, and componentwise, for the Ry*Rp*Rr the calibration
// builds:
//
//   translation : x negated, y and z unchanged
//   yaw   (Y)   : negated        (M Ry(t) M == Ry(-t))
//   pitch (X)   : UNCHANGED      (M Rx(t) M == Rx(t))
//   roll  (Z)   : negated        (M Rz(t) M == Rz(-t))
//
// and the ROLES swap across the two controllers with the sword. Applying both to
// the user's right-handed numbers gives the left-handed row below. It predicts a
// roll of +100 where the shipped build used -100 -- a 200-degree error about the
// blade axis, which is why the sword looked upside down -- so the prediction and
// the symptom agree, which is the only reason it ships as a default rather than
// as a zero. the user dials it from there and reports; the sliders below now edit
// whichever configuration is selected.
//
// WHAT HE TYPED, AND WHAT IS STORED, once more (the convention is R7's and it
// has bitten before): the slider labelled "Forward" DISPLAYS -z, so a reading of
// "forward -1" is stored as z = +1. "Across" is x and "Up" is y exactly as
// displayed. the user's 1.0.1.14 numbers, and the translation:
//
//   LEFT  controller: across -13.5  up -2.0  forward 0  ->  off_cm {-13.5,-2.0,0}
//                     yaw 0    pitch 0   roll -100      ->  rot_deg {0, 0, -100}
//   RIGHT controller: across   0.0  up -2.0  forward 0  ->  off_cm {  0.0,-2.0,0}
//                     yaw 90   pitch 8   roll -100      ->  rot_deg {90, 8, -100}
//
// He wrote "Forward -" for the left controller with no number; it is recorded as
// ZERO and this sentence is the assumption. He asked for the right controller to
// move "up -2.0 cm from where it is now" (it was 0/0/0), which is the row above.
//
// Index order in each row: x, y, z (cm), then yaw, pitch, roll (degrees).
#define SOHVR_HANDCAL_N 6
// --- R12 item 2: BOTH SETS ARE FROZEN, AND NEITHER IS A PREDICTION ----------
//
// the user wore 1.0.1.15 -- "the sword movement looks great now" -- and dialled
// BOTH configurations in the headset, then read the twenty-four numbers off the
// page. R11 shipped the left-handed row as the mirror CONJUGATE of the
// right-handed one, which was the right thing to ship when nobody had worn it;
// it is now superseded by measurement, and the measurement is NOT the conjugate
// (his left-handed sword-hand pitch is -19 where the conjugate predicted +8).
// That is expected -- the conjugate is exact only for a wrist that holds the
// two controllers as mirror images of each other, and a human does not.
//
// D-053's rule applies to the numbers, not to the sliders: the sliders STAY for
// now because the held-item calibration below may need to move a hand with
// them, and they are the only instrument that can tell a bad item correction
// from a bad hand calibration.
//
// The stored convention is R7's, once more, because it has bitten before: the
// slider labelled "Forward" DISPLAYS -z, so a reading of "forward +3" is stored
// as z = -3. "Across" is x and "Up" is y exactly as displayed. What the user
// typed, and what is stored:
//
//   SWORD ON RIGHT (config 0)
//     LEFT  (shield): across -13.5  up -2  forward  0  yaw   0  pitch -16  roll -120
//     RIGHT (sword) : across   0    up -2  forward  0  yaw  90  pitch  +8  roll -120
//   SWORD ON LEFT (config 1)
//     LEFT  (sword) : across  -2    up -2  forward  0  yaw -90  pitch -19  roll +120
//     RIGHT (shield): across  +9.5  up -2  forward +3  yaw   0  pitch -35  roll  +90
//
// R13 (1.0.1.16, "great!"): FINAL. Four numbers moved and all four are ROLL --
// -100 -> -120, -122 -> -120, +130 -> +120, +95 -> +90. Everything else is
// identical to what he dialled on 1.0.1.15, which is the signature of a
// calibration that has converged: the seat is right and the last pass was the
// wrist. The namespace goes vrHand2_ -> vrHand3_ for the same reason it went
// vrHand_ -> vrHand2_ last round -- his install has the 1.0.1.15 values WRITTEN
// into it, and a stored value beats a shipped default.
//
// Only the last row has a non-zero forward, and it is the only stored z that is
// not zero: +3 displayed is -3.0f stored.
//
// Index order in each row: x, y, z (cm), then yaw, pitch, roll (degrees).
static const float kSohVRHandCal[2][2][SOHVR_HANDCAL_N] = {
    // [0] RIGHT-HANDED (sword on the right controller) -- the user's own numbers.
    {
        { -13.5f, -2.0f, 0.0f, 0.0f, -16.0f, -120.0f }, // left controller  (shield)
        { 0.0f, -2.0f, 0.0f, 90.0f, 8.0f, -120.0f },    // right controller (sword)
    },
    // [1] LEFT-HANDED (sword on the left controller) -- the user's own numbers
    // too, as of 1.0.1.15. No longer the mirror conjugate of the row above.
    {
        { -2.0f, -2.0f, 0.0f, -90.0f, -19.0f, 120.0f }, // left controller  (sword)
        { 9.5f, -2.0f, -3.0f, 0.0f, -35.0f, 90.0f },    // right controller (shield)
    },
};

// The LIVE calibration: whichever configuration's row the settings pushed. It
// opens on the right-handed set so a build whose defaults have not been pushed
// yet (the suite before applyAll, a first launch) is already the user's.
static float sohvr_handOffCm[2][3] = {
    // x (across), y (up), z (forward out of the grip, negative = away from you)
    { -13.5f, -2.0f, 0.0f }, // left
    { 0.0f, -2.0f, 0.0f },   // right
};
static float sohvr_handRotDeg[2][3] = {
    // yaw (about Y), pitch (about X), roll (about Z), applied Ry * Rp * Rr
    { 0.0f, -16.0f, -120.0f },  // left
    { 90.0f, 8.0f, -120.0f },   // right
};

// The settings sheet reads its defaults from HERE rather than repeating them in
// Swift: a constant written twice is a constant that disagrees with itself on
// somebody's device (D-053's rule, and R9's "three of four agreeing is a fresh
// install"). config 0 = right-handed, 1 = left-handed; hand 0 = LEFT controller;
// idx 0..2 = the STORED offset in cm, 3..5 = yaw/pitch/roll in degrees.
float SohVR_HandCalDefault(int config, int hand, int idx) {
    if (config < 0 || config > 1 || hand < 0 || hand > 1 || idx < 0 || idx >= SOHVR_HANDCAL_N) {
        return 0.0f;
    }
    return kSohVRHandCal[config][hand][idx];
}

// --- R12 item 4: THE HELD-ITEM CORRECTION, ITS DEFAULTS AND ITS DIALS -------
//
// The reasoning is beside gSohVRItemRotDeg in SohIosShell.m. This is the data.
//
// Index 0..15 is PLAYER_MODELTYPE_*: 0 lh_open, 1 lh_closed, 2 sword,
// 3 sword2, 4 bgs, 5 hammer, 6 boomerang, 7 bottle, 8 rh_open, 9 rh_closed,
// 10 shield, 11 bow (bow AND slingshot -- one mesh slot), 12 bow2,
// 13 ocarina, 14 oot, 15 hookshot. Second index is the configuration
// (0 = sword on the right). Then yaw, pitch, roll in degrees and x, y, z in
// game units.
//
// EVERYTHING IS ZERO EXCEPT TWO ROWS, and both of those are GUESSES from a
// screenshot rather than measurements -- which is stated here because this
// program has shipped a prediction as a constant before and not said so:
//
//   * bow/slingshot: NO LONGER A GUESS. R13 -- the user dialled it on 1.0.1.16
//     and reported "item held: pitch -90, roll +45 (to mimic vanilla, at a 45
//     degree angle)", the same for both configurations. He was holding the
//     SLINGSHOT when he dialled, and the slingshot and the bow share one mesh
//     slot, so the row is written from his numbers and the ASSUMPTION -- that
//     what he dialled for the slingshot is right for the bow too -- is stated
//     here and in QUESTIONS.md (Q-VR30) rather than buried.
//   * ocarina/OoT: "held upright, mouthpiece away" -- the mouthpiece wants to
//     come back toward the head, which is a pitch. Same coin flip on the sign.
//
// The sword, the shield and every empty hand are identity BY CONSTRUCTION: the
// hand calibration was dialled against the sword's fist, so the sword is the
// reference this whole table is measured from and it can never need a row.
static const float kSohVRItemCal[SOHVR_ITEMCAL_N][2][6] = {
    /* 0  lh_open   */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 1  lh_closed */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 2  sword     */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 3  sword2    */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 4  bgs       */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 5  hammer    */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 6  boomerang */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 7  bottle    */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 8  rh_open   */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 9  rh_closed */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 10 shield    */ { { 0, 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0, 0 } },
    /* 11 bow       */ { { 0, -90, 45, 0, 0, 0 }, { 0, -90, 45, 0, 0, 0 } },
    /* 12 bow2      */ { { 0, -90, 45, 0, 0, 0 }, { 0, -90, 45, 0, 0, 0 } },
    /* 13 ocarina   */ { { 0, -90, 0, 0, 0, 0 }, { 0, -90, 0, 0, 0, 0 } },
    /* 14 oot       */ { { 0, -90, 0, 0, 0, 0 }, { 0, -90, 0, 0, 0, 0 } },
    /* 15 hookshot  */ { { 0, -55, 0, 0, 0, 0 }, { 0, -55, 0, 0, 0, 0 } },
};

static const char* const kSohVRItemCalNames[SOHVR_ITEMCAL_N] = {
    "lh_open", "lh_closed", "sword", "sword2", "bgs", "hammer", "boomerang", "bottle",
    "rh_open", "rh_closed", "shield", "bow", "bow2", "ocarina", "oot", "hookshot",
};

// Human-facing names for the settings sheet. The mesh slot named "bow" carries
// the SLINGSHOT as a child, which is the one the user will be looking at.
static const char* const kSohVRItemCalLabels[SOHVR_ITEMCAL_N] = {
    "Open hand (sword hand)", "Closed hand (sword hand)", "Sword", "Sword", "Biggoron's Sword",
    "Hammer", "Boomerang", "Bottle",
    "Open hand (off hand)", "Closed hand (off hand)", "Shield", "Bow / Slingshot", "Bow / Slingshot",
    "Ocarina", "Ocarina of Time", "Hookshot",
};

const char* SohVR_ItemCalName(int model) {
    if (model < 0 || model >= SOHVR_ITEMCAL_N) {
        return "none";
    }
    return kSohVRItemCalNames[model];
}

const char* SohVR_ItemCalLabel(int model) {
    if (model < 0 || model >= SOHVR_ITEMCAL_N) {
        return "Nothing";
    }
    return kSohVRItemCalLabels[model];
}

float SohVR_ItemCalDefault(int config, int model, int idx) {
    if (config < 0 || config > 1 || model < 0 || model >= SOHVR_ITEMCAL_N || idx < 0 || idx >= 6) {
        return 0.0f;
    }
    return kSohVRItemCal[model][config][idx];
}

void SohVR_SetItemCal(int config, int model, int idx, float v) {
    if (config < 0 || config > 1 || model < 0 || model >= SOHVR_ITEMCAL_N || idx < 0 || idx >= 6) {
        return;
    }
    if (idx < 3) {
        if (v < -180.0f) {
            v = -180.0f;
        } else if (v > 180.0f) {
            v = 180.0f;
        }
        gSohVRItemRotDeg[model][config][idx] = v;
    } else {
        if (v < -50.0f) {
            v = -50.0f;
        } else if (v > 50.0f) {
            v = 50.0f;
        }
        gSohVRItemOffU[model][config][idx - 3] = v;
    }
}

int SohVR_HeldModel(int hand) {
    if (hand < 0 || hand > 1) {
        return -1;
    }
    return gSohVRHeldModel[hand];
}

// The live table starts AS the shipped one. A constructor rather than a lazy
// init because the reader is the game thread inside a limb draw: there is no
// safe point there to notice that a table has not been filled in yet, and a
// zeroed row would be a silently uncorrected item rather than a loud failure.
__attribute__((constructor)) static void sohvr_itemCalInit(void) {
    for (int m = 0; m < SOHVR_ITEMCAL_N; m++) {
        for (int c = 0; c < 2; c++) {
            for (int i = 0; i < 3; i++) {
                gSohVRItemRotDeg[m][c][i] = kSohVRItemCal[m][c][i];
                gSohVRItemOffU[m][c][i] = kSohVRItemCal[m][c][i + 3];
            }
        }
    }
}

// --- R14 item 2: THE AIM TRIMS, AND THE ROW A DIAL WRITES -------------------
//
// The trims are keyed by mesh slot x configuration, and the console verb has to
// pick a row without being told one. It picks the item BEING AIMED (the last
// one Player_VrAimHeld reported), then whatever aimable item is in a hand right
// now, then the bow/slingshot slot -- which is the row the simulator and the
// suite always land on, because nothing is held there.
int SohVR_AimTrimModel(void) {
    // R17 item 4: the ROW, not the model. The bow and the slingshot share mesh
    // slot 11 and no longer share a trim, so a console dial has to write the
    // row the game is reading -- which the aim publishes on every frame it
    // runs. gSohVRAimModel is still what `vr aim` NAMES as the item.
    if ((gSohVRAimTrimRow >= 0) && (gSohVRAimTrimRow < SOHVR_AIMTRIM_N)) {
        return gSohVRAimTrimRow;
    }
    if ((gSohVRAimModel >= 0) && (gSohVRAimModel < SOHVR_ITEMCAL_N)) {
        return gSohVRAimModel;
    }
    for (int h = 0; h < 2; h++) {
        int m = gSohVRHeldModel[h];
        // The mesh-slot indices are kSohVRItemCalNames' own: 6 boomerang,
        // 11 bow (and the slingshot with it), 12 bow2, 15 hookshot. The shell
        // does not include z64player.h, so the numbers are named here once.
        if ((m == 11) || (m == 12) || (m == 15) || (m == 6)) {
            return m;
        }
    }
    return 11;
}

// The settings sheet's half of the same table. idx 0 = yaw, 1 = pitch.
const char* SohVR_AimTrimName(int row) {
    if (row == SOHVR_AIMTRIM_SLINGSHOT) {
        return "slingshot";
    }
    return SohVR_ItemCalName(row);
}

float SohVR_AimTrim(int config, int model, int idx) {
    if (config < 0 || config > 1 || model < 0 || model >= SOHVR_AIMTRIM_N || idx < 0 || idx > 1) {
        return 0.0f;
    }
    return gSohVRAimTrimDeg[model][config][idx];
}

// R15: the aim crosshair option, from the settings sheet.
void SohVR_SetAimReticle(int on) {
    gSohVRAimReticle = on ? 1 : 0;
}

void SohVR_SetAimTrim(int config, int model, int idx, float v) {
    if (config < 0 || config > 1 || model < 0 || model >= SOHVR_AIMTRIM_N || idx < 0 || idx > 1) {
        return;
    }
    gSohVRAimTrimDeg[model][config][idx] = v;
}

// The live read-out row. -1 = no bow has been drawn this run, 1 = the last
// nocked frame aimed from the hand, 0 = it fell back to vanilla's own
// arithmetic. R13 shipped a mechanism that never ran and there was no way to
// see that from inside the headset; this is that way.
int SohVR_AimPath(void) {
    return gSohVRAimPath;
}
int SohVR_AimShots(int vanilla) {
    return (int)(vanilla ? gSohVRAimVanillaShots : gSohVRAimShots);
}

// --- R8 item 2: THE ROLL, AND WHY IT ORBITS ---------------------------------
//
// the user, on 1.0.1.10: holding the controller straight out, fist closed, palm
// facing left, then rotating ONLY his hand so the palm faces up, "made the hand
// ROLL around my actual hands/controllers instead of just rotating the hand IN
// PLACE."
//
// THE CHAIN IS RIGID, and the suite now asserts that rather than assuming it:
// `vr hands` publishes rigid_m = inverse(raw anchor) * calibrated palm, and
// S18.1 sweeps injected anchor rotations with the solver running and requires
// it to be CONSTANT. A rigid attach cannot be the cause of an orbit.
//
// THE CAUSE IS THE OFFSET, and it is arithmetic on his own numbers. `pose * C`
// puts the hand's origin at p + q*t, so when q rolls by an angle the hand
// origin sweeps a circle whose radius is the part of t perpendicular to the
// roll axis. The roll axis here is the controller's own z, so that radius is
// hypot(x, y):
//
//   left  : hypot(-13.5, -11.0) = 17.4 cm
//   right : hypot(  1.0,  -9.5) =  9.6 cm
//
// A 90-degree wrist roll therefore swings Link's left hand through a 17 cm arc.
// That is not a bug in the composition; it is what a rigid body 17 cm from its
// pivot does, and it also explains the asymmetry the user noticed between his two
// hands -- the left offset is nearly twice the right one.
//
// WHY THE OFFSET IS THAT BIG, which is the part worth acting on. A wrong
// ROTATION can always be compensated at ONE pose by a translation, and the
// dialling procedure -- hold a comfortable neutral pose, move sliders until the
// hands look right -- is exactly a one-pose fit. The code comment above already
// warned about this class ("invisible at one pose and wrong everywhere else");
// this is that warning coming true from the other direction. The physical
// grip-to-palm offset on a Sense unit is a few centimetres, not seventeen.
//
// R9 PART A: THE REAL FIX, AND WHY R8's READING WAS ONLY HALF OF IT. R8 said
// the offsets were large because a wrong rotation had been compensated by a
// translation. True, but incomplete: the ANCHOR ORIGIN IS NOT WHERE THE
// CONTROLLER IS HELD. An accessory anchor sits at the origin of the accessory's
// MODEL, which on a Sense is centimetres up the barrel from the fist -- so a
// large part of what the user dialled was him hand-fitting that lever arm.
//
// visionOS 26 publishes the grip point directly
// (`ar_accessory_anchor_get_anchor_from_location_transform_with_correction`
// with `ar_accessory_location_name_grip`), so SohSense now composes
// anchor x anchorFromGrip and publishes THAT as the hand pose. The pivot of a
// wrist roll and the origin of the pose are then the same point, and the
// offsets above are zero.
//
// R8's REJECTED alternative -- a synthetic "pivot" knob -- stays rejected, and
// this is not it. A pivot knob invents a pivot; this reads the real one out of
// the runtime. The distinction is the whole reason the fix is allowed to change
// his numbers: it is not hiding a symptom, it is moving the pose onto the point
// the symptom was measured about.
//
// THE ANCHOR GIZMO IS GONE (the user, on 1.0.1.12: "the anchors are just a guide,
// doesn't solve our problem. Can remove."). Its job was to make the anchor
// origin visible so the two halves of a one-pose fit could be separated by eye;
// with the pose sitting on the grip there is nothing left for it to disambiguate.
// The last calibrated palm pose and the raw anchor it came from, so `vr hands`
// can show the calibration rather than assert it (R7 verdict 2's last clause).
// R10 verdict 1: the sky's seat this frame, in GAME space, so the suite can
// assert that it tracks the eye rather than the game camera. Published beside
// the eye's own game position (sohvr_eyeGame), which is what it must track.
static simd_float3 sohvr_skySeat;

static simd_float4x4 sohvr_handRawPose[2];
static simd_float4x4 sohvr_handCalPose[2];
// R8 part B: the pose actually PUBLISHED to the game -- calibrated, then
// moved by the attack envelope. Kept beside the calibrated one so the R8
// part A rigidity assertion still has an un-thrust palm to read: an
// envelope is not a calibration error and must not look like one.
static simd_float4x4 sohvr_handAtkPose[2];

static simd_float4x4 sohvr_hand_calibration(int hand) {
    const float d2r = (float)M_PI / 180.0f;
    float yaw = sohvr_handRotDeg[hand][0] * d2r;
    float pitch = sohvr_handRotDeg[hand][1] * d2r;
    float roll = sohvr_handRotDeg[hand][2] * d2r;
    simd_quatf qy = simd_quaternion(yaw, simd_make_float3(0, 1, 0));
    simd_quatf qp = simd_quaternion(pitch, simd_make_float3(1, 0, 0));
    simd_quatf qr = simd_quaternion(roll, simd_make_float3(0, 0, 1));
    simd_float4x4 m = simd_matrix4x4(simd_normalize(simd_mul(qy, simd_mul(qp, qr))));
    m.columns[3] = simd_make_float4(sohvr_handOffCm[hand][0] * 0.01f, sohvr_handOffCm[hand][1] * 0.01f,
                                    sohvr_handOffCm[hand][2] * 0.01f, 1.0f);
    return m;
}

// Applied on the RIGHT of the tracked pose: the hand turns about its own
// origin, and the offset is expressed in the controller's frame.
static simd_float4x4 sohvr_apply_hand_calibration(int hand, simd_float4x4 pose) {
    return simd_mul(pose, sohvr_hand_calibration(hand));
}

// --- R14: THE AIM AXIS BELONGS TO ONE FRAME, AND IT IS THE SWORD HAND'S -----
//
// The aim axis table ships (1, 0, 0) and the reason is specific: the sword's
// blade runs along the L_HAND limb's +X, and the hand calibration was dialled
// against the SWORD's fist -- so in the sword hand, and only there, limb +X is
// where a calibrated controller points. The bow and the slingshot are in the
// OTHER hand, whose row of kSohVRHandCal differs by as much as ninety degrees
// of yaw, and the same local axis there is not the pointing direction at all.
//
// So the table stays expressed in the sword hand's frame and this publishes the
// rotation that carries a vector out of it into hand h's own frame:
//
//     hand pose  = raw * C_h              (sohvr_apply_hand_calibration)
//     pointing   = raw * C_s * xhat       (what the sword hand's calibration means)
//                = (raw * C_h) * (C_h^-1 * C_s * xhat)
//
// i.e. Fix[h] = C_h^-1 * C_s, rotation only -- identity for the sword hand by
// construction, which is the check `vr aim` prints. Recomputed every frame
// because it costs two 3x3 multiplies and a calibration that changed between
// frames must never be half applied.
static void sohvr_publish_aim_handfix(void) {
    int swordHand = (gSohVRLeftHanded != 0) ? 0 : 1;
    simd_float3x3 rs;
    {
        simd_float4x4 m = sohvr_hand_calibration(swordHand);
        rs = simd_matrix(m.columns[0].xyz, m.columns[1].xyz, m.columns[2].xyz);
    }
    for (int h = 0; h < 2; h++) {
        simd_float4x4 m = sohvr_hand_calibration(h);
        simd_float3x3 rh = simd_matrix(m.columns[0].xyz, m.columns[1].xyz, m.columns[2].xyz);
        simd_float3x3 fix = simd_mul(simd_transpose(rh), rs); // columns
        for (int c = 0; c < 3; c++) {
            for (int r = 0; r < 3; r++) {
                // Published ROW-major: the consumer computes dot(row, axis).
                gSohVRAimHandFix[h][(r * 3) + c] = fix.columns[c][r];
            }
        }
    }
}

// The inverse of sohvr_to_game for a POINT: game world units back to tracking
// metres. The physical blade needs it because OoT's collision mesh only exists
// in game units and the contact solver only speaks metres -- and the solver
// speaking metres is the whole reason its thresholds are physical (0.012 m of
// blade radius is 0.012 m at any world scale).
static simd_float3 sohvr_track_to_game_pt(SohVRSeat seat, simd_float3 track) {
    simd_float3 local = (track - sohvr_roomOrigin) * sohvr_scale;
    return simd_mul(seat.Rg, simd_make_float4(local, 0.0f)).xyz + seat.anchor;
}

static simd_float3 sohvr_game_to_track_pt(SohVRSeat seat, simd_float3 g) {
    simd_float3 local = simd_mul(simd_transpose(seat.Rg), simd_make_float4(g - seat.anchor, 0.0f)).xyz;
    return local / sohvr_scale + sohvr_roomOrigin;
}

// A . V . P for one eye, published in Fast3D ROW-VECTOR order.
// Row-vector f[i][j] such that clip = v_row * f, from a column-vector
// clip = VP * v: f[i][j] = VP[j][i] = vp.columns[i][j].
static void sohvr_compose_eye(simd_float4x4 gamePose, simd_float4x4 proj, float out[16]) {
    simd_float4x4 vp = simd_mul(proj, simd_inverse(gamePose));
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            out[i * 4 + j] = vp.columns[i][j];
        }
    }
}

// Donor VR_GetCullingFovy shape (vr_openxr.cpp:1968-1982): the WIDER eye's
// vertical FOV, padded 1.3x, clamped to [90,160] deg, default 100. Deliberately
// errs wide — over-wide costs a little geometry, too narrow reintroduces the
// edge pop-in the whole unification exists to stop.
static float sohvr_culling_fovy(void) {
    float best = 0.0f;
    for (int e = 0; e < 2; e++) {
        float v = atanf(sohvr_contract.tanT[e]) - atanf(sohvr_contract.tanB[e]);
        if (v > best) {
            best = v;
        }
    }
    float deg = best * (180.0f / (float)M_PI) * 1.3f;
    if (!(deg > 1.0f)) {
        return 100.0f;
    }
    return deg < 90.0f ? 90.0f : (deg > 160.0f ? 160.0f : deg);
}

// --- shell-facing accessors ----------------------------------------------------
int SohVR_SpaceVariant(void) {
    return sohvr_variant;
}
int SohVR_StyleIsFull(void) {
    return sohvr_styleFull;
}
int SohVR_IsActive(void) {
    return gSohVRMode;
}

// spec D1's tri-state, in ONE place. Soh_Get3DMode() is the engine's
// offscreen flag and is set for BOTH immersive modes, so it can never
// distinguish them — the R0 rough edge where `vr off` tore down the 3D panel
// was exactly that conflation.
int Soh_GetMode(void) {
    if (gSohVRMode) {
        return 2; // vr
    }
    return Soh_Get3DMode() ? 1 : 0; // panel3D / flat
}

void SohVR_Recenter(void) {
    sohvr_recenterReq = 1; // serviced on the loop thread against the live pose
}

// R8 item 5: the settings sheet's "Re-calibrate VR height" button, and the same
// path VR entry and every first-person re-entry take. There is exactly one
// calibration in the program and this is it.
void SohVR_RecalibrateHeight(void) {
    sohvr_heightCalReq = 1;
}

// R9 part A item 2: THE SWORD HAND. the user: "we need an option to switch hands
// (default is sword on right hand), for left-handed people or to match how Link
// does it." There is exactly one variable and every consumer derives from it:
// the limb override and its mirror (overlay 0042), the physical blade's
// SohVrSwordHand() (0048), the parametric shield's hand (0049), the item
// wheel's hand (0051, sword hand or off hand per gSohVRItemSelHandCfg), the
// item TRIGGER reservation (0047) and the attack envelope's seam here in
// SohImmersive.m. Adding a second copy of this truth is how half of them would
// swap and half would not.
//
// The per-hand CALIBRATION constants are deliberately NOT swapped: they are
// per CONTROLLER (a left Sense unit is a different shape held a different way),
// not per role.
void SohVR_SetLeftHanded(int on) {
    gSohVRLeftHanded = on ? 1 : 0;
    // R14 item 3: THE HAND SLIDERS ARE GONE, so nothing pushes the twenty-four
    // numbers any more and this is where the configuration's row is selected.
    // It used to be SohVRHandCalKeys.push(); deleting a settings row without
    // moving what it did is how a constant quietly stops being applied (the
    // note beside applyAll in SohVisionApp.swift is about exactly this).
    // `vr set hand*` still writes the live arrays, and still loses to the next
    // configuration switch -- which is what a debug dial should do.
    for (int h = 0; h < 2; h++) {
        for (int i = 0; i < 3; i++) {
            sohvr_handOffCm[h][i] = kSohVRHandCal[gSohVRLeftHanded ? 1 : 0][h][i];
            sohvr_handRotDeg[h][i] = kSohVRHandCal[gSohVRLeftHanded ? 1 : 0][h][3 + i];
        }
    }
}

// R8 item 4: the world scale is HARDCODED at 34 and this is an EXPERIMENT hook
// only -- nothing persists it, nothing pushes it at VR entry, and the settings
// sheet no longer has a row for it. It keeps gSohVRWorldScale in step because
// the item compass measures its flick in centimetres of real hand travel and
// has to convert with the same number the seat uses.
void SohVR_SetWorldScale(float unitsPerMetre) {
    if (unitsPerMetre > 5.0f && unitsPerMetre < 500.0f) {
        sohvr_scale = unitsPerMetre;
        gSohVRWorldScale = unitsPerMetre;
    }
}

// R8 item 5: the ONE height knob, a signed trim in metres from the calibrated
// state. The sheet's range is +/-0.5; the guard here is wider on purpose so a
// console sweep is not silently clamped to the UI's taste.
void SohVR_SetHeightTrim(float metres) {
    if (metres > -2.0f && metres < 3.0f) {
        sohvr_height = metres;
    }
}

void SohVR_SetFlatWorldBackdrop(int on) {
    sohvr_flatWorldBackdrop = on ? 1 : 0;
}

// R2a: the pre-rendered-room treatment (spec D3 extension, donor §5b).
// 0 panel / 1 flat / 2 3d. Publishing the value is what overlay 0039 rev2's
// latch and overlay 0040 rev2's enhancement gate both read; the re-apply is
// needed because 3DSceneRender installs its hooks through RegisterShipInitFunc
// and only ShipInit::Init re-runs them.
void SohVR_SetRoomMode(int mode) {
    if (mode < 0 || mode > 2) {
        mode = 0;
    }
    if (mode == gSohVRRoomMode) {
        return;
    }
    gSohVRRoomMode = mode;
    extern void SohVR_ReapplyRoomMode(void); // SohHostViewController.m
    SohVR_ReapplyRoomMode();
}
int SohVR_GetRoomMode(void) {
    return gSohVRRoomMode;
}
void SohVR_SetEyeScale(float s) {
    if (s >= 0.25f && s <= 2.0f) {
        sohvr_eyeScale = s;
    }
}
float SohVR_GetEyeScale(void) {
    return sohvr_eyeScale;
}

float SohVR_GetWorldScale(void) {
    return sohvr_scale;
}

// --- R2b live tunables (settings sheet + `vr set`) ----------------------------
void SohVR_SetHudPlane(int on) {
    gSohVRHudPlane = on ? 1 : 0;
}
int SohVR_GetHudPlane(void) {
    return gSohVRHudPlane;
}
// R8 item 7: SohVR_Set/GetHudDistance are GONE. The distance is fixed at
// 2.0 m; `vr set huddist` remains for an experiment and does not persist.
void SohVR_SetHudWidth(float metres) {
    if (metres >= 0.2f && metres <= 6.0f) {
        sohvr_hudWidth = metres;
    }
}
// R8 item 7: the HUD's height above eye level. The sheet's range is +/-1.0 m
// and shows the sign; the guard is wider so a console sweep is not clamped to
// the UI's taste. the user will pick the default from the headset; ships 0.0.
void SohVR_SetHudUp(float metres) {
    if (metres >= -2.0f && metres <= 2.0f) {
        sohvr_hudUp = metres;
    }
}
// R7 verdict 2: the same six numbers per hand, for the settings sheet. the user
// asked for "temporary settings to adjust them" -- so they get rows, not only a
// console command: a console needs a Mac on the tailnet, and he is wearing the
// headset.
// R7 verdict 5: the flip camera, default ON (the user's call).
void SohVR_SetFlipCam(int on) {
    sohvr_flipCam = on ? 1 : 0;
    if (!sohvr_flipCam) {
        sohvr_flipAngle = 0.0f;
    }
}
int SohVR_GetFlipCam(void) {
    return sohvr_flipCam;
}

void SohVR_SetHandOffset(int hand, float xCm, float yCm, float zCm) {
    if (hand < 0 || hand > 1) {
        return;
    }
    sohvr_handOffCm[hand][0] = xCm;
    sohvr_handOffCm[hand][1] = yCm;
    sohvr_handOffCm[hand][2] = zCm;
}
void SohVR_SetHandRotation(int hand, float yawDeg, float pitchDeg, float rollDeg) {
    if (hand < 0 || hand > 1) {
        return;
    }
    sohvr_handRotDeg[hand][0] = yawDeg;
    sohvr_handRotDeg[hand][1] = pitchDeg;
    sohvr_handRotDeg[hand][2] = rollDeg;
}

float SohVR_GetHudWidth(void) {
    return sohvr_hudWidth;
}
// R3: 0 = SMOOTH (default), else the snap angle. One knob, one slider.
void SohVR_SetTurnDegrees(float deg) {
    if (deg >= 0.0f && deg <= 90.0f) {
        sohvr_turnDeg = deg;
    }
}
float SohVR_GetTurnDegrees(void) {
    return sohvr_turnDeg;
}
void SohVR_SetSmoothTurnSpeed(float degPerSec) {
    if (degPerSec >= 30.0f && degPerSec <= 360.0f) {
        sohvr_smoothDegPerSec = degPerSec;
    }
}
float SohVR_GetSmoothTurnSpeed(void) {
    return sohvr_smoothDegPerSec;
}
void SohVR_SetHideBody(int on) {
    gSohVRHideBody = on ? 1 : 0;
}
int SohVR_GetHideBody(void) {
    return gSohVRHideBody;
}
void SohVR_SetBodyFollowsHead(int on) {
    gSohVRBodyFollowsHead = on ? 1 : 0;
}
int SohVR_GetBodyFollowsHead(void) {
    return gSohVRBodyFollowsHead;
}
// R8 item 9: SohVR_Set/GetLockOnFraming are GONE with the option they served.
// R8 item 5: SohVR_SetEyeHeightOffset is GONE too. gSohVRHeadHeightOffset stays
// a constant at its donor-tuned -9 game units, set once in SohIosShell.m and
// changed by nothing but `vr set eyeoffset` for an experiment. It was never a
// user knob in any honest sense -- "head trim, in game units, on top of Link's
// own height" is an implementation detail, and shipping it beside a metres-based
// eye height gave the wearer two ways to say the same thing and no way to know
// which one had drifted.
float SohVR_GetEyeHeightOffset(void) {
    return gSohVRHeadHeightOffset;
}
void SohVR_SetEyeBudget(float px) {
    if (px >= 256.0f && px <= 8192.0f) {
        sohvr_eyeBudget = (double)px;
    }
}
float SohVR_GetEyeBudget(void) {
    return (float)sohvr_eyeBudget;
}

// --- the blit pipeline ---------------------------------------------------------
static id<MTLRenderPipelineState> sohvr_blitPipeline;
static id<MTLRenderPipelineState> sohvr_blitDepthPipeline; // R1: with depth handoff
static id<MTLRenderPipelineState> sohvr_clearPipeline;
static id<MTLRenderPipelineState> sohvr_hudPipeline; // R2b: the HUD plane (spec D7)
static id<MTLDepthStencilState> sohvr_depthState;
// Uniform mirror of the shader's SohVRDepthCvt. Kept next to the shader source
// so the two can only be changed together.
typedef struct {
    float n, f, nearMScale, enabled;
} SohVRDepthCvt;

static NSString* const kSohVRShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut { float4 pos [[position]]; float2 uv; };\n"
     "vertex VOut sohvr_vs(uint vid [[vertex_id]]) {\n"
     "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
     "  VOut o; o.pos = float4(p[vid], 0.5, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 sohvr_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                         constant float& srgbDecode [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  return float4(c.rgb, 1.0);\n"
     "}\n"
     // R1 DEPTH HANDOFF (spec D2 / D-044). R0 measured that the compositor
     // is reverse-Z with an INFINITE far plane while Fast3D is forward-Z, so
     // this is a CONVERSION, never a copy — blitting engine depth straight in
     // would invert the reprojection. Uniform layout must match SohVRDepthCvt.
     //   d      = f*n / (z_fwd*(n - f) + f)      (game units, from the engine)
     //   z_rev  = (near_m * scale) / d           (reverse-Z, far at infinity)
     "struct SohVRDepthCvt { float n; float f; float nearMScale; float enabled; };\n"
     "struct SohVRFOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };\n"
     "fragment SohVRFOut sohvr_fs_depth(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                                  depth2d<float> dep [[texture(1)]],\n"
     "                                  constant float& srgbDecode [[buffer(0)]],\n"
     "                                  constant SohVRDepthCvt& cvt [[buffer(1)]]) {\n"
     "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "  constexpr sampler sd(filter::nearest, address::clamp_to_edge);\n"
     "  SohVRFOut o;\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  o.color = float4(c.rgb, 1.0);\n"
     "  float zf = dep.sample(sd, in.uv);\n"
     "  float den = zf * (cvt.n - cvt.f) + cvt.f;\n"
     "  float d = (abs(den) > 1e-6) ? (cvt.f * cvt.n / den) : cvt.f;\n"
     "  o.depth = clamp(cvt.nearMScale / max(d, 1e-3), 0.0, 1.0);\n"
     "  return o;\n"
     "}\n"
     "fragment float4 sohvr_solid_fs(constant float4& col [[buffer(0)]]) { return col; }\n"
     // R2b (spec D7): THE HUD PLANE. A textured quad placed in front of the
     // head and drawn with each eye's OWN projection, which is the entire point
     // -- the same pixels at the same world placement, seen from two eyes, have
     // real disparity and fuse. Depth comes free: mvp already carries the
     // compositor's reverse-Z/infinite-far matrix, so pos.z/pos.w IS the device
     // depth the reprojector wants. Fully transparent texels are DISCARDED so
     // they do not stamp HUD depth over the world behind them.
     "vertex VOut sohvr_quad_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
     "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
     "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
     "  return o;\n"
     "}\n"
     // R7 verdict 7. the user: "there's no HUD anywhere. i can't see my hearts,
     // my c buttons, etc." -- and every counter said the pipeline was healthy:
     // hud_dl=1, hud_frames climbing, hud_dl_races=0, hud_presents climbing,
     // hud_tag == pair_tag. The counters were all telling the truth. rev2's
     // `vr hudprobe` copied the HUD framebuffer back and read it, and the answer
     // was unambiguous: 156,770 texels carrying COLOUR and exactly ZERO carrying
     // alpha (a_mean=0 over 1.92 M texels). Documents/vr-hud.png is a complete,
     // correct HUD -- three hearts, the B and C items, the rupee counter, the
     // Hyrule Field minimap -- painted on a fully transparent black field.
     //
     // So the line below was discarding the entire interface, every frame, on
     // an alpha channel that OoT's texrect path never writes. The N64 blender
     // composites COLOUR; nothing in that pipeline has a reason to leave
     // coverage behind in the destination alpha, and our framebuffer starts
     // cleared to alpha 0. The sibling port hit the same wall from the other
     // direction (SpaghettiKart R13: an MSAA normalisation moved its HUD
     // framebuffer onto a pipeline whose alpha factors were (Zero, One), and
     // "the HUD plane composited float4(rgb, 0.0): invisible, in every view
     // mode"). Same symptom, same cause, same lesson -- a HUD's coverage cannot
     // be assumed, it has to be produced.
     //
     // THE KEY. Coverage is derived from the colour instead: the framebuffer is
     // cleared to black and the HUD is painted onto it, so anything that is not
     // black is HUD. `keyGain` turns a dim texel fully opaque well before it
     // looks dim to a viewer, which keeps antialiased glyph edges soft while
     // making the body of every icon solid.
     //
     // ITS ONE HONEST COST, stated rather than discovered later: a HUD texel
     // that is genuinely BLACK is indistinguishable from the cleared field, so
     // OoT's black glyph outlines and drop shadows come through as holes rather
     // than as black. That is a visible artifact and it is enormously better
     // than no HUD at all; the proper fix is engine-side -- have the HUD
     // framebuffer accumulate real destination alpha -- and it is recorded as
     // the next step rather than attempted in the same change that made the
     // interface visible for the first time. `vr set hudkey 0` restores the
     // alpha-only path, which is the A/B for that work when it lands.
     "fragment float4 sohvr_hud_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
     "                             constant float2& hudParams [[buffer(0)]]) {\n"
     "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "  float4 c = tex.sample(s, in.uv);\n"
     "  float a = c.a;\n"
     "  if (hudParams.y > 0.0) {\n"
     "    // The KNEE matters as much as the gain. A bare multiply keyed in the\n"
     "    // framebuffer's own near-black background too (its mean channel is 5\n"
     "    // of 255, not 0) and hung a translucent grey veil over the whole HUD\n"
     "    // rectangle -- visible in the world as a haze band and a panel behind\n"
     "    // the minimap. Subtracting the knee first makes anything at or below\n"
     "    // ~6% exactly zero, so the background is discarded while every icon\n"
     "    // and glyph, which are far brighter, still saturates immediately.\n"
     "    a = max(a, saturate((max(c.r, max(c.g, c.b)) - 0.06) * hudParams.y));\n"
     "  }\n"
     "  if (a < 0.02) discard_fragment();\n"
     "  if (hudParams.x > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
     "  return float4(c.rgb * a, a);\n"
     "}\n";

static void sohvr_build_pipeline(id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kSohVRShader options:nil error:&err];
    if (!lib) {
        NSLog(@"[SohVR] shader compile FAILED: %@", err.localizedDescription);
        return;
    }
    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"sohvr_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"sohvr_fs"];
    pd.colorAttachments[0].pixelFormat = colorFmt;
    pd.depthAttachmentPixelFormat = depthFmt;
    // R2b: the HUD plane, premultiplied-alpha over the world.
    MTLRenderPipelineDescriptor* hp = [MTLRenderPipelineDescriptor new];
    hp.vertexFunction = [lib newFunctionWithName:@"sohvr_quad_vs"];
    hp.fragmentFunction = [lib newFunctionWithName:@"sohvr_hud_fs"];
    hp.colorAttachments[0].pixelFormat = colorFmt;
    hp.colorAttachments[0].blendingEnabled = YES;
    hp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    hp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    hp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    hp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    hp.depthAttachmentPixelFormat = depthFmt;
    sohvr_hudPipeline = [dev newRenderPipelineStateWithDescriptor:hp error:&err];
    if (!sohvr_hudPipeline) {
        NSLog(@"[SohVR] HUD plane pipeline FAILED: %@", err.localizedDescription);
    }
    sohvr_blitPipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!sohvr_blitPipeline) {
        NSLog(@"[SohVR] blit pipeline FAILED: %@", err.localizedDescription);
    }
    // R1: the same blit, writing a CONVERTED depth (spec D2). Built beside
    // the plain one so a shader failure degrades to R0 behaviour instead of a
    // black world.
    MTLRenderPipelineDescriptor* dpd = [MTLRenderPipelineDescriptor new];
    dpd.vertexFunction = [lib newFunctionWithName:@"sohvr_vs"];
    dpd.fragmentFunction = [lib newFunctionWithName:@"sohvr_fs_depth"];
    dpd.colorAttachments[0].pixelFormat = colorFmt;
    dpd.depthAttachmentPixelFormat = depthFmt;
    sohvr_blitDepthPipeline = [dev newRenderPipelineStateWithDescriptor:dpd error:&err];
    if (!sohvr_blitDepthPipeline) {
        NSLog(@"[SohVR] depth blit pipeline FAILED: %@", err.localizedDescription);
    }
    MTLRenderPipelineDescriptor* cd = [MTLRenderPipelineDescriptor new];
    cd.vertexFunction = [lib newFunctionWithName:@"sohvr_vs"];
    cd.fragmentFunction = [lib newFunctionWithName:@"sohvr_solid_fs"];
    cd.colorAttachments[0].pixelFormat = colorFmt;
    cd.depthAttachmentPixelFormat = depthFmt;
    sohvr_clearPipeline = [dev newRenderPipelineStateWithDescriptor:cd error:&err];
    if (!sohvr_clearPipeline) {
        NSLog(@"[SohVR] clear pipeline FAILED: %@", err.localizedDescription);
    }
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES; // the compositor reprojects on depth
    sohvr_depthState = [dev newDepthStencilStateWithDescriptor:dd];
    NSLog(@"[SohVR] pipelines built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt, (unsigned long)depthFmt);
}

// --- per-eye readback (the "both eyes measurably differ" proof) ----------------
static void sohvr_capture_eyes(id<MTLCommandQueue> queue) {
    for (int e = 0; e < 2; e++) {
        sohvr_captureHash[e] = 0;
        sohvr_captureMean[e] = 0;
        sohvr_captureW[e] = sohvr_captureH[e] = 0;
        id<MTLTexture> src = (__bridge id<MTLTexture>)Soh3D_GetEyeMTLTexture(e + 1);
        if (src == nil) {
            continue;
        }
        // Downsample by strided readback rather than a full 4K copy: a 256-wide
        // shared texture is enough for a hash + a PNG artifact.
        const int W = 256, H = (int)(256.0 * (double)src.height / (double)src.width);
        MTLTextureDescriptor* td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> dst = [src.device newTextureWithDescriptor:td];
        if (dst == nil) {
            continue;
        }
        // Blit cannot scale; render-blit through the sampling pipeline instead.
        MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = dst;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        NSError* err = nil;
        id<MTLLibrary> lib = [src.device newLibraryWithSource:kSohVRShader options:nil error:&err];
        pd.vertexFunction = [lib newFunctionWithName:@"sohvr_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"sohvr_fs"];
        pd.colorAttachments[0].pixelFormat = src.pixelFormat;
        id<MTLRenderPipelineState> ps = [src.device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (ps == nil) {
            NSLog(@"[SohVR] capture pipeline FAILED: %@", err.localizedDescription);
            continue;
        }
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
        float zero = 0.0f;
        [enc setRenderPipelineState:ps];
        [enc setFragmentBytes:&zero length:sizeof(zero) atIndex:0];
        [enc setFragmentTexture:src atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        size_t rowBytes = (size_t)W * 4;
        uint8_t* px = malloc(rowBytes * (size_t)H);
        [dst getBytes:px bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        uint32_t hash = 2166136261u;
        uint64_t sum = 0;
        BOOL bgra = (src.pixelFormat == MTLPixelFormatBGRA8Unorm || src.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
        for (size_t i = 0; i < rowBytes * (size_t)H; i++) {
            hash = (hash ^ px[i]) * 16777619u;
            sum += px[i];
        }
        sohvr_captureHash[e] = hash;
        sohvr_captureMean[e] = (uint32_t)(sum / (rowBytes * (size_t)H));
        sohvr_captureW[e] = (int)src.width;
        sohvr_captureH[e] = (int)src.height;
        // PNG artifact (RGBA, opaque) next to the logs.
        uint8_t* rgba = malloc(rowBytes * (size_t)H);
        for (size_t i = 0; i < rowBytes * (size_t)H; i += 4) {
            rgba[i + 0] = bgra ? px[i + 2] : px[i + 0];
            rgba[i + 1] = px[i + 1];
            rgba[i + 2] = bgra ? px[i + 0] : px[i + 2];
            rgba[i + 3] = 255;
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, W, H, 8, rowBytes, cs,
                                                 kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (img != NULL) {
            NSString* docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSString* path = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"vr-eye%d.png", e]];
            NSData* png = UIImagePNGRepresentation([UIImage imageWithCGImage:img]);
            [png writeToFile:path atomically:YES];
            CGImageRelease(img);
        }
        if (ctx != NULL) {
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
        free(rgba);
        free(px);
    }
}

// --- R7 verdict 7: the HUD-plane PROBE ---------------------------------------
//
// THE QUESTION THIS ANSWERS. the user, 2026-09-04: "there's no HUD anywhere. i
// can't see my hearts, my c buttons, etc." -- and every counter said the
// mechanism was healthy: hud_dl=1, hud_frames climbing, hud_dl_races=0,
// hud_presents climbing, hud_tag == pair_tag. A pipeline that runs every frame
// and produces nothing visible is not a plumbing bug, it is a CONTENT bug, and
// the only way to tell those apart is to look at the pixels the plane is
// sampling. So: copy the HUD framebuffer back and report what is actually in
// it -- how many texels carry any alpha at all, how many carry any colour, and
// the means of both. `hud_a_nonzero=0` with `hud_rgb_nonzero` large says the
// HUD was drawn and its ALPHA was never written, which the plane's
// `discard_fragment()` on a < 0.004 then throws away in full.
static uint32_t sohvr_hudProbeANonzero = 0, sohvr_hudProbeRGBNonzero = 0;
static uint32_t sohvr_hudProbeAMean = 0, sohvr_hudProbeRGBMean = 0;
static uint32_t sohvr_hudProbeTexels = 0;
static uint64_t sohvr_hudProbes = 0;

static void sohvr_probe_hud(id<MTLCommandQueue> queue) {
    sohvr_hudProbeANonzero = sohvr_hudProbeRGBNonzero = 0;
    sohvr_hudProbeAMean = sohvr_hudProbeRGBMean = sohvr_hudProbeTexels = 0;
    void* ht = NULL;
    unsigned int htag = 0;
    Soh3DHudSnapshot(&ht, &htag);
    id<MTLTexture> src = (__bridge id<MTLTexture>)ht;
    if (src == nil || queue == nil) {
        return;
    }
    // A RAW blit, never a render-blit: the sampling shader forces alpha to 1,
    // which is precisely the value under investigation.
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                                  width:src.width
                                                                                 height:src.height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> dst = [src.device newTextureWithDescriptor:td];
    if (dst == nil) {
        return;
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:src
                sourceSlice:0
                sourceLevel:0
               sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(src.width, src.height, 1)
                  toTexture:dst
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    size_t W = src.width, H = src.height, rowBytes = W * 4;
    uint8_t* px = malloc(rowBytes * H);
    if (px == NULL) {
        return;
    }
    [dst getBytes:px bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    uint64_t aSum = 0, rgbSum = 0;
    uint32_t aNz = 0, rgbNz = 0;
    for (size_t i = 0; i < rowBytes * H; i += 4) {
        // Alpha is the last byte in every 8-bit-per-channel format we use
        // (RGBA8 and BGRA8 alike), which is why the channel order above does
        // not need resolving here.
        uint32_t a = px[i + 3];
        uint32_t rgb = (uint32_t)px[i + 0] + px[i + 1] + px[i + 2];
        aSum += a;
        rgbSum += rgb;
        if (a > 1) {
            aNz++;
        }
        if (rgb > 3) {
            rgbNz++;
        }
    }
    sohvr_hudProbeTexels = (uint32_t)(W * H);
    sohvr_hudProbeANonzero = aNz;
    sohvr_hudProbeRGBNonzero = rgbNz;
    sohvr_hudProbeAMean = (uint32_t)(aSum / (W * H));
    sohvr_hudProbeRGBMean = (uint32_t)(rgbSum / (W * H * 3));
    sohvr_hudProbes++;
    // The picture, so a human can see WHAT was in the framebuffer as well as
    // how much: alpha forced opaque so an all-alpha-zero HUD still shows its
    // colour, which is the exact case being diagnosed.
    uint8_t* rgba = malloc(rowBytes * H);
    if (rgba != NULL) {
        BOOL bgra = (src.pixelFormat == MTLPixelFormatBGRA8Unorm || src.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB);
        for (size_t i = 0; i < rowBytes * H; i += 4) {
            rgba[i + 0] = bgra ? px[i + 2] : px[i + 0];
            rgba[i + 1] = px[i + 1];
            rgba[i + 2] = bgra ? px[i + 0] : px[i + 2];
            rgba[i + 3] = 255;
        }
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, W, H, 8, rowBytes, cs,
                                                 kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (img != NULL) {
            NSString* docs =
                [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
            NSData* png = UIImagePNGRepresentation([UIImage imageWithCGImage:img]);
            [png writeToFile:[docs stringByAppendingPathComponent:@"vr-hud.png"] atomically:YES];
            CGImageRelease(img);
        }
        if (ctx != NULL) {
            CGContextRelease(ctx);
        }
        CGColorSpaceRelease(cs);
        free(rgba);
    }
    free(px);
}

// --- R2a: the eye-pair gate (trap D35) ---------------------------------------
// Take a snapshot of both eyes UNDER THE ENGINE'S PUBLISH MUTEX and adopt it
// only if the two eyes carry the same tag. A split snapshot is counted and
// DISCARDED — the previous coherent pair stays current and is re-presented
// against its own anchor, which is a whole frame of head latency the
// compositor reprojects away, instead of two eyes rendered for two different
// head poses, which nothing can fix downstream.
//
// The adopted textures are held in ARC strong statics on purpose: the engine's
// retire ring releases the incumbent one publish later, and a pair we intend
// to re-present must outlive that.
static unsigned int sohvr_take_pair(void) {
    void* tex[2] = { NULL, NULL };
    void* dep[2] = { NULL, NULL };
    unsigned int tag[2] = { 0, 0 };
    Soh3DEyePairSnapshot(tex, dep, tag);
    if (tex[0] == NULL || tex[1] == NULL) {
        return sohvr_pairTag; // nothing published yet for one of the eyes
    }
    if (tag[0] != tag[1]) {
        sohvr_pairSplits++;
        return sohvr_pairTag;
    }
    if (tag[0] == 0 || tag[0] == sohvr_pairTag) {
        return sohvr_pairTag; // untagged (pre-VR) or simply unchanged
    }
    sohvr_pairTex[0] = (__bridge id<MTLTexture>)tex[0];
    sohvr_pairTex[1] = (__bridge id<MTLTexture>)tex[1];
    sohvr_pairDepth[0] = (__bridge id<MTLTexture>)dep[0];
    sohvr_pairDepth[1] = (__bridge id<MTLTexture>)dep[1];
    sohvr_pairTag = tag[0];
    sohvr_pairAccepts++;
    if (sohvr_pairAccepts == 1) {
        extern void SohIos_VrNote(const char* what, const char* detail);
        char sohDetail[128];
        snprintf(sohDetail, sizeof(sohDetail), "tag=%u eye=%dx%d", tag[0], (int)gSoh3DEyeW, (int)gSoh3DEyeH);
        SohIos_VrNote("first eye pair accepted", sohDetail);
    }
    return sohvr_pairTag;
}

// The anchor a given pose seq was published with (NULL if it has aged out of
// the ring, which at 8 entries and 120 Hz is 66 ms).
static ar_device_anchor_t sohvr_anchor_for_seq(unsigned int seq) {
    int ri = (int)(seq % SOHVR_ANCHOR_RING);
    return (sohvr_anchorRingSeq[ri] == seq) ? sohvr_anchorRing[ri] : NULL;
}

// --- the loop ------------------------------------------------------------------
void SohVR_Immersive_Run(cp_layer_renderer_t layer_renderer) {
    // R8 part C: AN ALTERNATE SIGNAL STACK ON THIS THREAD. The shell installs
    // one on the thread that arms the handlers, and sigaltstack is PER THREAD --
    // so a stack-overflow SIGSEGV on the immersive render thread, the deepest
    // stack in the app and the one that runs three interpreter walks a frame,
    // had nowhere to run a handler and produced nothing at all. The handlers
    // themselves are already installed with SA_ONSTACK.
    {
        static char sSohVRAltStack[SIGSTKSZ * 4];
        stack_t sohSs = { .ss_sp = sSohVRAltStack, .ss_size = sizeof(sSohVRAltStack), .ss_flags = 0 };
        sigaltstack(&sohSs, NULL);
    }
    gSohVRStop = 0;
    gSohVRRunning = 1;
    int notifyEnded = 0;
    id<MTLCommandQueue> queue = nil;
    sohvr_frameCount = 0;
    sohvr_presents = 0;
    sohvr_anchored = 0;
    sohvr_reason = "starting";
    memset(&sohvr_contract, 0, sizeof(sohvr_contract));

    ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
    ar_world_tracking_provider_t wtp = ar_world_tracking_provider_create(wtc);
    ar_session_t arSession = ar_session_create();
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(wtp, NULL);
    ar_session_run(arSession, providers);
    // R4: the hand source. Discovery is async and the accessory provider runs
    // on its OWN session (SohSense.m says why), so this is fire-and-forget --
    // the loop never waits on it and works exactly as R3 did until anchors
    // start arriving.
    SohVrPhys_Reset();
    // R8 item 5: every VR entry calibrates the height. Belt AND braces with the
    // first-person rising edge below -- the edge covers re-entering first person
    // within a session, this covers entering VR at all, and both land on the
    // same deferred servicing so neither can fire against an unconverged pose.
    sohvr_heightCalReq = 1;
    sohvr_yawResetReq = 1; // R16b: entering VR faces the wearer down the game's -Z
    sohvr_physLastT = 0.0;
    sohvr_bladeHitSeen[0] = gSohVRBladeHitSeq[0];
    sohvr_bladeHitSeen[1] = gSohVRBladeHitSeq[1];
    gSohVRBladeValid[0] = gSohVRBladeValid[1] = 0;
    SohVrPhys_SetMesh(NULL, 0);
    // R6: the previous session's recorded hand-matrix pointers are graph-pool
    // addresses that mean nothing now. Cleared at BOTH ends -- entry as well as
    // exit -- because an exit that never ran its teardown (a crash, a killed
    // space) would otherwise hand this session a table of live-looking garbage.
    SohVR_ClearHandMtxTable();
    // R10 verdict 5: EXPLICIT, because it is no longer implied. SohSense_Start
    // doffs every latch only when discovery was off, and the flat-mode pump
    // (SohVR_SenseFlatPump) may have turned it on long before this entry. "A VR
    // exit with a trigger down must not leave that bit asserted" is a rule about
    // ENTRY as well, and it now says so in one line instead of resting on a
    // guard clause somewhere else.
    SohSense_InjectDoff();
    SohSense_Start();

    NSLog(@"[SohVR] render loop started (variant=%d world=%d scale=%.1f)", sohvr_variant, sohvr_worldMode,
          sohvr_scale);
    // R17 part B item 2(a)+(b): the loop's own line in vr-mem.log, and the entry
    // watchdog that is the only thing in the app able to notice a black entry
    // while it is still happening.
    {
        extern void SohIos_VrNote(const char* what, const char* detail);
        char sohDetail[160];
        snprintf(sohDetail, sizeof(sohDetail), "variant=%d world=%d scale=%.1f eye=%dx%d avail_mb=%ld",
                 sohvr_variant, sohvr_worldMode, sohvr_scale, (int)gSoh3DEyeW, (int)gSoh3DEyeH,
                 SohIos_AvailableMemoryMB());
        SohIos_VrNote("loop started", sohDetail);
    }
    sohvr_entryGen = sohvr_entryGen + 1;
    sohvr_layerState = -1;
    sohvr_pausedNoted = 0;
    {
        pthread_t sohEntryTh;
        if (pthread_create(&sohEntryTh, NULL, SohVR_EntryWatchdogThread, NULL) == 0) {
            pthread_detach(sohEntryTh);
        }
    }

    int running = 1;
    while (running) {
        if (gSohVRStop) {
            NSLog(@"[SohVR] stop requested, exiting cleanly (frames=%d)", sohvr_frameCount);
            sohvr_reason = "stopped";
            running = 0;
            continue;
        }
        sohvr_layerState = (int)cp_layer_renderer_get_state(layer_renderer);
        switch ((cp_layer_renderer_state)sohvr_layerState) {
            case cp_layer_renderer_state_paused:
                // Noted ONCE per entry: wait_until_running returns on every
                // system flap and a line per flap would bury the heartbeat.
                if (!sohvr_pausedNoted) {
                    extern void SohIos_VrNote(const char* what, const char* detail);
                    char sohDetail[96];
                    snprintf(sohDetail, sizeof(sohDetail), "frames=%d presents=%llu", sohvr_frameCount,
                             (unsigned long long)sohvr_presents);
                    SohIos_VrNote("layer paused", sohDetail);
                    sohvr_pausedNoted = 1;
                }
                cp_layer_renderer_wait_until_running(layer_renderer);
                continue;
            case cp_layer_renderer_state_invalidated:
                NSLog(@"[SohVR] layer invalidated, exiting loop (frames=%d)", sohvr_frameCount);
                // R7 verdict 9: an invalidation is one of the three ways the
                // 2026-09-04 death could have left no crash report at all, so
                // it is RECORDED, with the frame count and the memory headroom
                // at the moment it happened.
                {
                    char sohDetail[128];
                    snprintf(sohDetail, sizeof(sohDetail), "cp_layer invalidated frames=%d avail_mb=%ld",
                             sohvr_frameCount, SohIos_AvailableMemoryMB());
                    SohIos_ReportFatalContext("compositor", sohDetail);
                    extern void SohIos_VrNote(const char* what, const char* detail);
                    SohIos_VrNote("layer invalidated", sohDetail);
                }
                sohvr_reason = "invalidated";
                notifyEnded = 1;
                running = 0;
                continue;
            case cp_layer_renderer_state_running:
            default:
                break;
        }

        @autoreleasepool {
            cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
            if (frame == NULL) {
                continue;
            }
            cp_frame_timing_t timing = cp_frame_predict_timing(frame);
            cp_frame_start_update(frame);
            cp_frame_end_update(frame);
            cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
            cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
            if (drawable == NULL) {
                continue; // a failed query INVALIDATES the frame; end_submission would abort
            }

            id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
            if (queue == nil) {
                queue = [t0.device newCommandQueue];
                MTLPixelFormat dFmt = cp_drawable_get_depth_texture(drawable, 0).pixelFormat;
                sohvr_build_pipeline(t0.device, t0.pixelFormat, dFmt);
                // spec D3's flat contexts land on the EXISTING world-locked
                // panel machinery, so build the shipped panel pipelines here
                // too and let the panel re-anchor on the first flat entry.
                soh3d_build_pipeline(t0.device, t0.pixelFormat, dFmt);
                soh3d_haveScreenAnchor = false;
            }

            // --- the live device anchor (spec D2) ---------------------------
            // Queried for THIS frame's presentation time. It is NOT set on the
            // drawable yet: which anchor gets presented depends on whether the
            // engine wins the pose rendezvous below, and presenting content
            // against a pose it was not rendered for is what makes a stale
            // frame swim.
            CFTimeInterval presTime = cp_time_to_cf_time_interval(
                cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
            ar_device_anchor_t anchor = ar_device_anchor_create();
            ar_device_anchor_query_status_t anchorStatus =
                ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
            sohvr_anchored = (anchorStatus == ar_device_anchor_query_status_success);

            size_t views = cp_drawable_get_view_count(drawable);

            // --- pose (R1: LIVE; injection still wins while armed) ------------
            // Injection wins over the live pose on purpose (spec D10): a
            // headless assertion must never be raced by the compositor.
            simd_float4x4 head = matrix_identity_float4x4;
            if (sohvr_injectOn) {
                head = simd_mul(sohvr_rotY(sohvr_injectYawDeg * (float)M_PI / 180.0f),
                                sohvr_rotX(sohvr_injectPitchDeg * (float)M_PI / 180.0f));
                head.columns[3] = simd_make_float4(sohvr_injectPos[0], sohvr_injectPos[1], sohvr_injectPos[2], 1.0f);
                sohvr_poseSrc = 2;
            } else if (sohvr_anchored) {
                head = ar_device_anchor_get_origin_from_anchor_transform(anchor);
                sohvr_poseSrc = 1;
            } else {
                sohvr_poseSrc = 0; // tracking has not converged yet
            }
            sohvr_head = head;

            // Manual recenter (spec D6 / DONOR-MAP §4f). Serviced HERE, on
            // the loop thread, against the pose this frame will actually use.
            // It captures NOTHING into steering — only the artificial yaw is
            // zeroed and the roomscale origin re-seated on the head's current
            // translation. A captured steering offset is the donor's recorded
            // "walking sideways" bug.
            if (sohvr_recenterReq) {
                sohvr_recenterReq = 0;
                sohvr_heightCalReq = 1; // R8 item 5: recenter IS the calibration
                sohvr_yawResetReq = 1;  // R16b: and the recenter IS the yaw reset
            }

            // --- R8 item 5: THE HEIGHT CALIBRATION -------------------------
            // Serviced HERE, and only on a frame whose pose is real. That
            // condition is the entire fix for the user's "too tall after
            // re-entering VR": the first-person rising edge used to be consumed
            // on whatever frame carried it, and the frames immediately after an
            // immersive space opens have no converged world-tracking anchor at
            // all -- `head` is the identity, the room origin lands on the floor
            // at the tracking origin, and the wearer's whole standing height is
            // then added on top of Link's. Deferring costs at most a few frames
            // and is counted, so a calibration that never lands is visible in
            // `vr room` instead of felt in the headset.
            if (sohvr_heightCalReq) {
                if (sohvr_poseSrc != 0) {
                    sohvr_heightCalReq = 0;
                    // R16b: only an explicit recenter or VR entry re-seats the
                    // yaw. See sohvr_yawResetReq's note: zeroing it on every
                    // first-person return is what flipped the user 180 degrees on
                    // unpause.
                    if (sohvr_yawResetReq) {
                        sohvr_yawResetReq = 0;
                        sohvr_turnYaw = 0.0f;
                    }
                    sohvr_roomOrigin = head.columns[3].xyz;
                    sohvr_recenters++;
                    sohvr_heightCals++;
                    NSLog(@"[SohVR] height calibrated #%llu (room origin %.3f,%.3f,%.3f from pose_src=%d; "
                          @"eyes now sit at Link's eye height, trim %+.2f m; nothing captured into steering)",
                          (unsigned long long)sohvr_heightCals, sohvr_roomOrigin.x, sohvr_roomOrigin.y,
                          sohvr_roomOrigin.z, sohvr_poseSrc, sohvr_height);
                } else {
                    sohvr_heightCalDeferred++;
                }
            }

            // --- R2b: comfort events serviced HERE, on the loop thread, on
            // the pose this frame will actually use (spec D4/D6).
            // SNAP TURN pivots on the LIVE head: rotating the playspace about
            // the head's own x/z is what leaves the player standing where they
            // are instead of being swung around an arbitrary origin (donor
            // vr_apply_snap_turn, vr_openxr.cpp:672-682). We express that by
            // re-seating the roomscale origin on the head at the instant of the
            // turn -- a yaw about that origin then has the head as its pivot by
            // construction. Y is left alone so a physically crouching player
            // does not spring back to standing on every turn.
            {
                // R3: ONE primitive, two styles, one edge detector, real dt.
                // The pivot is the LIVE head: re-seating the roomscale origin on
                // the head at the instant of the turn makes a yaw about that
                // origin have the head as its pivot by construction, which is
                // what leaves the player standing where they are (donor
                // vr_apply_snap_turn, vr_openxr.cpp:672-682). Y is left alone so
                // a physically crouching player does not spring back to standing.
                double turnNow = CACurrentMediaTime();
                double turnDt = (sohvr_turnLastT > 0.0) ? (turnNow - sohvr_turnLastT) : 0.0;
                sohvr_turnLastT = turnNow;
                if (turnDt > 1.0 / 30.0) {
                    turnDt = 1.0 / 30.0; // the donor clamps dt in both turn paths
                }
                float turnAxis = gSohVRTurnAxis;
                if (!(turnAxis > -1.5f && turnAxis < 1.5f)) {
                    turnAxis = 0.0f; // NaN/garbage can never move the world
                }
                float turnDelta = 0.0f; // degrees RIGHT, this frame
                if (gSohVRFpActive != 0 && sohvr_flatActive == 0) {
                    if (sohvr_turnDeg <= 0.5f) {
                        // SMOOTH (donor style 1): deadzone 0.25, renormalized so
                        // the first degree of travel past it is not a jump.
                        const float dead = 0.25f;
                        float mag = fabsf(turnAxis);
                        if (mag > dead) {
                            float n = (mag - dead) / (1.0f - dead);
                            turnDelta = (turnAxis > 0 ? 1.0f : -1.0f) * n *
                                        sohvr_smoothDegPerSec * (float)turnDt;
                            sohvr_turnDegTotal += fabs((double)turnDelta);
                        }
                        sohvr_snapArmed = 0;
                    } else {
                        // SNAP (donor style 0): latch at |x| > 0.6, release below
                        // 0.3. Hysteresis is what stops a stick resting near the
                        // threshold from machine-gunning turns.
                        if (!sohvr_snapArmed) {
                            if (turnAxis > 0.6f) {
                                sohvr_snapArmed = 1;
                                turnDelta = sohvr_turnDeg;
                                sohvr_snapTurns++;
                            } else if (turnAxis < -0.6f) {
                                sohvr_snapArmed = 1;
                                turnDelta = -sohvr_turnDeg;
                                sohvr_snapTurns++;
                            }
                        } else if (turnAxis < 0.3f && turnAxis > -0.3f) {
                            sohvr_snapArmed = 0;
                        }
                    }
                } else {
                    sohvr_snapArmed = 0;
                }
                if (turnDelta != 0.0f) {
                    // A turn RIGHT is a NEGATIVE yaw about +Y (the donor flags
                    // the sign as a positive-feedback trap; a right turn
                    // decreases game binang).
                    sohvr_turnYaw -= turnDelta * (float)M_PI / 180.0f;
                    sohvr_roomOrigin.x = head.columns[3].x;
                    sohvr_roomOrigin.z = head.columns[3].z;
                }
                // --- R16 item 4: THE WORLD TURNS WITH LINK -----------------
                // The game publishes a signed s16 delta and a sequence number
                // whenever it snaps Link's facing in a state the facing pin
                // stands down in (ladder, ledge, hang) -- a ladder descent
                // writes shape.rot.y += 0x8000 in one tick. Nothing followed
                // that, so the user climbed down facing away from the ladder.
                //
                // THE SIGN IS DIRECT, and it is not a guess. sohvr_seat builds
                // Rg = sohvr_rotY(turnYaw); applying that to a tracking-space
                // forward (sin phi, *, cos phi) gives (sin(phi + turnYaw), *,
                // cos(phi + turnYaw)), and gSohVRHeadingYaw is atan2(x, z) of
                // the SEATED forward -- so the game heading psi = psi(head) +
                // turnYaw exactly. To move psi by +delta, add +delta. (The
                // stick turn agrees: a turn RIGHT decreases game binang and it
                // subtracts.) Because the game side samples shape.rot.y AFTER
                // the pin, the previous sample on a pinned tick IS psi, so the
                // delta published on the entry tick lands the view on Link's
                // choreographed body yaw rather than merely near it.
                //
                // Eased over 0.25 s rather than snapped: the wearer is being
                // turned by the world, which is the classic sickness trigger,
                // and a quarter second is the shortest turn that still reads
                // as a turn. The room origin is re-seated on the LIVE head on
                // every step, exactly as the snap turn does, so the pivot is
                // the wearer's own head and he is not swung around a point.
                {
                    int snapSeq = gSohVRBodyYawSnapSeq;
                    if (snapSeq != sohvr_ladderSeqSeen) {
                        sohvr_ladderSeqSeen = snapSeq;
                        sohvr_ladderLastDelta = gSohVRBodyYawSnapDelta;
                        if (sohvr_ladderFollow && gSohVRFpActive != 0 && sohvr_flatActive == 0) {
                            sohvr_ladderRemain =
                                (float)sohvr_ladderLastDelta * (float)M_PI / 32768.0f;
                            sohvr_ladderT = 0.25f;
                            sohvr_ladderFollows++;
                        }
                    }
                    if (sohvr_ladderT > 0.0f) {
                        float step;
                        if ((float)turnDt >= sohvr_ladderT) {
                            step = sohvr_ladderRemain;
                            sohvr_ladderRemain = 0.0f;
                            sohvr_ladderT = 0.0f;
                        } else {
                            step = sohvr_ladderRemain * ((float)turnDt / sohvr_ladderT);
                            sohvr_ladderRemain -= step;
                            sohvr_ladderT -= (float)turnDt;
                        }
                        sohvr_turnYaw += step;
                        sohvr_roomOrigin.x = head.columns[3].x;
                        sohvr_roomOrigin.z = head.columns[3].z;
                    }
                }
                // Recenter on the RISING edge of first person (donor
                // z_play.c:1396-1402). Captures nothing into steering.
                // R8 item 5: it REQUESTS the calibration rather than performing
                // it, so an edge that arrives before tracking has converged
                // waits for a real pose instead of seating the room on an
                // identity head. See the servicing block above.
                int fpEnt = gSohVRFpEntered;
                if (fpEnt != sohvr_fpEnteredSeen) {
                    sohvr_fpEnteredSeen = fpEnt;
                    sohvr_heightCalReq = 1;
                }
                // R16 part B: a RESUME is first person coming back after 0041
                // suspended it — the pause menu, a panel room, the far-camera
                // fallback. It re-seats the room origin exactly like an entry
                // (the wearer may have walked during the pause) and, like an
                // entry, it no longer touches the yaw. Counted separately only
                // so `vr room` can tell the two apart.
                int fpRes = gSohVRFpResumed;
                if (fpRes != sohvr_fpResumedSeen) {
                    sohvr_fpResumedSeen = fpRes;
                    sohvr_heightCalReq = 1;
                }
            }

            // --- contract capture + eye matrices ------------------------------
            // R7 verdict 5: the flip camera advances on its OWN wall clock, once
            // per compositor frame, before the eye matrices are composed -- see
            // sohvr_update_flip for why integrating against the call count
            // instead is the sibling's recorded "MANY somersaults" bug. R8 part
            // B's attack envelopes and shield crouch share that clock, and the
            // block moved ABOVE sohvr_seat() because the crouch lowers the seat:
            // a seat taken before its own input is a frame of lag that reads as
            // a stutter on exactly the fast motion the crouch is part of.
            {
                static double sohvr_flipLastT = 0.0;
                double sohvr_flipNow = CACurrentMediaTime();
                float sohvr_flipDt =
                    (sohvr_flipLastT > 0.0) ? (float)(sohvr_flipNow - sohvr_flipLastT) : (1.0f / 90.0f);
                sohvr_flipLastT = sohvr_flipNow;
                sohvr_update_flip(sohvr_flipDt);
                sohvr_update_attack(sohvr_flipDt);
                sohvr_update_crouch(sohvr_flipDt);
            }
            SohVRSeat seat = sohvr_seat();
            simd_float4x4 proj[2];
            simd_float4x4 gamePose[2];
            // R10 verdict 1: THE SKY'S SEAT, computed ONCE for both eyes and
            // per COMPOSITOR FRAME. See the skybox block below for why it is
            // the head's game-space position and no longer the game camera's.
            simd_float3 skySeat =
                sohvr_apply_flip(sohvr_to_game(seat, head)).columns[3].xyz;
            sohvr_skySeat = skySeat;
            sohvr_synthEye2 = (views < 2);
            // Publish into the slot the engine is NOT reading; the seq bump at
            // the end is what makes the pair visible to it.
            unsigned int poseSeq = gSohVRPoseSeq + 1u;
            int slot = (int)(poseSeq & 1u);
            for (int e = 0; e < 2; e++) {
                size_t v = (size_t)e < views ? (size_t)e : 0;
                cp_view_t view = cp_drawable_get_view(drawable, v);
                simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                if (sohvr_synthEye2) {
                    // Simulator reports ONE view with an identity transform.
                    // Synthesize the pair at +/- half the 63 mm IPD along
                    // eye-space X so the stereo assertion has something real.
                    simd_float4x4 off = matrix_identity_float4x4;
                    off.columns[3] = simd_make_float4((e == 0 ? -kSohVRHalfIpd : kSohVRHalfIpd), 0, 0, 1);
                    deviceFromEye = simd_mul(deviceFromEye, off);
                }
                sohvr_eyeTrack[e] = simd_mul(head, deviceFromEye);

                simd_float4x4 pc = matrix_identity_float4x4;
                if (__builtin_available(visionOS 2.0, *)) {
                    pc = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, v);
                }
                float tR = 0, tL = 0, tT = 0, tB = 0;
                if (fabsf(pc.columns[0][0]) > 1e-6f && fabsf(pc.columns[1][1]) > 1e-6f) {
                    tR = (pc.columns[2][0] + 1.0f) / pc.columns[0][0];
                    tL = (pc.columns[2][0] - 1.0f) / pc.columns[0][0];
                    tT = (pc.columns[2][1] + 1.0f) / pc.columns[1][1];
                    tB = (pc.columns[2][1] - 1.0f) / pc.columns[1][1];
                } else {
                    tR = tT = 1.0f;
                    tL = tB = -1.0f;
                }
                proj[e] = sohvr_projection(tL, tR, tB, tT, sohvr_near, sohvr_far);

                cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
                MTLViewport vp = cp_view_texture_map_get_viewport(tmap);
                sohvr_contract.vpW[e] = vp.width;
                sohvr_contract.vpH[e] = vp.height;
                sohvr_contract.texIdx[e] = cp_view_texture_map_get_texture_index(tmap);
                sohvr_contract.slice[e] = cp_view_texture_map_get_slice_index(tmap);
                sohvr_contract.tanL[e] = tL;
                sohvr_contract.tanR[e] = tR;
                sohvr_contract.tanB[e] = tB;
                sohvr_contract.tanT[e] = tT;
                // R19 part B: the same four numbers, published to the GAME
                // side, because overlay 0055 rev2's head-locked lens quad has
                // to know how wide this eye's field really is. Written here
                // rather than derived there: these are the compositor's own
                // tangents, and the game has no other way to see them.
                if (e >= 0 && e < 2) {
                    gSohVREyeTan[e][0] = tL;
                    gSohVREyeTan[e][1] = tR;
                    gSohVREyeTan[e][2] = tB;
                    gSohVREyeTan[e][3] = tT;
                }
                sohvr_contract.rawC2z[e] = pc.columns[2][2];
                sohvr_contract.rawC3z[e] = pc.columns[3][2];
                sohvr_classify_depth(pc, &sohvr_contract.depthKind[e], &sohvr_contract.depthNear[e],
                                     &sohvr_contract.depthFar[e]);
                // Empirical: push a point 1 m and 1000 m down -Z through the
                // compositor's OWN matrix and record its NDC z. Near->0/far->1
                // is forward-Z; near->1/far->0 is reverse-Z. Measured, not read.
                for (int k = 0; k < 2; k++) {
                    float z = (k == 0) ? -1.0f : -1000.0f;
                    simd_float4 clip = simd_mul(pc, simd_make_float4(0, 0, z, 1));
                    float ndc = (fabsf(clip.w) > 1e-9f) ? clip.z / clip.w : 0.0f;
                    if (k == 0) {
                        sohvr_contract.zndc1m[e] = ndc;
                    } else {
                        sohvr_contract.zndc1000m[e] = ndc;
                    }
                }

                gamePose[e] = sohvr_to_game(seat, sohvr_eyeTrack[e]);
                // R7 verdict 5: the flip camera. Applied to the EYE, ahead of
                // both the world matrix and the skybox one below, so the sky
                // somersaults with the world instead of staying put while
                // everything else turns.
                gamePose[e] = sohvr_apply_flip(gamePose[e]);
                // R8 item 5: the eye's GAME-space position, so "the wearer's
                // eyes land at Link's eye height whatever their real height is"
                // is a diff of two numbers rather than a feeling.
                sohvr_eyeGame[e] = gamePose[e].columns[3].xyz;
                // R9 part B: the eye's world FORWARD, after the flip. The sign
                // of the flip camera is not settleable by convention, so it is
                // settled by reading this: +Y through a backflip, -Y through a
                // forward roll. sohvr_to_game applies a YAW only, so the Y
                // component here is the tracking-space one unchanged.
                sohvr_eyeFwd[e] = -gamePose[e].columns[2].xyz;
                float row[16];
                sohvr_compose_eye(gamePose[e], proj[e], row);
                memcpy(sohvr_eyeVPDump[e], row, sizeof(row));
                for (int i = 0; i < 16; i++) {
                    gSohVREyeVP[slot][e][i] = row[i];
                }
                // --- R7 verdict 8: THE SKYBOX VIEW ---------------------------
                //
                // the user, 2026-09-04: "the sky outside in hyrule field violently
                // pulsates as you're moving. and the depth is off.. it is
                // relatively close when it should be the most distant texture."
                //
                // Both halves of that are one cause and it is arithmetic, not
                // taste. OoT's skybox is a small sphere CENTRED ON THE CAMERA --
                // +/-126 game units, which at 35 units/m is a 3.6 m ball. The
                // game re-centres it once per game TICK (about 20 Hz), while the
                // eye matrix is recomposed every compositor frame (90-120 Hz)
                // from the live head. So between two ticks the head translates
                // inside a stale 3.6 m sphere, and a 3.6 m sphere gives real
                // parallax for a few centimetres of head motion: the sky
                // swims, at the tick rate, hardest while walking. That is the
                // "violent pulsation" exactly, and the same 3.6 m radius is why
                // it reads as near.
                //
                // 0033 already solves this for the 3D-panel mode -- its skybox
                // sentinels make the skybox draw SKEW-ONLY, which is zero
                // disparity, which is infinity, and the spec calls it
                // strictly better than the donor's 100x scale hack. The VR
                // branch of 0031 never learned about it: it substitutes the
                // composed A.V.P for every perspective draw and the sentinels
                // fall through.
                //
                // So the shell publishes a SECOND matrix for skybox draws only:
                //
                //   skyPose = T(the GAME camera's own eye) . R(head) . S(1/100)
                //
                // Three deliberate parts.
                //   * The POSITION is the game camera's, not the head's -- which
                //     is where the sky sphere actually is. Head translation
                //     therefore cannot move the sky at all: the pulsation is
                //     removed at its source rather than damped.
                //   * The ROTATION is the head's, because looking around must
                //     still look around. Eye-rotation-only is the whole ask.
                //   * The SCALE pushes the sphere out by 100x. Both eyes get the
                //     SAME pose and differ only in their own projection, so the
                //     disparity is already zero (0033's result, reached the same
                //     way); the scale is for the DEPTH BUFFER, which the
                //     compositor reprojects on. 126 units becomes 12600, i.e.
                //     360 m, which is far enough down a reverse-Z infinite-far
                //     curve to be indistinguishable from the far plane. This is
                //     the one place the donor's 100x is the right tool, because
                //     here it is doing depth and not disparity.
                //
                // --- R10 VERDICT 1: THE SEAT IS THE EYE, NOT THE GAME CAMERA -
                //
                // the user, on 1.0.1.13: *"The sky vibrates or pulsates as you
                // move. It looks fine when you're not moving."* The R7 fix
                // above is right about the CAUSE (a stale sphere centre) and
                // wrong about which centre is stale.
                //
                // `gSoh3DCamEye` is `play->view.eye`, written by z_view.c's
                // View_Apply while the GAME frame is being built -- so it steps
                // once per game frame and holds. The skybox MESH is centred on
                // the same `play->view.eye` (z_play.c: SkyboxDraw_Draw and
                // SkyboxDraw_UpdateMatrix are both passed it), so the two do
                // agree at the instant the display list is recorded. But the
                // matrix that CARRIES the mesh is then INTERPOLATED between two
                // game frames by Fast3D and re-submitted on every compositor
                // frame, while our seat is the raw latched word. The mesh moves
                // smoothly; the seat it is being viewed from jumps. The
                // difference is a sawtooth at the game-frame rate whose
                // amplitude is how far Link moved in one frame -- zero while he
                // stands still, largest while he runs, which is the user's report
                // exactly.
                //
                // The seat is therefore the EYE's own game-space position, the
                // same translation the world matrix uses this frame, computed
                // once above and shared by both eyes (a per-eye seat would put
                // half an IPD of parallax on a sphere the compositor is about
                // to reproject; both eyes sharing one seat is what makes the
                // disparity exactly zero, which is 0033's result and the reason
                // the sky reads as infinitely far). Two consequences worth
                // stating:
                //   * The seat now moves every frame, smoothly, with the world.
                //     Nothing steps, so nothing vibrates.
                //   * The sphere centre and the seat are no longer identical, so
                //     there IS a residual parallax -- and it is divided by the
                //     100x scale below, which turns the 3.6 m ball into a 360 m
                //     one. A wearer's head moving 5 cm inside a 360 m sphere is
                //     0.008 degrees. That is the whole reason the scale can be
                //     asked to do this job.
                //
                // --- R11 VERDICT 1: THE 100x SCALE NEVER DIVIDED ANYTHING ----
                //
                // the user, on 1.0.1.14: *"Sky still pulsates like crazy when I
                // move."* Two seats have now failed, and the reason both failed
                // is one line of arithmetic that R7 and R10 both got wrong.
                //
                // Write out what a skybox vertex actually does. The game's model
                // matrix M puts the sphere at `play->view.eye` (z_vr_box_draw.c:
                // Matrix_Translate(x,y,z, MTXMODE_NEW) then the three rotates),
                // and Fast3D INTERPOLATES M between two game frames, so its
                // translation is a smooth glide of the game camera. Our view is
                // inverse(skyPose), i.e. 100 * R^T applied to (p - seat). So the
                // vertex lands, in eye space, at
                //
                //     100 * R^T * ( R_sky * p_model  +  M_t  -  seat )
                //
                // The sphere's own radius is |p_model| = 126 units, which the
                // same 100 multiplies to 12600. THE RESIDUAL (M_t - seat) IS
                // INSIDE THE SAME 100. Scaling numerator and denominator alike
                // changes no angle at all: the angular error is
                //
                //     |M_t - seat| / 126 radians
                //
                // whatever the scale is. R7's note ("a 3.6 m ball gives real
                // parallax") and R10's ("a 5 cm head move inside a 360 m sphere
                // is 0.008 degrees") are the same claim with the scale applied
                // to one side only. 126 units at 34 units/m is 3.7 m, and the
                // gap between the interpolated game camera and the head is
                // several units the moment Link moves -- ten units is 4.5
                // DEGREES of sky swim, per frame, sawtoothing with whatever
                // disagreement there is between the two clocks. "Pulsates like
                // crazy" is that number, and no choice of seat makes it zero,
                // because the two quantities are sampled by different clocks by
                // construction.
                //
                // THE CONSTRUCTION THAT CANNOT PULSATE IS TO HAVE NO
                // TRANSLATION ANYWHERE. A skybox is a direction map: the only
                // thing that may reach it is a rotation. So:
                //
                //   * the shell's sky pose keeps the head's ROTATION and the
                //     100x scale and sets its translation to ZERO (here), and
                //   * overlay 0031 zeroes M's translation row for draws inside
                //     0033's skybox sentinel (the interpreter is the only place
                //     that can, because M does not exist until the display list
                //     is walked).
                //
                // The vertex then lands at 100 * R^T * R_sky * p_model: the
                // sphere is centred on the eye BY CONSTRUCTION, at every frame,
                // regardless of tick rate, of Fast3D's interpolation, of how
                // fast Link is running and of how the wearer's head moves. The
                // residual is not small; it is identically zero. Both eyes still
                // share one rotation and differ only in their projection, so the
                // disparity is zero, which is what makes the sky read as
                // infinitely far (0033's result, reached the same way), and the
                // 100x still does the one job it is good for -- pushing the
                // sphere far enough down the reverse-Z curve that the compositor
                // reprojects it as background.
                //
                // `skySeat` is KEPT and still published: it is what `vr sky`
                // prints beside the M translation 0031 dropped, so the residual
                // this construction refuses to carry is a number in the log
                // rather than an argument in a comment.
                {
                    simd_float4x4 skyPose = gamePose[e];
                    // Same rotation basis for both eyes -- and it already is,
                    // since both eyes share the head's orientation; taking it
                    // from this eye's own pose keeps one code path.
                    const float kSohVRSkyScale = 100.0f;
                    for (int c = 0; c < 3; c++) {
                        skyPose.columns[c] = skyPose.columns[c] / kSohVRSkyScale;
                    }
                    // R11: ZERO. Not the head, not the game camera, not any
                    // sample of any position -- a skybox has no position.
                    skyPose.columns[3] = simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f);
                    float skyRow[16];
                    sohvr_compose_eye(skyPose, proj[e], skyRow);
                    for (int i = 0; i < 16; i++) {
                        gSohVRSkyVP[slot][e][i] = skyRow[i];
                    }
                }
            }

            // --- R4: MOTION HANDS + the swing detector (DONOR-MAP 3 + 8) ------
            // Deliberately inside the eye-pair block and BEFORE the seq bump:
            // the hands go into the SAME slot under the SAME pose seq as the
            // two eyes, so a frame is one instant of one pose everywhere. The
            // donor gets this for free (one OpenXR xrLocateViews call locates
            // hands and views together); we have to arrange it, and a hand
            // latched from a different pose than the eye it is seen through
            // swims -- the one artefact that reads as "not my hands".
            {
                gSohVRPhysVersion = SohVrPhys_GetInterfaceVersion();
                simd_float4x4 sohvr_handTrack[2];
                int sohvr_handHave[2] = { 0, 0 };
                sohvr_script_tick(CACurrentMediaTime());
                SohSense_Update(0.0, head);
                SohVrPhysHand physHands[2];
                memset(physHands, 0, sizeof(physHands));
                for (int h = 0; h < 2; h++) {
                    simd_float4x4 hp;
                    simd_float3 hv, hw;
                    if (!SohSense_HandMotion(h, &hp, &hv, &hw)) {
                        gSohVRHandValid[h] = 0;
                        gSohVRAimRayValid[h] = 0;
                        continue;
                    }
                    // The physics runs in TRACKING space (metres), where the
                    // thresholds are physical: 5 m/s is 5 m/s whatever the
                    // world scale is set to. Only the PUBLISHED matrix is
                    // seated into game space.
                    // Re-normalize the basis before extracting the quaternion:
                    // the anchor transform is rigid, but a hair of numerical
                    // drift in the matrix becomes a non-unit quaternion the
                    // physics then integrates.
                    simd_float3x3 hbasis = simd_matrix(simd_normalize(hp.columns[0].xyz),
                                                       simd_normalize(hp.columns[1].xyz),
                                                       simd_normalize(hp.columns[2].xyz));
                    simd_quatf hq = simd_normalize(simd_quaternion(hbasis));
                    simd_float3 hpos = hp.columns[3].xyz;
                    physHands[h].valid = 1;
                    physHands[h].pos = (SohV3){ hpos.x, hpos.y, hpos.z };
                    physHands[h].quat = (SohQ4){ simd_imag(hq).x, simd_imag(hq).y, simd_imag(hq).z, simd_real(hq) };
                    physHands[h].vel = (SohV3){ hv.x, hv.y, hv.z };
                    physHands[h].angVel = (SohV3){ hw.x, hw.y, hw.z };

                    sohvr_handTrack[h] = hp;
                    sohvr_handHave[h] = 1;
                }
                // --- R5: feed the solver the game's collision mesh ---------
                // Converted EVERY frame, not only when the harvest seq moves:
                // the triangles are static in GAME space, but the seat that
                // maps game space to tracking metres moves with Link, so a
                // cached conversion would drag the world with him between
                // ticks. Sixteen triangles is 48 points; this is free.
                if (gSohVRBladeDamage != 0) {
                    SohVrPhysTri tris[SOHVRPHYS_MAX_TRI];
                    int nTri = gSohVRMeshCount;
                    if (nTri < 0) {
                        nTri = 0;
                    } else if (nTri > SOHVRPHYS_MAX_TRI) {
                        nTri = SOHVRPHYS_MAX_TRI;
                    }
                    for (int i = 0; i < nTri; i++) {
                        simd_float3 a = sohvr_game_to_track_pt(
                            seat, simd_make_float3(gSohVRMeshTri[i][0], gSohVRMeshTri[i][1], gSohVRMeshTri[i][2]));
                        simd_float3 b = sohvr_game_to_track_pt(
                            seat, simd_make_float3(gSohVRMeshTri[i][3], gSohVRMeshTri[i][4], gSohVRMeshTri[i][5]));
                        simd_float3 c = sohvr_game_to_track_pt(
                            seat, simd_make_float3(gSohVRMeshTri[i][6], gSohVRMeshTri[i][7], gSohVRMeshTri[i][8]));
                        tris[i].a = (SohV3){ a.x, a.y, a.z };
                        tris[i].b = (SohV3){ b.x, b.y, b.z };
                        tris[i].c = (SohV3){ c.x, c.y, c.z };
                        tris[i].id = gSohVRMeshId[i];
                        // R6: shape + radius. The radius is a LENGTH, so it
                        // takes the scale alone -- sohvr_game_to_track_pt's
                        // rotation and origin are for points.
                        int sh = gSohVRMeshShape[i];
                        tris[i].shape = (sh == SOHVRPHYS_SHAPE_CAPSULE || sh == SOHVRPHYS_SHAPE_SPHERE)
                                            ? sh
                                            : SOHVRPHYS_SHAPE_TRI;
                        tris[i].radius =
                            (tris[i].shape == SOHVRPHYS_SHAPE_TRI) ? 0.0f : gSohVRMeshRadius[i] / sohvr_scale;
                    }
                    SohVrPhys_SetMesh(tris, nTri);
                } else {
                    SohVrPhys_SetMesh(NULL, 0); // R4 fallback: no physical blade
                }
                // A damage quad LANDED last tick: drop the tier HOT -> ARMED.
                for (int h = 0; h < 2; h++) {
                    unsigned int hs = gSohVRBladeHitSeq[h];
                    if (hs != sohvr_bladeHitSeen[h]) {
                        sohvr_bladeHitSeen[h] = hs;
                        SohVrPhys_NotifyHit(h);
                        // The hit haptic. Donor VrSwing.cpp:1525 fires this
                        // game-side, one tick late, at an amplitude that rises
                        // with tip speed; ours does the same from the same
                        // edge, which is the same instant in the same tick.
                        float sp = gSohVRSwingSpeed[h];
                        float amp = 0.45f + 0.09f * sp;
                        SohSense_Haptic(h, amp > 1.0f ? 1.0f : amp, 0.7f, (45.0f + 12.0f * sp) * 0.001f);
                    }
                }

                double physNow = CACurrentMediaTime();
                float physDt = (sohvr_physLastT > 0.0) ? (float)(physNow - sohvr_physLastT) : (1.0f / 90.0f);
                sohvr_physLastT = physNow;
                SohVrPhys_Step(physDt, physHands);
                // R14: one publish per frame, before either hand's matrix is
                // written, so the pin and the aim can never disagree about
                // which calibration is live.
                sohvr_publish_aim_handfix();
                for (int h = 0; h < 2; h++) {
                    SohVrPhysOut po;
                    // R5: THE HAND MATRIX IS THE SIM POSE, not the raw
                    // controller. That single substitution is what makes the
                    // recoil visible -- the donor does the same thing one layer
                    // lower, inside its OpenXR grip accessor
                    // (vr_openxr.cpp:2200-2210), so its limb draw has no choice
                    // in the matter either. Held items ride the same matrix, so
                    // the sword you see is the sword that stopped.
                    if (sohvr_handHave[h]) {
                        simd_float4x4 hpose = sohvr_handTrack[h];
                        if ((gSohVRBladeDamage != 0) && SohVrPhys_Get(h, &po)) {
                            simd_quatf sq = simd_quaternion(po.visQuat.x, po.visQuat.y, po.visQuat.z, po.visQuat.w);
                            hpose = simd_matrix4x4(simd_normalize(sq));
                            hpose.columns[3] = simd_make_float4(po.visPos.x, po.visPos.y, po.visPos.z, 1.0f);
                        }
                        sohvr_handRawPose[h] = hpose;
                        // R7 verdicts 2+3: THE GRIP -> HAND CALIBRATION, applied
                        // HERE and nowhere else. This is the one point in the
                        // program where the controller pose becomes the hand
                        // pose, so a single application keeps the DRAWN hand,
                        // the DRAWN sword and shield (which ride the same limb
                        // matrix), and the SOLVER's blade (whose geometry is
                        // multiplied through that same matrix by the game) all
                        // describing one object. Calibrating in two places would
                        // be the R5 lesson repeated: the blade the physics uses
                        // and the blade you see must be the same pose.
                        //
                        // It sits AFTER the physics substitution deliberately.
                        // The solver works in the raw controller frame -- its
                        // thresholds are physical and its grip-local geometry is
                        // extracted against the pose it was given -- so
                        // calibrating before it would rotate the frame the
                        // solver reasons in for no benefit, and calibrating
                        // after it leaves the recoil intact and simply expresses
                        // the result in the hand mesh's frame.
                        hpose = sohvr_apply_hand_calibration(h, hpose);
                        sohvr_handCalPose[h] = hpose;
                        // R8 part B: THE ATTACK ENVELOPE, at the same seam and
                        // for the same reason. A button attack has to MOVE the
                        // sword, and moving it here -- after the calibration,
                        // before sohvr_to_game -- moves the drawn hand, the
                        // drawn sword, the vanilla trail (which reads the hand
                        // limb matrix) and, through the transform stored below,
                        // the solver's blade line, as one object.
                        {
                            int swordHand = (gSohVRLeftHanded != 0) ? 0 : 1;
                            sohvr_atkXfPrev[h] = sohvr_atkXf[h];
                            // R20 item 1: the two cosines `vr room` prints, every
                            // frame and whether or not an envelope is running --
                            // a number only published during a 0.7 s envelope is
                            // a number nobody can read over a TCP round trip.
                            if (h == swordHand) {
                                SohVrPhysOut spo;
                                sohvr_atkHamDot =
                                    simd_dot(sohvr_limb_dir(hpose, kSohVRHammerTipLimb),
                                             simd_normalize(hpose.columns[0].xyz));
                                if (SohVrPhys_Get(h, &spo)) {
                                    simd_float3 sb = simd_make_float3(spo.bladeTip.x - spo.bladeBase.x,
                                                                      spo.bladeTip.y - spo.bladeBase.y,
                                                                      spo.bladeTip.z - spo.bladeBase.z);
                                    float sl = simd_length(sb);
                                    if (sl > 1e-4f) {
                                        sohvr_atkSwLimbDot = simd_dot(
                                            sohvr_limb_dir(hpose, kSohVRSwordTipLimb), sb / sl);
                                    }
                                }
                            }
                            if ((h == swordHand) && (sohvr_atkKind != 0)) {
                                simd_float3 bd;
                                simd_float3* bdp = NULL;
                                // R19 item 1, CORRECTED IN R20: the HAMMER is
                                // handed NO blade, because overlay 0048 builds
                                // one only for melee weapons 1..3 and a line
                                // found there would be a SWORD's. What it
                                // rotates about instead is vanilla's own hammer
                                // tip -- D_80126080 scaled to
                                // sMeleeWeaponLengths[5], i.e. (2500, 400, 0) in
                                // the LIMB frame -- carried into shell space by
                                // sohvr_limb_dir. R19 skipped that carry and
                                // used hpose's own +X, which the mesh mirror
                                // turns into the WRONG END of the hammer.
                                if ((sohvr_atkKind != 3) && SohVrPhys_Get(h, &po)) {
                                    bd = simd_make_float3(po.bladeTip.x - po.bladeBase.x,
                                                          po.bladeTip.y - po.bladeBase.y,
                                                          po.bladeTip.z - po.bladeBase.z);
                                    bdp = &bd;
                                }
                                // R9 part B: the envelope is defined against
                                // the WEARER's frame, so it needs the head. The
                                // head pose for this frame is already known
                                // (sohvr_head, set at the top of the loop), and
                                // its forward is -Z; the build flattens it.
                                simd_float3 bodyFwd = -sohvr_head.columns[2].xyz;
                                sohvr_atkXf[h] = sohvr_atk_build(hpose, bdp, bodyFwd);
                                hpose = sohvr_atk_pose(&sohvr_atkXf[h], hpose);
                            } else {
                                sohvr_atkXf[h].active = 0;
                            }
                        }
                        sohvr_handAtkPose[h] = hpose;
                        // Through the seat, exactly like the head and the eyes:
                        // same A, same world scale, same anchor. Nothing about
                        // the hand path is special, and that is the point.
                        simd_float4x4 handGame = sohvr_to_game(seat, hpose);
                        for (int i = 0; i < 4; i++) {
                            for (int j = 0; j < 4; j++) {
                                gSohVRHandMat[slot][h][i * 4 + j] = handGame.columns[i][j];
                            }
                        }
                        gSohVRHandValid[h] = 1;
                        // R15: THE AIM RAY. The accessory's own aim location,
                        // through the same seat as the hand -- and NOT through
                        // the calibration, the physics substitution or the
                        // attack envelope, none of which is about where the
                        // controller points. Rotation only for the direction;
                        // the origin is the aim location's own, in game units.
                        {
                            simd_float4x4 aimTrack;
                            int aimSrc = -1;
                            if (SohSense_HandAimPose(h, &aimTrack, &aimSrc)) {
                                simd_float4x4 aimGame = sohvr_to_game(seat, aimTrack);
                                simd_float3 d = aimGame.columns[0].xyz * gSohVRAimRayAxis[0] +
                                                aimGame.columns[1].xyz * gSohVRAimRayAxis[1] +
                                                aimGame.columns[2].xyz * gSohVRAimRayAxis[2];
                                float dl = simd_length(d);
                                if (dl > 1e-6f) {
                                    d = d / dl;
                                    gSohVRAimRayDir[h][0] = d.x;
                                    gSohVRAimRayDir[h][1] = d.y;
                                    gSohVRAimRayDir[h][2] = d.z;
                                    gSohVRAimRayOrg[h][0] = aimGame.columns[3].x;
                                    gSohVRAimRayOrg[h][1] = aimGame.columns[3].y;
                                    gSohVRAimRayOrg[h][2] = aimGame.columns[3].z;
                                    gSohVRAimRayValid[h] = 1;
                                } else {
                                    gSohVRAimRayValid[h] = 0;
                                }
                            } else {
                                gSohVRAimRayValid[h] = 0;
                            }
                            sohvr_aimRaySrc[h] = aimSrc;
                        }
                    }
                    if (SohVrPhys_Get(h, &po)) {
                        gSohVRSwingSeq[h] = po.swingSeq;
                        gSohVRSwingSpeed[h] = po.swingSpeed;
                        gSohVRSwingMid[h] = po.midSpeed;
                        gSohVRSwingHand[h] = po.handSpeed;
                        gSohVRSwingJump[h] = po.swingJumpSlash;
                        gSohVRSwingTier[h] = po.tier;
                    } else {
                        // Tier drops but the SEQ is held: a re-acquire after a
                        // tracking dropout must not replay an old edge as a new
                        // attack. SohVrPhys_Reset is the only thing that clears
                        // it, and only VR entry calls that.
                        gSohVRSwingMid[h] = 0.0f;
                        gSohVRSwingHand[h] = 0.0f;
                        gSohVRSwingTier[h] = 0;
                    }
                    gSohVRSenseBtn[h] = SohSense_HandButtons(h);
                    float sx = 0.0f, sy = 0.0f;
                    SohSense_HandStick(h, &sx, &sy);
                    // R6: the compass owns its hand's thumbstick while it is
                    // open. Without this the thumb resting on a CLICKED stick
                    // turns the player through the whole selection.
                    if (gSohVRItemSelOpen != 0 && gSohVRItemSelHand == h) {
                        sx = 0.0f;
                        sy = 0.0f;
                    }
                    gSohVRSenseStickX[h] = sx;
                    gSohVRSenseStickY[h] = sy;
                }
                gSohVRWorldScale = sohvr_scale;
                // R6: the Alyx confirmation tick. The game side bumps the seq on
                // every highlight change; the shell is where the motors live.
                if (gSohVRItemSelTickSeq != sohvr_itemSelTickSeen) {
                    sohvr_itemSelTickSeen = gSohVRItemSelTickSeq;
                    SohSense_Haptic(gSohVRItemSelHand, 0.4f, 0.9f, 0.025f);
                }

                // --- R5: the blade line, and the contacts that stopped it ---
                for (int h = 0; h < 2; h++) {
                    SohVrPhysOut po;
                    if ((gSohVRBladeDamage == 0) || !gSohVRHandValid[h] || !SohVrPhys_Get(h, &po)) {
                        gSohVRBladeValid[h] = 0;
                        continue;
                    }
                    const SohV3 pts[4] = { po.bladeBase, po.bladeTip, po.prevBase, po.prevTip };
                    for (int k = 0; k < 4; k++) {
                        simd_float3 tp = simd_make_float3(pts[k].x, pts[k].y, pts[k].z);
                        // R8 part B: the thrust's damage rides the thrust. The
                        // solver works in the RAW controller frame and knows
                        // nothing about the envelope, so the same rigid
                        // transform the drawn sword took is applied here --
                        // this frame's to the current points, LAST frame's to
                        // the previous pair, so the swept quad sees the
                        // envelope's own motion rather than cancelling it.
                        simd_float3 moved =
                            sohvr_atk_point((k < 2) ? &sohvr_atkXf[h] : &sohvr_atkXfPrev[h], tp);
                        if (k == 0) {
                            float d = simd_length(moved - tp);
                            if (d > sohvr_atkBladeShift) {
                                sohvr_atkBladeShift = d;
                            }
                        }
                        tp = moved;
                        simd_float3 g = sohvr_track_to_game_pt(seat, tp);
                        gSohVRBladeLine[slot][h][k * 3 + 0] = g.x;
                        gSohVRBladeLine[slot][h][k * 3 + 1] = g.y;
                        gSohVRBladeLine[slot][h][k * 3 + 2] = g.z;
                    }
                    gSohVRBladeValid[h] = 1; // published LAST, like every pose here
                }
                {
                    SohVrPhysEvent evs[SOHVRPHYS_MAX_EVENTS];
                    int nev = SohVrPhys_DrainEvents(evs, SOHVRPHYS_MAX_EVENTS);
                    for (int i = 0; i < nev; i++) {
                        unsigned int w = gSohVRContactSeq & 7u;
                        simd_float3 g =
                            sohvr_track_to_game_pt(seat, simd_make_float3(evs[i].pos.x, evs[i].pos.y, evs[i].pos.z));
                        // The NORMAL is a direction, so it takes the rotation
                        // and NOT the scale or the origin. Running it through
                        // the point transform is the bug this comment exists to
                        // stop someone reintroducing.
                        simd_float3 n =
                            simd_mul(seat.Rg, simd_make_float4(evs[i].normal.x, evs[i].normal.y, evs[i].normal.z, 0.0f))
                                .xyz;
                        gSohVRContactPos[w][0] = g.x;
                        gSohVRContactPos[w][1] = g.y;
                        gSohVRContactPos[w][2] = g.z;
                        gSohVRContactNrm[w][0] = n.x;
                        gSohVRContactNrm[w][1] = n.y;
                        gSohVRContactNrm[w][2] = n.z;
                        gSohVRContactImpact[w] = evs[i].impact;
                        gSohVRContactHand[w] = evs[i].hand;
                        gSohVRContactId[w] = evs[i].id;
                        gSohVRContactSeq = gSohVRContactSeq + 1u; // the entry is complete FIRST
                        gSohVRBladeContacts = gSohVRBladeContacts + 1;
                        // The impact haptic (donor vr_physics.cpp:1294-1300).
                        float imp = evs[i].impact;
                        float amp = 0.3f + imp * 0.18f;
                        float ms = 30.0f + (imp > 4.0f ? 4.0f : imp) * 20.0f;
                        SohSense_Haptic(evs[i].hand, amp > 1.0f ? 1.0f : amp, 0.9f, ms * 0.001f);
                    }
                }
                gSohVRSenseActive = SohSense_Active();
            }

            sohvr_contract.views = views;
            sohvr_contract.textures = cp_drawable_get_texture_count(drawable);
            sohvr_contract.ratemaps = cp_drawable_get_rasterization_rate_map_count(drawable);
            sohvr_contract.colorFmt = (unsigned long)t0.pixelFormat;
            sohvr_contract.depthFmt = (unsigned long)cp_drawable_get_depth_texture(drawable, 0).pixelFormat;
            sohvr_contract.layout = (sohvr_contract.textures > 1) ? 0 : ((views > 1) ? 1 : 0);
            {
                simd_float2 dr = cp_drawable_get_depth_range(drawable);
                sohvr_contract.rangeFar = dr.x; // reverse-Z ordering: x = far, y = near
                sohvr_contract.rangeNear = dr.y;
                // The measured near plane is the one constant the depth
                // conversion needs; anything else means we do not understand
                // the drawable and the handoff stays off (R0 finding 4).
                if (sohvr_contract.depthKind[0] == 2 && dr.y > 0.001f && dr.y < 10.0f) {
                    sohvr_depthNearM = dr.y;
                    sohvr_depthValid = 1;
                } else {
                    sohvr_depthValid = 0;
                }
            }
            sohvr_contract.valid = 1;

            // --- R2b scope F: WHAT ACTUALLY MOVES (the rainbow hunt) ----------
            // the user sees huge sheared saturated triangles ONLY while the Mac
            // Virtual Display is in his gaze. Hypothesis (a) is that the
            // compositor changes the per-eye viewport / tangents / rate-map
            // count when a system window enters the scene, and we were
            // recomputing the engine's render extent from those numbers EVERY
            // frame. These counters make that measurable instead of arguable:
            // if vp_changes or tan_changes climbs while he looks at the MVD,
            // (a) is live; if they stay flat while rainbows appear, it is not.
            if (sohvr_contractSeen) {
                if (fabs(sohvr_contract.vpW[0] - sohvr_lastVpW) > 0.5 ||
                    fabs(sohvr_contract.vpH[0] - sohvr_lastVpH) > 0.5) {
                    sohvr_vpChanges++;
                }
                if (sohvr_contract.ratemaps != sohvr_lastRatemaps) {
                    sohvr_ratemapChanges++;
                }
                for (int e = 0; e < 2; e++) {
                    if (fabsf(sohvr_contract.tanL[e] - sohvr_lastTan[e][0]) > 1e-4f ||
                        fabsf(sohvr_contract.tanR[e] - sohvr_lastTan[e][1]) > 1e-4f ||
                        fabsf(sohvr_contract.tanB[e] - sohvr_lastTan[e][2]) > 1e-4f ||
                        fabsf(sohvr_contract.tanT[e] - sohvr_lastTan[e][3]) > 1e-4f) {
                        sohvr_tanChanges++;
                        break;
                    }
                }
            }
            sohvr_lastVpW = sohvr_contract.vpW[0];
            sohvr_lastVpH = sohvr_contract.vpH[0];
            sohvr_lastRatemaps = sohvr_contract.ratemaps;
            for (int e = 0; e < 2; e++) {
                sohvr_lastTan[e][0] = sohvr_contract.tanL[e];
                sohvr_lastTan[e][1] = sohvr_contract.tanR[e];
                sohvr_lastTan[e][2] = sohvr_contract.tanB[e];
                sohvr_lastTan[e][3] = sohvr_contract.tanT[e];
            }
            sohvr_contractSeen = 1;

            // --- R2a: size the ENGINE's eye framebuffer from the drawable ------
            // Trap D7: the eye extent is its own sizing domain, derived from
            // the drawable's own per-eye viewport (so the render target carries
            // the SAME aspect as the projection built from that eye's
            // tangents), clamped to a long-edge budget, times the render scale.
            // Never from the flat pipeline's internal-res settings.
            if (sohvr_contract.vpW[0] > 1.0 && sohvr_contract.vpH[0] > 1.0) {
                double exW = sohvr_contract.vpW[0], exH = sohvr_contract.vpH[0];
                double lo = exW > exH ? exW : exH;
                double k = 1.0;
                if (sohvr_eyeBudget > 64.0 && lo > sohvr_eyeBudget) {
                    k = sohvr_eyeBudget / lo;
                    sohvr_eyeClamped = 1;
                } else {
                    sohvr_eyeClamped = 0;
                }
                k *= (double)sohvr_eyeScale;
                int w = ((int)(exW * k)) & ~1;
                int h = ((int)(exH * k)) & ~1;
                if (w < 320) {
                    w = 320;
                }
                if (h < 240) {
                    h = 240;
                }
                // R2b (scope F): ADOPT SLOWLY. R2a wrote gSoh3DEyeW/H the
                // instant the drawable's numbers moved, which meant the
                // engine's render targets could be reallocated in the middle
                // of the two interpreter walks that make up one stereo pair --
                // and a pair walked across a reallocation is exactly the kind
                // of garbage geometry the user photographed. A new extent must
                // now hold for SOHVR_SIZE_HOLD consecutive frames (1 s at 120
                // Hz) before it is adopted, so a transient contract change
                // while the compositor composites a system window cannot reach
                // the engine at all. The FIRST size is adopted immediately --
                // there is no pair in flight yet.
                if (w != sohvr_eyeWWant || h != sohvr_eyeHWant) {
                    sohvr_eyeWWant = w;
                    sohvr_eyeHWant = h;
                    sohvr_eyeWantHeld = 0;
                } else if (sohvr_eyeWantHeld < SOHVR_SIZE_HOLD) {
                    sohvr_eyeWantHeld++;
                }
                int first = (gSoh3DEyeW == 0 || gSoh3DEyeH == 0);
                if ((w != gSoh3DEyeW || h != gSoh3DEyeH) &&
                    (first || sohvr_eyeWantHeld >= SOHVR_SIZE_HOLD)) {
                    NSLog(@"[SohVR] eye framebuffer %dx%d -> %dx%d (drawable eye vp %.0fx%.0f, budget %.0f, "
                          @"scale %.2f, held %d frames)",
                          gSoh3DEyeW, gSoh3DEyeH, w, h, exW, exH, sohvr_eyeBudget, sohvr_eyeScale,
                          sohvr_eyeWantHeld);
                    {
                        extern void SohIos_VrNote(const char* what, const char* detail);
                        char sohDetail[160];
                        snprintf(sohDetail, sizeof(sohDetail), "%dx%d -> %dx%d first=%d held=%d avail_mb=%ld",
                                 (int)gSoh3DEyeW, (int)gSoh3DEyeH, w, h, first, sohvr_eyeWantHeld,
                                 SohIos_AvailableMemoryMB());
                        SohIos_VrNote("eye size adopted", sohDetail);
                    }
                    gSoh3DEyeW = w;
                    gSoh3DEyeH = h;
                    sohvr_fbReallocs++;
                }
            }

            // --- camera unification (spec D5, overlay 0037) -----------------
            // Push the composed HEAD pose (mean of the two eyes) back into the
            // game View so culling, audio panning and LOD follow the head. This
            // is BLOCKING for a head-tracked frame, not a nicety: at any real
            // head displacement the game's own culling and skybox collapse
            // (VR-R0-FINDINGS finding 7). The A matrix is seated on the GAME
            // camera's basis (overlay 0037's export), never on the value we
            // write here — that would be a feedback loop.
            {
                simd_float4x4 headGame = sohvr_to_game(seat, head);
                simd_float3 c = (gamePose[0].columns[3].xyz + gamePose[1].columns[3].xyz) * 0.5f;
                simd_float3 fwd = -headGame.columns[2].xyz;
                simd_float3 up = headGame.columns[1].xyz;
                gSohVRCamEye[0] = c.x;
                gSohVRCamEye[1] = c.y;
                gSohVRCamEye[2] = c.z;
                gSohVRCamFwd[0] = fwd.x;
                gSohVRCamFwd[1] = fwd.y;
                gSohVRCamFwd[2] = fwd.z;
                gSohVRCamUp[0] = up.x;
                gSohVRCamUp[1] = up.y;
                gSohVRCamUp[2] = up.z;
                gSohVRCamFovy = sohvr_culling_fovy();
                gSohVRCamValid = 1;

                // R2b (spec D6 / VR-DONOR-MAP §4): the HEAD YAW as a game
                // binang, for the steering table in overlay 0042. Game yaw 0
                // faces +Z and movement is sin->x cos->z, so atan2(fwd.x,
                // fwd.z) IS the game convention with no conversion at all --
                // the donor records an earlier Euler extraction with fudge
                // constants that skewed steering by up to ~15 degrees when the
                // head was pitched. Looking straight up or down leaves the
                // horizontal projection degenerate, so the last stable value
                // is held (the donor's function-local static).
                {
                    static int lastYaw = 0;
                    float hx = fwd.x, hz = fwd.z;
                    float hlen = sqrtf(hx * hx + hz * hz);
                    if (hlen > 0.05f) {
                        float yawRad = atan2f(hx / hlen, hz / hlen);
                        lastYaw = (int)lroundf(yawRad * 32768.0f / (float)M_PI) & 0xFFFF;
                        if (lastYaw > 32767) {
                            lastYaw -= 65536;
                        }
                    }
                    gSohVRHeadingYaw = lastYaw;
                    gSohVRHeadingValid = 1;
                }
            }

            // Sim-rate correctness (spec D8, overlay 0015 rev3): publish the
            // engine's own CADENCE, never the raw compositor rate. R1 published
            // the measured present rate and that is right at 60 and wrong at
            // 120 — see the sohvr_hostDiv note. The divisor is chosen from the
            // measurement, not hardcoded, and it is what `interp_hz` reports.
            if (sohvr_presentHz > 30.0 && sohvr_presentHz < 240.0) {
                int div = sohvr_hostDiv;
                if (div <= 0) {
                    // Smallest divisor that puts the engine at or below 60 fps.
                    // 60.5 rather than 60 so a 60.02 Hz measurement does not
                    // round itself up into a divisor of 2.
                    div = (int)ceil(sohvr_presentHz / 60.5);
                }
                if (div < 1) {
                    div = 1;
                }
                if (div > 4) {
                    div = 4;
                }
                sohvr_hostDivEff = div;
                int cadence = (int)(sohvr_presentHz / (double)div + 0.5);
                if (cadence < 20) {
                    cadence = 20; // never below OoT's own tick rate
                }
                sohvr_engineHz = cadence;
                gSohVRRefreshHz = cadence;
            }
            // Park this pose's anchor so a pair rendered against it can be
            // re-presented against it later (trap D35's corollary: submit the
            // PAIR's own anchor, not the live one).
            {
                int ri = (int)(poseSeq % SOHVR_ANCHOR_RING);
                sohvr_anchorRing[ri] = sohvr_anchored ? anchor : NULL;
                sohvr_anchorRingSeq[ri] = poseSeq;
            }

            // --- publish + rendezvous (spec D2/D8) --------------------------
            // The slot is written; the seq bump makes it visible. The engine
            // latches the seq ONCE for its two interpreter walks (0031 rev13),
            // so both eyes come from THIS pose or from none of it.
            gSohVREyeVPValid = 1;
            gSohVRPoseSeq = poseSeq;

            unsigned int havePair = sohvr_take_pair();
            int rendezvousHit = 0;
            int encodeHit = 0;
            {
                double t0w = CACurrentMediaTime();
                double budget = (double)sohvr_rendezvousMs / 1000.0;
                // Clamp the wait to what this frame can actually afford. The
                // blit itself measures ~0.05 ms, so the real constraint is the
                // compositor's own rendering deadline — waiting past it would
                // trade a frame of head latency (which the compositor
                // reprojects away) for a DROPPED frame, which it cannot. The
                // ms budget is the ceiling; the deadline is the floor, and on
                // device the deadline is the one that will bind.
                double toDeadline =
                    cp_time_to_cf_time_interval(cp_frame_timing_get_rendering_deadline(timing)) -
                    CACurrentMediaTime() - 0.002;
                if (toDeadline > 0.0 && toDeadline < budget) {
                    budget = toDeadline;
                } else if (toDeadline <= 0.0) {
                    budget = 0.0; // already late: present what we have
                }
                // R2a: wait on the PUBLISHED PAIR, not on the encode signal.
                // gSohVREyeSeqDone rises when the engine has finished ENCODING
                // both eyes; the textures the compositor samples are published
                // later, on GPU completion, one handler per eye. R1 waited on
                // the encode and then presented whatever was published, which
                // is how a split pair reaches the headset.
                while ((int)(havePair - poseSeq) < 0) {
                    if (CACurrentMediaTime() - t0w >= budget) {
                        break;
                    }
                    usleep(250);
                    havePair = sohvr_take_pair();
                }
                rendezvousHit = ((int)(havePair - poseSeq) >= 0);
                encodeHit = ((int)(gSohVREyeSeqDone - poseSeq) >= 0);
                sohvr_rvWaitMsLast = (CACurrentMediaTime() - t0w) * 1000.0;
                if (sohvr_rvWaitMsLast > sohvr_rvWaitMsMax) {
                    sohvr_rvWaitMsMax = sohvr_rvWaitMsLast;
                }
                if (rendezvousHit) {
                    sohvr_rvHits++;
                } else {
                    sohvr_rvMisses++;
                    unsigned int age = poseSeq - havePair;
                    if (havePair != 0 && age < 1000u && age > sohvr_pairAgeMax) {
                        sohvr_pairAgeMax = age;
                    }
                }
                if (encodeHit) {
                    sohvr_encHits++;
                } else {
                    sohvr_encMisses++;
                }
            }

            // --- flat-screen contexts (spec D3, overlay 0039) ---------------
            // gSohVRPairFlat is what the ENGINE latched for the pair now sitting
            // in the eye textures, so it describes the content we are about to
            // present rather than the tick that is running now.
            sohvr_flatActive = (gSohVRPairFlat != 0);
            if (sohvr_flatActive && !sohvr_flatPrev) {
                // Rising edge: place the panel once, in front of the player —
                // the donor places its quad at exactly this moment.
                sohvr_flatEnters++;
                soh3d_frozenHead = head;
                soh3d_haveScreenAnchor = true;
                NSLog(@"[SohVR] flat-screen context entered (#%llu) — panel placed",
                      (unsigned long long)sohvr_flatEnters);
            }
            sohvr_flatPrev = sohvr_flatActive;

            // Which anchor is presented. Rendezvous HIT: the pose we just
            // published is the pose in the textures, so present that. MISS: the
            // textures still hold the previous pair, so present the anchor THAT
            // pair was rendered against and let the compositor reproject it
            // (the CompositorServices equivalent of the donor's stale-layer
            // resubmit). A very old content anchor is worse than a live one, so
            // it expires after a second.
            //
            // R2a: the anchor is now looked up by the PRESENTED PAIR'S TAG, so
            // it is exactly the anchor that pair was rendered against — not
            // "the last anchor a rendezvous hit used", which drifts by however
            // many frames the engine is behind. Falls back to the previous
            // scheme if the tag has aged out of the ring.
            ar_device_anchor_t presentAnchor = anchor;
            double nowT = CACurrentMediaTime();
            if (!rendezvousHit && !sohvr_flatActive) {
                ar_device_anchor_t own = sohvr_anchor_for_seq(sohvr_pairTag);
                if (own != NULL) {
                    presentAnchor = own;
                } else if (sohvr_contentAnchor != NULL && (nowT - sohvr_contentAnchorTime) < 1.0) {
                    presentAnchor = sohvr_contentAnchor;
                }
            }
            cp_drawable_set_device_anchor(drawable, presentAnchor);
            if (rendezvousHit && sohvr_anchored) {
                sohvr_contentAnchor = anchor;
                sohvr_contentAnchorTime = nowT;
            }
            if (!rendezvousHit) {
                sohvr_pairRepeats++;
            }

            id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

            id<MTLTexture> eyeTex[2] = { nil, nil };
            id<MTLTexture> eyeDepth[2] = { nil, nil };
            int haveWorld = 0;
            if (sohvr_worldMode) {
                // R2a: the COHERENT PAIR, never the two published slots read
                // independently. haveWorld requires BOTH eyes — presenting one
                // eye of world and one eye of whatever the other slot happens
                // to hold is the split this whole mechanism exists to stop.
                if (sohvr_pairTag != 0 && sohvr_pairTex[0] != nil && sohvr_pairTex[1] != nil) {
                    eyeTex[0] = sohvr_pairTex[0];
                    eyeTex[1] = sohvr_pairTex[1];
                    eyeDepth[0] = sohvr_pairDepth[0];
                    eyeDepth[1] = sohvr_pairDepth[1];
                    haveWorld = 1;
                }
            }
            // R2b (spec D7): the HUD plane's texture, snapshotted under the
            // engine's own publish mutex exactly like the eye pair. It carries
            // the pair tag of the host frame that built it; a HUD from a
            // different frame than the eyes it sits over is counted, not
            // presented stale-forever.
            if (gSohVRHudPlane) {
                void* ht = NULL;
                unsigned int htag = 0;
                Soh3DHudSnapshot(&ht, &htag);
                if (ht != NULL) {
                    sohvr_hudTex = (__bridge id<MTLTexture>)ht;
                    sohvr_hudTag = htag;
                }
                if (haveWorld && sohvr_hudTex != nil && sohvr_hudTag != sohvr_pairTag) {
                    sohvr_contractMismatch++;
                }
            } else {
                sohvr_hudTex = nil;
            }
            // The frozen-world backdrop is kept as a ROLLING copy of the last
            // WORLD pair, refreshed every half second or so while not flat.
            // Capturing it on the flat rising edge instead does not work and
            // the reason is worth recording: overlay 0039 latches the predicate
            // at the tick boundary BEFORE the DL is built, so by the time the
            // shell sees gSohVRPairFlat the eye textures ALREADY hold the menu,
            // not the world. A rolling copy costs one full-slice blit every
            // ~30 frames and always has real world content in it.
            if (sohvr_flatWorldBackdrop && haveWorld &&
                (!sohvr_flatActive && (sohvr_frozenWorld[0] == nil || (sohvr_frameCount % 30) == 0))) {
                for (int e = 0; e < 2; e++) {
                    id<MTLTexture> src = eyeTex[e] ?: eyeTex[0];
                    if (src == nil) {
                        continue;
                    }
                    if (sohvr_frozenWorld[e] != nil && sohvr_frozenWorld[e].width == src.width &&
                        sohvr_frozenWorld[e].height == src.height &&
                        sohvr_frozenWorld[e].pixelFormat == src.pixelFormat) {
                        id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
                        [blit copyFromTexture:src toTexture:sohvr_frozenWorld[e]];
                        [blit endEncoding];
                        continue;
                    }
                    MTLTextureDescriptor* td =
                        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                                           width:src.width
                                                                          height:src.height
                                                                       mipmapped:NO];
                    td.usage = MTLTextureUsageShaderRead;
                    td.storageMode = MTLStorageModePrivate;
                    sohvr_frozenWorld[e] = [src.device newTextureWithDescriptor:td];
                    id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
                    [blit copyFromTexture:src toTexture:sohvr_frozenWorld[e]];
                    [blit endEncoding];
                }
            }
            sohvr_reason = sohvr_flatActive ? "flat_panel"
                                            : (sohvr_worldMode ? (haveWorld ? "world" : "no_eye_texture")
                                                               : "clear_only");

            simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(presentAnchor);
            // R2b (scope C): SIZE THE PANEL TO THE FRAME, never the frame to
            // the panel. R2a made the eye framebuffer follow the drawable's own
            // per-eye viewport (5087x4081 on device, aspect 1.246), which is
            // right for the world; the flat-screen contexts that land on this
            // panel were then being stretched across a 16:9 quad, which is
            // the user's "save selection screen is stretched too wide". Deriving
            // the quad's aspect from the PRESENTED TEXTURE is immune to the
            // eye-sizing latch, keeps the 3D-panel mode byte-identical (it
            // never runs this loop), and cannot race the flat latch: whatever
            // pixels are about to be drawn, the quad matches them. The panel is
            // fitted inside the shipped 2.75 x 1.55 m box so it never grows.
            float panelHalfW = soh3d_screenHalfW, panelHalfH = soh3d_screenHalfH;
            {
                id<MTLTexture> flatTex = sohvr_pairTex[0] ?: sohvr_pairTex[1];
                if (flatTex != nil && flatTex.height > 0) {
                    float fa = (float)flatTex.width / (float)flatTex.height;
                    if (fa > 0.2f && fa < 5.0f) {
                        panelHalfW = soh3d_screenHalfH * fa;
                        panelHalfH = soh3d_screenHalfH;
                        if (panelHalfW > soh3d_screenHalfW) {
                            panelHalfW = soh3d_screenHalfW;
                            panelHalfH = panelHalfW / fa;
                        }
                    }
                }
            }
            simd_float4x4 panelModel = simd_mul(soh3d_make_screen_anchor(soh3d_frozenHead),
                                                soh3d_scale(panelHalfW, panelHalfH, 1.0f));

            for (size_t v = 0; v < views; v++) {
                cp_view_t view = cp_drawable_get_view(drawable, v);
                cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
                size_t texIdx = cp_view_texture_map_get_texture_index(tmap);
                size_t slice = cp_view_texture_map_get_slice_index(tmap);
                MTLViewport vp = cp_view_texture_map_get_viewport(tmap);

                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.colorAttachments[0].texture = cp_drawable_get_color_texture(drawable, texIdx);
                pass.colorAttachments[0].slice = slice;
                pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
                size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);
                if (rmCount > 0) {
                    pass.rasterizationRateMap =
                        cp_drawable_get_rasterization_rate_map(drawable, texIdx < rmCount ? texIdx : 0);
                }
                id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIdx);
                if (depthTex != nil) {
                    pass.depthAttachment.texture = depthTex;
                    pass.depthAttachment.slice = slice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 1.0;
                }

                id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
                [enc setViewport:vp];
                [enc setDepthStencilState:sohvr_depthState];
                id<MTLTexture> tex = (v < 2) ? eyeTex[v] : eyeTex[0];
                id<MTLTexture> dep = (v < 2) ? eyeDepth[v] : eyeDepth[0];
                MTLPixelFormat sf = tex.pixelFormat, df = t0.pixelFormat;
                BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
                BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB || df == MTLPixelFormatRGBA8Unorm_sRGB ||
                                  df == MTLPixelFormatRGBA16Float);
                float srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;

                if (sohvr_flatActive) {
                    // spec D3: a flat frame renders MONO (0031 rev13 keeps
                    // the game's own matrix for it) and lands on the shipped
                    // world-locked panel — kaleido pause and its background
                    // capture stay one panel image, which is the whole point of
                    // the donor's overlay-routing rule.
                    //
                    // DEVIATION from the donor, recorded in VR-R1-NOTES: it can
                    // resubmit the frozen world layer with its OWN stale pose
                    // because OpenXR composes layers independently.
                    // CompositorServices has ONE anchor per drawable, and the
                    // panel must be world-locked, so the anchor has to be the
                    // live one and the frozen world behind it is therefore
                    // head-locked. It is drawn under the user's own surroundings
                    // dim (default 80%), where the sliding is not readable, and
                    // `vr set flatworld 0` removes it outright.
                    if (sohvr_flatWorldBackdrop && sohvr_frozenWorld[0] != nil && sohvr_blitPipeline != nil) {
                        id<MTLTexture> bg = (v < 2 && sohvr_frozenWorld[v]) ? sohvr_frozenWorld[v]
                                                                           : sohvr_frozenWorld[0];
                        MTLPixelFormat bsf = bg.pixelFormat;
                        float bsrgb = ((bsf == MTLPixelFormatBGRA8Unorm || bsf == MTLPixelFormatRGBA8Unorm) &&
                                       dstLinear)
                                          ? 1.0f
                                          : 0.0f;
                        [enc setRenderPipelineState:sohvr_blitPipeline];
                        [enc setFragmentBytes:&bsrgb length:sizeof(bsrgb) atIndex:0];
                        [enc setFragmentTexture:bg atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    float dimNow = soh3d_dimLevel;
                    if (dimNow > 0.003f && soh3d_dimPipeline != nil) {
                        [enc setRenderPipelineState:soh3d_dimPipeline];
                        [enc setDepthStencilState:soh3d_dimDepthState];
                        [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                    }
                    if (tex != nil && soh3d_pipeline != nil) {
                        simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                        simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));
                        simd_float4x4 pcp = matrix_identity_float4x4;
                        if (__builtin_available(visionOS 2.0, *)) {
                            pcp = cp_drawable_compute_projection(drawable,
                                                                 cp_axis_direction_convention_right_up_back, v);
                        }
                        simd_float4x4 mvp = simd_mul(pcp, simd_mul(eyeFromOrigin, panelModel));
                        [enc setRenderPipelineState:soh3d_pipeline];
                        [enc setDepthStencilState:soh3d_depthState];
                        [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                        [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                        [enc setFragmentTexture:tex atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                    }
                } else if (haveWorld && tex != nil && sohvr_blitPipeline != nil) {
                    // R1 depth handoff (spec D2 / D-044): CONVERT the
                    // engine's forward-Z depth into the drawable's reverse-Z /
                    // infinite-far target. Only when everything the conversion
                    // needs is present and measured; otherwise fall back to the
                    // R0 colour-only blit rather than write nonsense depth,
                    // which is worse than writing none.
                    int useDepth = (sohvr_depthValid && dep != nil && sohvr_blitDepthPipeline != nil);
                    if (useDepth) {
                        SohVRDepthCvt cvt = { sohvr_near, sohvr_far, sohvr_depthNearM * sohvr_scale, 1.0f };
                        [enc setRenderPipelineState:sohvr_blitDepthPipeline];
                        [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                        [enc setFragmentBytes:&cvt length:sizeof(cvt) atIndex:1];
                        [enc setFragmentTexture:tex atIndex:0];
                        [enc setFragmentTexture:dep atIndex:1];
                    } else {
                        [enc setRenderPipelineState:sohvr_blitPipeline];
                        [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
                        [enc setFragmentTexture:tex atIndex:0];
                    }
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

                    // R2b (spec D7 / VR-DONOR-MAP §6): THE HUD PLANE. The
                    // interface was rendered ONCE, into its own transparent
                    // framebuffer (overlay 0031 rev15) off a display list
                    // overlay 0043 unchained from the world. Here the SAME
                    // pixels are placed at ONE world position in front of the
                    // head and drawn with THIS eye's own projection, so the two
                    // eyes see it from two eye positions and it fuses. Placing
                    // it head-locked (mvp built from deviceFromEye, not from
                    // the anchor) is the donor's `gVrHudAttach = 0` and keeps
                    // it readable while the player turns.
                    if (sohvr_hudTex != nil && sohvr_hudPipeline != nil) {
                        float hw = sohvr_hudWidth * 0.5f;
                        float hh = hw;
                        if (sohvr_hudTex.width > 0) {
                            hh = hw * (float)sohvr_hudTex.height / (float)sohvr_hudTex.width;
                        }
                        simd_float4x4 deviceFromEye = cp_view_get_transform(view);
                        simd_float4x4 eyeFromDevice = simd_inverse(deviceFromEye);
                        simd_float4x4 pcp = matrix_identity_float4x4;
                        if (__builtin_available(visionOS 2.0, *)) {
                            pcp = cp_drawable_compute_projection(drawable,
                                                                 cp_axis_direction_convention_right_up_back, v);
                        }
                        simd_float4x4 hudModel =
                            simd_mul(soh3d_translate(0.0f, sohvr_hudUp, -sohvr_hudDist),
                                     soh3d_scale(hw, hh, 1.0f));
                        simd_float4x4 hudMvp = simd_mul(pcp, simd_mul(eyeFromDevice, hudModel));
                        MTLPixelFormat hf = sohvr_hudTex.pixelFormat;
                        float hsrgb = ((hf == MTLPixelFormatBGRA8Unorm || hf == MTLPixelFormatRGBA8Unorm) &&
                                       dstLinear)
                                          ? 1.0f
                                          : 0.0f;
                        // R7 verdict 7: {srgbDecode, luminance-key gain}. Gain 0
                        // is the pre-R7 alpha-only path and the A/B control.
                        simd_float2 hudParams = simd_make_float2(hsrgb, sohvr_hudKeyGain);
                        [enc setRenderPipelineState:sohvr_hudPipeline];
                        [enc setDepthStencilState:sohvr_depthState];
                        [enc setVertexBytes:&hudMvp length:sizeof(hudMvp) atIndex:0];
                        [enc setFragmentBytes:&hudParams length:sizeof(hudParams) atIndex:0];
                        [enc setFragmentTexture:sohvr_hudTex atIndex:0];
                        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                        if (v == 0) {
                            sohvr_hudPresents++;
                        }
                    }
                } else if (sohvr_clearPipeline != nil) {
                    // R0a: a DISTINCT solid colour per eye, half-transparent so
                    // passthrough is still visible under .mixed.
                    simd_float4 col = (v == 0) ? simd_make_float4(0.75f, 0.10f, 0.10f, 0.5f)
                                               : simd_make_float4(0.10f, 0.20f, 0.85f, 0.5f);
                    [enc setRenderPipelineState:sohvr_clearPipeline];
                    [enc setFragmentBytes:&col length:sizeof(col) atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [enc endEncoding];
            }

            cp_drawable_encode_present(drawable, command_buffer);
            // R7 verdict 9: a GPU fault, a hang timeout or an out-of-memory
            // command buffer reports through `error` and NOT through any signal
            // -- which is one of the ways the 2026-09-04 death could have left
            // no crash report. It costs one block per frame and it is the only
            // notice we would ever get.
            [command_buffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
                if (cb.error != nil) {
                    char sohDetail[192];
                    snprintf(sohDetail, sizeof(sohDetail), "vr present cb error %ld: %s avail_mb=%ld",
                             (long)cb.error.code, cb.error.localizedDescription.UTF8String ?: "?",
                             SohIos_AvailableMemoryMB());
                    SohIos_ReportFatalContext("metal", sohDetail);
                }
            }];
            [command_buffer commit];

            sohvr_frameCount++;
            sohvr_note_present();
            if (sohvr_frameCount == 3 || (sohvr_frameCount % 600) == 0) {
                NSLog(@"[SohVR] frame %d views=%zu world=%d flat=%d rv=%llu/%llu wait=%.2fms eyeL=%d eyeR=%d "
                      @"present_hz=%.2f",
                      sohvr_frameCount, views, haveWorld, sohvr_flatActive, (unsigned long long)sohvr_rvHits,
                      (unsigned long long)sohvr_rvMisses, sohvr_rvWaitMsLast, Soh3D_GetEyeFrames(1),
                      Soh3D_GetEyeFrames(2), sohvr_presentHz);
            }

            cp_frame_end_submission(frame);

            if (sohvr_captureReq) {
                sohvr_captureReq = 0;
                sohvr_capture_eyes(queue);
                sohvr_captureDone = 1;
            }
            if (sohvr_hudProbeReq) {
                sohvr_hudProbeReq = 0;
                sohvr_probe_hud(queue);
                sohvr_hudProbeDone = 1;
            }
        }
    }

    // Hand the engine back its own camera BEFORE anything else: leaving
    // gSohVRCamValid set would keep overlay 0037 pushing a dead head pose into
    // the game View after the loop is gone (spec D9 — every exit restores).
    gSohVRCamValid = 0;
    gSohVREyeVPValid = 0;
    gSohVRPairFlat = 0;
    // R2a: hand the engine back its own defaults. gSoh3DEyeW/H = 0 restores the
    // 3840x2160 the 3D PANEL mode has always used, so leaving VR can never
    // leave the panel rendering at a VR eye's extent (the sibling's trap D14,
    // "a priority claim over a shared render extent must be a LEASE").
    gSoh3DEyeW = 0;
    gSoh3DEyeH = 0;
    gSohVRRefreshHz = 0;
    gSohVRRoomImage = 0;
    gSohVRRoomFixedCam = 0;
    // R2b: hand the game side back its defaults too. gSohVRFpActive gates the
    // steering table and the limb cull in overlays 0041/0042, so leaving it set
    // after the loop is gone would keep the flat window steering off a dead
    // head yaw (spec D9 — every exit restores).
    gSohVRFpActive = 0;
    gSohVRHeadingValid = 0;
    // R6 -- THE CRASH FIX, AT THE CAUSE. R5 cleared gSohVROverlayDL here.
    // That variable is the GAME thread's own publication: overlay 0043
    // writes it while building the frame's display lists and overlay 0031
    // consumes it a few hundred microseconds later in the same thread, and
    // this teardown runs on the COMPOSITOR LOOP thread. Landing between
    // 0031's gate and 0031's interpreter call handed Fast::Interpreter::Run
    // a NULL display list, which faults on the first command word -- R5's
    // rapid enter/exit SIGSEGV at address 0. Measured at 2 lost races per
    // 60 enter/exit cycles, which is exactly the rate R5 crashed at.
    //
    // Nothing is lost by not clearing it: 0043 republishes or NULLs the
    // pointer on every single frame it builds, on the same thread that
    // reads it, and 0031's walk is gated on gSohVRMode as well -- so one
    // game frame after the mode flag drops there is no HUD walk at all.
    // The general rule this round adds to the spec's D9 restore list:
    // an exit restores what THIS THREAD owns; a variable another thread
    // publishes every frame is not ours to clear.
    //
    // ...WHICH APPLIES TO THE HAND-MATRIX TABLE TOO, and R6's first version of
    // this exit broke its own rule three lines after stating it: it called
    // SohVR_ClearHandMtxTable() from here. Every writer of that table is the
    // GAME thread (overlay 0042's limb override sets the tag, 0050's
    // Matrix_ToMtx funnel appends the pointers), and a draw that had already
    // sampled gSohVRFpActive could still be writing while this thread zeroed
    // it. Milder than the display-list crash -- the consumers are
    // bounds-checked, so it costs one frame of torn hand matrix rather than a
    // fault -- and wrong in exactly the same way. So: ASK, and let the game
    // thread clear it in overlay 0039's per-frame latch block, which is the
    // one place that runs every frame on the thread that owns the words.
    gSohVRHandMtxClearReq = 1;
    // R4: every exit restores (spec D9). A VR exit mid-swing must not leave
    // the game side with a live hand matrix, a HOT tier, or a Sense button held
    // -- all three would keep acting on the flat window, where there are no
    // hands at all.
    SohSense_Stop();
    SohVrPhys_Reset();
    SohVrPhys_SetMesh(NULL, 0);
    gSohVRBladeValid[0] = gSohVRBladeValid[1] = 0;
    gSohVRMeshCount = 0;
    gSohVRHandValid[0] = gSohVRHandValid[1] = 0;
    gSohVRSenseActive = 0;
    gSohVRPhysVersion = 0;
    for (int h = 0; h < 2; h++) {
        gSohVRSenseBtn[h] = 0;
        gSohVRSenseStickX[h] = gSohVRSenseStickY[h] = 0.0f;
        gSohVRSwingTier[h] = 0;
        gSohVRSwingMid[h] = gSohVRSwingHand[h] = 0.0f;
    }
    sohvr_hudTex = nil;
    sohvr_hudTag = 0;
    sohvr_eyeWWant = sohvr_eyeHWant = 0;
    sohvr_eyeWantHeld = 0;
    sohvr_contractSeen = 0;
    sohvr_contract.valid = 0;
    sohvr_depthValid = 0;
    sohvr_frozenWorld[0] = sohvr_frozenWorld[1] = nil;
    sohvr_contentAnchor = NULL;
    sohvr_pairTex[0] = sohvr_pairTex[1] = nil;
    sohvr_pairDepth[0] = sohvr_pairDepth[1] = nil;
    sohvr_pairTag = 0;
    for (int i = 0; i < SOHVR_ANCHOR_RING; i++) {
        sohvr_anchorRing[i] = NULL;
        sohvr_anchorRingSeq[i] = 0;
    }
    sohvr_flatActive = sohvr_flatPrev = 0;
    // R8 part C: THE RATCHET. The ~800 MB of eye, HUD and compositor surfaces VR
    // takes IS given back above -- the vr-mem.log toggles move by 750-870 MB in
    // both directions. What did NOT come back was the ~1 GB the resource cache
    // grew WHILE in VR, because nothing ever evicts from it; that is the leak
    // this round fixes, and leaving VR is the single best moment to collect it:
    // every texture the immersive session streamed is now cold and the game
    // thread is about to draw a flat frame that needs almost none of them.
    {
        extern void SohIos_RequestMemoryTrim(const char* why);
        SohIos_RequestMemoryTrim("vr-exit");
    }
    if (notifyEnded) {
        Soh3D_Immersive_Ended();
    }
    gSohVRRunning = 0; // signal the shell LAST
}

int SohVR_AnyLoopRunning(void) {
    return (gSohVRRunning || gSoh3DRunning) ? 1 : 0;
}

// --- R17 part B item 2(b): THE VR ENTRY WATCHDOG -----------------------------
//
// What it is for. Twice in four launches of 1.0.1.21 the heartbeat shows VR
// entered, exited within seconds, and re-entered -- the user's own workaround for
// a black entry, performed by hand. The state has a name in code
// (sohvr_reason == "no_eye_texture", i.e. sohvr_pairTag is 0 or one
// sohvr_pairTex is nil while the compositor presents empty drawables), and the
// three candidate causes are ranked in this round's notes. This does two things
// about it and deliberately not a third:
//
//   t+3 s   ONE line into vr-mem.log with everything a diagnosis needs. Not a
//           stream: one line, so the next pull says which of the three causes
//           it was without anybody having to reproduce it.
//   t+6 s   still stalled -> run THE USER'S OWN WORKAROUND through the supported
//           path exactly once: Soh_EnterVR(false) on the main thread, wait for
//           the loop to leave the layerRenderer AND for gSohVRMode to clear
//           (which is Soh_Exit3DFinalize, after Swift has dismissed the space),
//           then Soh_EnterVR(true). Nothing here touches the compositor, the
//           space, or the engine's mode flags directly -- it presses the same
//           two buttons he does.
//
// A SECOND stall in the same run does not heal again: it says so and leaves VR
// exited, because a workaround that did not work twice is not a workaround.
//
// What it deliberately does NOT do: change the eye-size entry contract. Cause 1
// (gSoh3DEyeW/H zeroed on exit, the engine rendering at the 3840x2160 default
// until `first` bypasses SOHVR_SIZE_HOLD to adopt the drawable's ~5087x4081 --
// two 166 MB reallocations in the middle of a transition, under memory pressure)
// is the likeliest of the three and is a structural change to when the engine
// may resize. It is a follow-up, on purpose: this round instruments it (the
// "eye size adopted" note carries the old size, the new one, and the headroom)
// rather than guessing at it blind.
static void* SohVR_EntryWatchdogThread(void* arg) {
    (void)arg;
    pthread_setname_np("soh-vr-entry-watchdog");
    extern void SohIos_VrNote(const char* what, const char* detail);
    extern volatile int gSohVREntryStalls, gSohVREntryHeals;
    unsigned int gen = sohvr_entryGen;
    // Retired the moment the loop stops, or a NEWER entry starts: a watchdog
    // that outlived its own entry must never heal somebody else's.
    for (int i = 0; i < 60 && gSohVRRunning && gen == sohvr_entryGen; i++) {
        usleep(50 * 1000);
    }
    if (!gSohVRRunning || gen != sohvr_entryGen) {
        return NULL;
    }
    if (sohvr_presents != 0 && sohvr_pairAccepts != 0) {
        return NULL; // entered cleanly; nothing to say and nothing to do
    }
    char detail[512];
    snprintf(detail, sizeof(detail),
             "reason=%s frames=%d presents=%llu pair_accepts=%llu pair_tag=%u eye_frames=%d/%d "
             "eye=%dx%d layer_state=%d mode3d=%d vr_mode=%d eye_vp_valid=%d avail_mb=%ld",
             sohvr_reason ? sohvr_reason : "?", sohvr_frameCount, (unsigned long long)sohvr_presents,
             (unsigned long long)sohvr_pairAccepts, sohvr_pairTag, Soh3D_GetEyeFrames(1), Soh3D_GetEyeFrames(2),
             (int)gSoh3DEyeW, (int)gSoh3DEyeH, (int)sohvr_layerState, Soh_Get3DMode(), gSohVRMode,
             gSohVREyeVPValid, SohIos_AvailableMemoryMB());
    gSohVREntryStalls = gSohVREntryStalls + 1;
    SohIos_VrNote("entry stalled", detail);
    // Another 3 s before acting: a slow first pair (a cold O2R read, a scene
    // load) is not a stall, and 6 s is longer than any entry that has ever
    // worked in this app.
    for (int i = 0; i < 60 && gSohVRRunning && gen == sohvr_entryGen; i++) {
        usleep(50 * 1000);
    }
    if (!gSohVRRunning || gen != sohvr_entryGen) {
        return NULL;
    }
    if (sohvr_presents != 0 && sohvr_pairAccepts != 0) {
        SohIos_VrNote("entry recovered on its own", detail);
        return NULL;
    }
    if (sohvr_entryHealedOnce) {
        SohIos_VrNote("entry heal gave up", detail);
        dispatch_async(dispatch_get_main_queue(), ^{ Soh_EnterVR(false); });
        return NULL;
    }
    sohvr_entryHealedOnce = 1;
    gSohVREntryHeals = gSohVREntryHeals + 1;
    SohIos_VrNote("entry heal: exiting VR", detail);
    dispatch_async(dispatch_get_main_queue(), ^{ Soh_EnterVR(false); });
    // The exit is asynchronous in three stages (stop flag, the loop leaving the
    // layerRenderer, Swift dismissing the space and Soh_Exit3DFinalize clearing
    // gSohVRMode). Re-entering before the last of those returns early in
    // Soh_EnterVR's own `if (gSoh3DMode) return;` guard and would leave the app
    // in 2D with no explanation, so BOTH are waited for.
    for (int i = 0; i < 500 && (gSohVRRunning || gSohVRMode || Soh_Get3DMode()); i++) {
        usleep(10 * 1000);
    }
    if (gSohVRRunning || gSohVRMode || Soh_Get3DMode()) {
        SohIos_VrNote("entry heal: the exit did not complete -- NOT re-entering", detail);
        return NULL;
    }
    usleep(500 * 1000); // let the space finish dismissing before asking for it again
    SohIos_VrNote("entry heal: re-entering VR", "");
    dispatch_async(dispatch_get_main_queue(), ^{ Soh_EnterVR(true); });
    return NULL;
}

// --- the diagnostics dump family (spec D10) --------------------------------
static NSString* sohvr_dump_pose(void) {
    simd_float3 e0 = sohvr_eyeTrack[0].columns[3].xyz;
    simd_float3 e1 = sohvr_eyeTrack[1].columns[3].xyz;
    // The convention assertion is NOT "the world-space delta is 63 mm along X"
    // (it isn't, under a yawed head) but "the delta reduces to +63 mm along X
    // in EYE space" — rotate the world delta back through eye 0's basis.
    simd_float3 d = e1 - e0;
    simd_float3 ex = sohvr_eyeTrack[0].columns[0].xyz;
    simd_float3 ey = sohvr_eyeTrack[0].columns[1].xyz;
    simd_float3 ez = sohvr_eyeTrack[0].columns[2].xyz;
    float dx = simd_dot(d, ex), dy = simd_dot(d, ey), dz = simd_dot(d, ez);
    float len = simd_length(d);
    BOOL pass = (fabsf(dx - 2.0f * kSohVRHalfIpd) < 0.005f) && (fabsf(dy) < 0.002f) && (fabsf(dz) < 0.002f);
    return [NSString
        stringWithFormat:@"ok vr_pose injected=%d anchored=%d views=%zu psrc=%d synth_eye2=%d "
                          "head=%.4f,%.4f,%.4f eye0=%.4f,%.4f,%.4f eye1=%.4f,%.4f,%.4f "
                          "ipd_eye_dx=%.5f ipd_eye_dy=%.5f ipd_eye_dz=%.5f ipd_len=%.5f ipd_check=%s "
                          "cam_eye=%.1f,%.1f,%.1f cam_fwd=%.3f,%.3f,%.3f cam_right=%.3f,%.3f,%.3f cam_dist=%.1f "
                          "scale=%.2f height=%.3f near=%.1f far=%.1f "
                          "eye_game=%.2f,%.2f,%.2f "
                          "eyeL_row0=%.5f,%.5f,%.5f,%.5f eyeL_row3=%.5f,%.5f,%.5f,%.5f "
                          "eyeR_row0=%.5f,%.5f,%.5f,%.5f eyeR_row3=%.5f,%.5f,%.5f,%.5f seq=%llu",
                         sohvr_injectOn, sohvr_anchored, sohvr_contract.views, sohvr_poseSrc, sohvr_synthEye2,
                         sohvr_head.columns[3].x, sohvr_head.columns[3].y, sohvr_head.columns[3].z, e0.x, e0.y, e0.z,
                         e1.x, e1.y, e1.z, dx, dy, dz, len, pass ? "PASS" : "FAIL", gSoh3DCamEye[0], gSoh3DCamEye[1],
                         gSoh3DCamEye[2], gSoh3DCamFwd[0], gSoh3DCamFwd[1], gSoh3DCamFwd[2], gSoh3DCamRight[0],
                         gSoh3DCamRight[1], gSoh3DCamRight[2], gSoh3DCamDist, sohvr_scale, sohvr_height, sohvr_near,
                         sohvr_far, sohvr_eyeGame[0].x, sohvr_eyeGame[0].y, sohvr_eyeGame[0].z,
                         sohvr_eyeVPDump[0][0], sohvr_eyeVPDump[0][1], sohvr_eyeVPDump[0][2],
                         sohvr_eyeVPDump[0][3], sohvr_eyeVPDump[0][12], sohvr_eyeVPDump[0][13],
                         sohvr_eyeVPDump[0][14], sohvr_eyeVPDump[0][15], sohvr_eyeVPDump[1][0],
                         sohvr_eyeVPDump[1][1], sohvr_eyeVPDump[1][2], sohvr_eyeVPDump[1][3],
                         sohvr_eyeVPDump[1][12], sohvr_eyeVPDump[1][13], sohvr_eyeVPDump[1][14],
                         sohvr_eyeVPDump[1][15], (unsigned long long)(++sohvr_dumpSeq)];
}

static NSString* sohvr_dump_mode(void) {
    static const char* kSpaces[3] = { "SohVR", "SohVRTestA", "SohVRTestB" };
    static const char* kModes[3] = { "flat", "panel3D", "vr" };
    // R7 verdict 1: `style=` and `limbs=` report WHAT THIS BUILD REQUESTS, and
    // they are labelled that way on purpose. Neither is a query of the system:
    // visionOS exposes no read-back for the live immersion style or for
    // upper-limb visibility, so the honest claim these two support is "the app
    // asks for full immersion with limbs hidden, and nothing at runtime can
    // change that" — which is exactly what the `vr style mixed` no-op makes
    // testable. Whether the wearer's arms are actually gone is a headset
    // verdict, and D-052 decision 8's rule says to say so rather than let a
    // counter that shares a convention with the thing it tests read green
    // through a bug.
    return [NSString stringWithFormat:@"ok vr_mode mode=%s space=%s style_req=%s limbs_req=%s panel_mode=%d loop_running=%d "
                                       "loop_stop=%d reason=%s world=%d eye_frames=%d,%d eye_size=%dx%d paused=%d "
                                       "in_play=%d aiming=%d anchored=%d injected=%d contract=%d vp_valid=%d "
                                       "soh3d_loop=%d flat_latch=%d flat_raw=%d flat_active=%d flat_enters=%llu "
                                       "flat_backdrop=%d cam_valid=%d cam_fovy=%.1f anchor_valid=%d "
                                       "anchor_eye=%.1f,%.1f,%.1f recenters=%llu seq=%llu",
                                      kModes[Soh_GetMode() % 3], kSpaces[sohvr_variant % 3],
                                      sohvr_styleFull ? "full" : "mixed",
                                      sohvr_styleFull ? "hidden" : "visible", Soh_Get3DMode(), gSohVRRunning, gSohVRStop,
                                      sohvr_reason, sohvr_worldMode, Soh3D_GetEyeFrames(1), Soh3D_GetEyeFrames(2),
                                      gSoh3DEyeW, gSoh3DEyeH, gSoh3DPaused, gSoh3DInPlay, gSoh3DAiming,
                                      sohvr_anchored, sohvr_injectOn, sohvr_contract.valid, gSohVREyeVPValid,
                                      gSoh3DRunning, gSohVRFlatLatch, gSohVRFlatRaw, sohvr_flatActive,
                                      (unsigned long long)sohvr_flatEnters, sohvr_flatWorldBackdrop, gSohVRCamValid,
                                      gSohVRCamFovy, gSohVRAnchorValid, gSohVRAnchorEye[0], gSohVRAnchorEye[1],
                                      gSohVRAnchorEye[2], (unsigned long long)sohvr_recenters,
                                      (unsigned long long)(++sohvr_dumpSeq)];
}

static NSString* sohvr_dump_contract(void) {
    static const char* kKind[3] = { "forwardZ", "reverseZ_finite", "reverseZ_infinite_far" };
    NSMutableString* s = [NSMutableString stringWithFormat:@"ok vr_contract valid=%d views=%zu textures=%zu "
                                                            "ratemaps=%zu layout=%d(%s) colorFmt=%lu depthFmt=%lu",
                                                           sohvr_contract.valid, sohvr_contract.views,
                                                           sohvr_contract.textures, sohvr_contract.ratemaps,
                                                           sohvr_contract.layout,
                                                           sohvr_contract.layout == 0 ? "dedicated" : "layered",
                                                           sohvr_contract.colorFmt, sohvr_contract.depthFmt];
    for (int e = 0; e < 2; e++) {
        [s appendFormat:@" eye%d_vp=%.0fx%.0f eye%d_tex=%zu eye%d_slice=%zu eye%d_tan=%.4f,%.4f,%.4f,%.4f", e,
                        sohvr_contract.vpW[e], sohvr_contract.vpH[e], e, sohvr_contract.texIdx[e], e,
                        sohvr_contract.slice[e], e, sohvr_contract.tanL[e], sohvr_contract.tanR[e],
                        sohvr_contract.tanB[e], sohvr_contract.tanT[e]];
    }
    // The depth-contract line: what the COMPOSITOR's own projection does, and
    // what we hand the engine instead.
    for (int e = 0; e < 2; e++) {
        [s appendFormat:@" eye%d_depth=%s eye%d_c2z=%.6f eye%d_c3z=%.6f eye%d_near_m=%.4f eye%d_far_m=%.1f "
                         "eye%d_zndc_1m=%.6f eye%d_zndc_1000m=%.6f",
                        e, kKind[sohvr_contract.depthKind[e] % 3], e, sohvr_contract.rawC2z[e], e,
                        sohvr_contract.rawC3z[e], e, sohvr_contract.depthNear[e], e, sohvr_contract.depthFar[e], e,
                        sohvr_contract.zndc1m[e], e, sohvr_contract.zndc1000m[e]];
    }
    [s appendFormat:@" cp_depth_range_far_m=%.1f cp_depth_range_near_m=%.4f", sohvr_contract.rangeFar,
                    sohvr_contract.rangeNear];
    [s appendFormat:@" engine_depth=forwardZ_clear1.0_less engine_near_units=%.1f engine_far_units=%.1f "
                     "engine_eye_fb=%dx%d eye_budget=%.0f eye_scale=%.2f eye_clamped=%d "
                     "eye_fb_mpix=%.2f eye_tex=%dx%d/%dx%d room_mode=%d room_image=%d",
                    sohvr_near, sohvr_far, gSoh3DEyeW, gSoh3DEyeH, sohvr_eyeBudget, sohvr_eyeScale,
                    sohvr_eyeClamped, (double)gSoh3DEyeW * (double)gSoh3DEyeH / 1.0e6, sohvr_captureW[0],
                    sohvr_captureH[0], sohvr_captureW[1], sohvr_captureH[1], gSohVRRoomMode, gSohVRRoomImage];
    // R2b scope F (the rainbow hunt): everything that could be changing under
    // the engine while the user looks at the Mac Virtual Display. Sample this at
    // 2 Hz for 10 s with the MVD in view and again with it out of view; the
    // counter that moves is the hypothesis that survives.
    [s appendFormat:@" vp_changes=%llu tan_changes=%llu ratemap_changes=%llu fb_reallocs=%llu "
                     "contract_mismatch=%llu size_held=%d vbuf_pool=8 seq=%llu",
                    (unsigned long long)sohvr_vpChanges, (unsigned long long)sohvr_tanChanges,
                    (unsigned long long)sohvr_ratemapChanges, (unsigned long long)sohvr_fbReallocs,
                    (unsigned long long)sohvr_contractMismatch, sohvr_eyeWantHeld,
                    (unsigned long long)(++sohvr_dumpSeq)];
    // R17 part B item 2: the entry watchdog's own two numbers. entry_stalls > 0
    // with entry_heals = 0 is "it happened and healed itself"; both non-zero is
    // "it happened and the workaround was run for him".
    {
        extern volatile int gSohVREntryStalls, gSohVREntryHeals;
        [s appendFormat:@" entry_stalls=%d entry_heals=%d layer_state=%d", (int)gSohVREntryStalls,
                        (int)gSohVREntryHeals, (int)sohvr_layerState];
    }
    return s;
}

static NSString* sohvr_dump_pace(void) {
    float fps = 0, tps = 0;
    SohIos_PacingStats(&fps, &tps);
    uint64_t rvTotal = sohvr_rvHits + sohvr_rvMisses;
    uint64_t encTotal = sohvr_encHits + sohvr_encMisses;
    // R2a: the pacing line is unambiguous on purpose. present_hz is the
    // COMPOSITOR. engine_fps is what the engine actually achieved. interp_hz is
    // what GetInterpolationFPS was told to aim for, which is present_hz/hostdiv
    // and NEVER the raw compositor rate. tick_tps is OoT's own 20 Hz and is the
    // slow-motion assert. rv_hit_pct counts PUBLISHED pairs (the pixels being
    // presented), enc_hit_pct counts finished encodes; pair_splits counts the
    // times the two eyes disagreed and the pair was therefore NOT presented.
    return [NSString stringWithFormat:@"ok vr_pace engine_fps=%.2f tick_tps=%.2f present_hz=%.2f presents=%llu "
                                       "gpu_ms=%.2f interp_hz=%d hostdiv=%d hostdiv_req=%d engine_hz=%d "
                                       "rv_hits=%llu rv_misses=%llu rv_hit_pct=%.1f enc_hit_pct=%.1f "
                                       "pair_tag=%u pair_accepts=%llu pair_repeats=%llu pair_splits=%llu "
                                       "pair_age_max=%u rv_wait_ms=%.2f rv_wait_max_ms=%.2f rv_budget_ms=%.1f "
                                       "seq=%llu",
                                      fps, tps, sohvr_presentHz, (unsigned long long)sohvr_presents, gSohIosGpuMs,
                                      gSohVRRefreshHz, sohvr_hostDivEff, sohvr_hostDiv, sohvr_engineHz,
                                      (unsigned long long)sohvr_rvHits, (unsigned long long)sohvr_rvMisses,
                                      rvTotal ? (100.0 * (double)sohvr_rvHits / (double)rvTotal) : 0.0,
                                      encTotal ? (100.0 * (double)sohvr_encHits / (double)encTotal) : 0.0,
                                      sohvr_pairTag, (unsigned long long)sohvr_pairAccepts,
                                      (unsigned long long)sohvr_pairRepeats, (unsigned long long)sohvr_pairSplits,
                                      sohvr_pairAgeMax, sohvr_rvWaitMsLast, sohvr_rvWaitMsMax, sohvr_rendezvousMs,
                                      (unsigned long long)(++sohvr_dumpSeq)];
}

// R2b: first person, steering and the HUD plane, in one line (spec D4/D6/D7).
// `vr room` is the green-floor diagnostic: an image-backed room whose active
// camera is NOT CAM_SET_PREREND_FIXED (setting 0x2A) never draws its authored
// background, so what shows is the room's bare placeholder geometry.
static NSString* sohvr_dump_room(void) {
    return [NSString
        stringWithFormat:@"ok vr_room room_mode=%d room_image=%d cam_setting=%d flat_latch=%d flat_raw=%d "
                          "fp_active=%d fp_far=%d fp_seated=%d fp_enters=%d fp_resumes=%d "
                          "room_fixedcam=%d yaw_reset_pending=%d anchor=%.2f,%.2f,%.2f "
                          "eye_game=%.2f,%.2f,%.2f "
                          "eye_height=%.1f body_yaw=%d head_yaw=%d head_valid=%d "
                          "turn_style=%s turn_deg=%.0f smooth_dps=%.0f turn_axis=%.2f snaps=%llu smooth_total=%.0f "
                          "hide_body=%d follow_head=%d pinned_yaw=%d pin_ticks=%d kine_ticks=%d "
                          "pad_cur=0x%04x pad_c_masked=0x%04x "
                          "ztarget=%d hop=%d roll_active=%d roll_secs=%.2f flipcam=%d flip_deg=%.0f flip_kind=%d "
                          "flip_force=%d eye_fwd=%.3f,%.3f,%.3f "
                          "flips=%llu rolls=%llu suppressed=%d stab_ticks=%d stabs=%d "
                          "stab_quads=%d covered=%d vanilla_quads_skipped=%d cover_drops=%d "
                          "chop_ticks=%d chops=%d atk_kind=%d atk_t=%.3f atk_reach=%.3f atk_ang=%.3f "
                          "atk_axdot=%.3f atk_hamdot=%.3f atk_swlimb=%.3f "
                          "atk_peak_m=%.3f atk_peak_dot=%.3f atk_blade_m=%.3f "
                          "atk_up_deg=%.1f atk_start_deg=%.1f atk_fwd_deg=%.1f atk_fwd_u=%.2f atk_drop=%.3f "
                          "slash_arc=%.0f slash_down=%.0f slash_reach=%.2f "
                          "slash_secs=%.2f slash_drop=%.2f slash_hold=%.2f slash_back=%.2f "
                          "jump_arc=%.0f jump_secs=%.2f jump_reach=%.2f atk_dur=%.2f "
                          "hammers=%d hammer_hits=%d hammer_env=%llu hammer_arc=%.0f hammer_down=%.0f "
                          "hammer_reach=%.2f hammer_drop=%.2f hammer_secs=%.2f hammer_hold=%.2f "
                          "hammer_back=%.2f hammer_probe=%.1f "
                          "shield_stops=%d swing_sfx=%d jumpslash_vanilla=%d chop_yells=%d melee_anim=%d "
                          "link_vel=%.2f link_pos=%.1f,%.1f,%.1f ocarina=%d ocarina_force=%d "
                          "stab_env=%llu chop_env=%llu atk_dropped=%llu "
                          "crouch=%d crouch_now=%.3f crouch_frac=%.2f crouch_drop=%.2f crouches=%llu "
                          "grip_chord=%d hud_plane=%d hud_dl=%d hud_frames=%d hud_dl_races=%d hud_presents=%llu hud_tag=%u pair_tag=%u "
                          "hud_fb=%dx%d hud_dist_m=%.2f hud_width_m=%.2f hud_up_m=%.2f hud_key=%.1f "
                          "scale=%.1f height_trim_m=%.2f eye_offset_u=%.1f height_cals=%llu "
                          "height_cal_pending=%d height_cal_deferred=%llu "
                          "ladder_follow=%d ladder_delta=%d ladder_seq=%d ladder_follows=%llu "
                          "boom_direct=%d boom_throws=%u "
                          "flatworld=%d seq=%llu",
                         gSohVRRoomMode, gSohVRRoomImage, gSohVRCamSetting, gSohVRFlatLatch, gSohVRFlatRaw,
                         gSohVRFpActive, gSohVRFpFar, sohvr_fpSeated, gSohVRFpEntered, gSohVRFpResumed,
                         gSohVRRoomFixedCam, sohvr_yawResetReq, gSohVRFpAnchor[0],
                         gSohVRFpAnchor[1], gSohVRFpAnchor[2],
                         // R8 item 5: the game-space eye beside the anchor it is
                         // supposed to land on, in ONE dump. Read from two
                         // separate bridge round-trips they differ by however
                         // far Link walked in between, which is not what the
                         // calibration claim is about.
                         sohvr_eyeGame[0].x, sohvr_eyeGame[0].y, sohvr_eyeGame[0].z, gSohVRFpEyeHeight, gSohVRFpBodyYaw,
                         gSohVRHeadingYaw, gSohVRHeadingValid,
                         (sohvr_turnDeg <= 0.5f ? "smooth" : "snap"), sohvr_turnDeg, sohvr_smoothDegPerSec,
                         gSohVRTurnAxis, (unsigned long long)sohvr_snapTurns, sohvr_turnDegTotal,
                         gSohVRHideBody, gSohVRBodyFollowsHead, gSohVRPinnedYaw,
                         gSohVRDirectTicks, gSohVRKinematicTicks,
                         (unsigned)gSohVRPadCur, (unsigned)gSohVRPadCMasked,
                         gSohVRZTarget, gSohVRHopKind, gSohVRRollActive, sohvr_roll_seconds(), sohvr_flipCam,
                         sohvr_flipAngle * (180.0f / (float)M_PI), sohvr_flipKind,
                         sohvr_flipForce, sohvr_eyeFwd[0].x, sohvr_eyeFwd[0].y, sohvr_eyeFwd[0].z,
                         (unsigned long long)sohvr_flips, (unsigned long long)sohvr_rolls,
                         gSohVRAuthoredSuppressed, gSohVRStabTicks, gSohVRStabs, gSohVRStabQuads,
                         gSohVRMotionCovered, gSohVRVanillaQuadsSkipped, gSohVRCoverDrops,
                         gSohVRChopTicks, gSohVRChops, sohvr_atkKind, sohvr_atkT, sohvr_atkReach,
                         sohvr_atkAngle, sohvr_atkAxDot, sohvr_atkHamDot, sohvr_atkSwLimbDot,
                         sohvr_atkPeakTravel, sohvr_atkPeakDot,
                         sohvr_atkBladeShift, sohvr_atkPeakUpDeg, sohvr_atkStartUpDeg, sohvr_atkBestFwdDeg,
                         sohvr_atkBestFwdU, sohvr_atkDrop,
                         sohvr_slashArcDeg, sohvr_slashDownDeg, sohvr_slashReachM, sohvr_slashSecs,
                         sohvr_slashDropM, sohvr_slashHoldSecs, sohvr_slashBackSecs,
                         sohvr_jumpArcDeg, sohvr_jumpSecs, sohvr_jumpReachM,
                         sohvr_atk_duration(sohvr_atkKind != 0 ? sohvr_atkKind : 1),
                         gSohVRHammers, gSohVRHammerHits, (unsigned long long)sohvr_hammerEnvelopes,
                         sohvr_hammerArcDeg, sohvr_hammerDownDeg, sohvr_hammerReachM, sohvr_hammerDropM,
                         sohvr_hammerSecs, sohvr_hammerHoldSecs, sohvr_hammerBackSecs, gSohVRHammerProbe,
                         gSohVRShieldStops, gSohVRSwingSfx, gSohVRJumpSlashVanilla, gSohVRChopYells,
                         gSohVRMeleeAnim,
                         gSohVRLinkVel, gSohVRLinkPos[0], gSohVRLinkPos[1], gSohVRLinkPos[2],
                         gSohVROcarinaOut, gSohVROcarinaForce,
                         (unsigned long long)sohvr_stabEnvelopes,
                         (unsigned long long)sohvr_chopEnvelopes, (unsigned long long)sohvr_atkDropped,
                         gSohVRCrouch, sohvr_crouchNow, sohvr_crouchFrac, sohvr_crouch_drop(),
                         (unsigned long long)sohvr_crouches,
                         gSohVRGripChord, gSohVRHudPlane, gSohVROverlayDL != NULL, gSohVRHudFrames, gSohVRHudDLRaces,
                         (unsigned long long)sohvr_hudPresents, sohvr_hudTag, sohvr_pairTag, gSohVRHudW,
                         gSohVRHudH, sohvr_hudDist, sohvr_hudWidth, sohvr_hudUp, sohvr_hudKeyGain,
                         sohvr_scale, sohvr_height, gSohVRHeadHeightOffset,
                         (unsigned long long)sohvr_heightCals, sohvr_heightCalReq,
                         (unsigned long long)sohvr_heightCalDeferred,
                         sohvr_ladderFollow, sohvr_ladderLastDelta, gSohVRBodyYawSnapSeq,
                         (unsigned long long)sohvr_ladderFollows,
                         gSohVRBoomDirect, (unsigned)gSohVRBoomDirectThrows,
                         sohvr_flatWorldBackdrop,
                         (unsigned long long)(++sohvr_dumpSeq)];
}

// The depth-contract assertion (spec D2 / D-044). The blit converts
// Fast3D's forward-Z NDC into the compositor's reverse-Z / infinite-far NDC;
// this walks the SAME arithmetic the shader runs, at known distances, and
// checks the round trip lands where reverse-Z says it should (z = near/d).
static NSString* sohvr_dump_depth(void) {
    const float n = sohvr_near, f = sohvr_far, scale = sohvr_scale;
    const float nearM = sohvr_depthNearM;
    // Sample at 1 m, 10 m and 1000 m from the eye, expressed in game units.
    const float dm[3] = { 1.0f, 10.0f, 1000.0f };
    NSMutableString* s = [NSMutableString
        stringWithFormat:@"ok vr_depth valid=%d engine=forwardZ_clear1.0_less near_units=%.1f far_units=%.1f "
                          "scale=%.2f cp_kind=%s cp_near_m=%.4f cp_far_m=%.1f",
                         sohvr_depthValid, n, f, scale,
                         sohvr_contract.depthKind[0] == 2 ? "reverseZ_infinite_far"
                                                          : (sohvr_contract.depthKind[0] == 1 ? "reverseZ_finite"
                                                                                              : "forwardZ"),
                         nearM, sohvr_contract.depthFar[0]];
    BOOL pass = (sohvr_depthValid != 0);
    for (int i = 0; i < 3; i++) {
        float d = dm[i] * scale; // game units
        // What the ENGINE writes at that distance (forward-Z, our own P).
        float zf = (f * (n - d)) / ((n - f) * d);
        // What the BLIT then hands the compositor (the shader's arithmetic).
        float den = zf * (n - f) + f;
        float dBack = (fabsf(den) > 1e-6f) ? (f * n / den) : f;
        float zr = (nearM * scale) / (dBack > 1e-3f ? dBack : 1e-3f);
        zr = zr < 0.0f ? 0.0f : (zr > 1.0f ? 1.0f : zr);
        float want = nearM / dm[i]; // reverse-Z, far at infinity: z = near/dist
        float err = fabsf(zr - want);
        if (d > n && d < f && err > 0.002f) {
            pass = NO;
        }
        [s appendFormat:@" d%dm=%.1f zfwd=%.6f d_recovered=%.2f zrev=%.6f expect=%.6f err=%.6f", (int)dm[i], d, zf,
                        dBack, zr, want, err];
    }
    [s appendFormat:@" depth_check=%s seq=%llu", pass ? "PASS" : "FAIL", (unsigned long long)(++sohvr_dumpSeq)];
    return s;
}

// --- R2a: `vr selftest` — the eye-math suite, no immersive loop required -----
//
// The sibling's first device round found its per-eye projection rebuild broken
// under ASYMMETRIC tangents and invisible in every simulator round before it,
// because the simulator's tangents are symmetric and the off-centre term
// (tR+tL) is therefore exactly zero (VR-R6-DEVICE-EVIDENCE §1). This suite
// uses the REAL DEVICE TANGENTS as a fixture so the asymmetric case is
// exercised on any machine, and it runs from the flat 2D window — no headset
// on a head, no immersive space, no compositor.
//
//   eye0_tan = -1.7321, 1.0000, -1.1918, 1.0000
//   eye1_tan = -1.0000, 1.7321, -1.1918, 1.0000
//
// Note tR-tL = 2.7321 and tT-tB = 2.1918 for BOTH eyes: the two frustums are
// mirror images, so the SCALE terms must be identical and only the skew terms
// may differ. That is the invariant the sibling's bug violated.
static NSString* sohvr_dump_selftest(void) {
    const float tanL[2] = { -1.7321f, -1.0000f };
    const float tanR[2] = { 1.0000f, 1.7321f };
    const float tanB[2] = { -1.1918f, -1.1918f };
    const float tanT[2] = { 1.0000f, 1.0000f };
    // The dump's per-eye quadruple is (L, R, B, T). The horizontal pair is
    // mirrored (60 deg outward / 45 deg inward) and the VERTICAL pair is
    // identical, so tR-tL = 2.7321 and tT-tB = 2.1918 for both eyes.
    const float n = sohvr_near, f = sohvr_far;
    NSMutableString* s = [NSMutableString stringWithString:@"ok vr_selftest"];
    int pass = 1;
#define SOHVR_CHK(nameLit, cond)                                                                                   \
    do {                                                                                                           \
        int sohOk = (cond) ? 1 : 0;                                                                                \
        if (!sohOk) {                                                                                              \
            pass = 0;                                                                                              \
        }                                                                                                          \
        [s appendFormat:@"\n  %-28s %s", nameLit, sohOk ? "PASS" : "FAIL"];                                        \
    } while (0)

    // --- 1. tangent recovery round-trips exactly -----------------------------
    // Build the compositor's own matrix shape from the tangents, then run the
    // loop's recovery (SohImmersive.m's tangent block) back over it.
    float rtErr = 0.0f;
    for (int e = 0; e < 2; e++) {
        float w = tanR[e] - tanL[e], h = tanT[e] - tanB[e];
        simd_float4x4 pc;
        memset(&pc, 0, sizeof(pc));
        pc.columns[0][0] = 2.0f / w;
        pc.columns[1][1] = 2.0f / h;
        pc.columns[2][0] = (tanR[e] + tanL[e]) / w;
        pc.columns[2][1] = (tanT[e] + tanB[e]) / h;
        pc.columns[2][2] = 0.0f; // reverse-Z, infinite far (what the device reports)
        pc.columns[2][3] = -1.0f;
        pc.columns[3][2] = 0.1f;
        float rR = (pc.columns[2][0] + 1.0f) / pc.columns[0][0];
        float rL = (pc.columns[2][0] - 1.0f) / pc.columns[0][0];
        float rT = (pc.columns[2][1] + 1.0f) / pc.columns[1][1];
        float rB = (pc.columns[2][1] - 1.0f) / pc.columns[1][1];
        rtErr = fmaxf(rtErr, fmaxf(fabsf(rR - tanR[e]), fmaxf(fabsf(rL - tanL[e]),
                                                              fmaxf(fabsf(rT - tanT[e]), fabsf(rB - tanB[e])))));
        int kind = 0;
        float kn = 0, kf = 0;
        sohvr_classify_depth(pc, &kind, &kn, &kf);
        if (e == 0) {
            SOHVR_CHK("depth_kind_revZ_inf", kind == 2 && fabsf(kn - 0.1f) < 1e-4f && isinf(kf));
        }
    }
    SOHVR_CHK("tangent_roundtrip", rtErr < 1e-3f);

    // --- 2. the scale terms are EQUAL across the eyes ------------------------
    // This is the sibling's rainbow bug, stated as an invariant: (tR-tL) and
    // (tT-tB) match between the eyes, so P00 and P11 MUST match too, and the
    // off-centre term must land ONLY in the skew slots.
    simd_float4x4 P[2];
    for (int e = 0; e < 2; e++) {
        P[e] = sohvr_projection(tanL[e], tanR[e], tanB[e], tanT[e], n, f);
    }
    float p00d = fabsf(P[0].columns[0][0] - P[1].columns[0][0]);
    float p11d = fabsf(P[0].columns[1][1] - P[1].columns[1][1]);
    SOHVR_CHK("P00_equal_across_eyes", p00d < 1e-5f);
    SOHVR_CHK("P11_equal_across_eyes", p11d < 1e-5f);
    // The off-centre terms are non-zero (otherwise the fixture is not testing
    // anything) and OPPOSITE in sign between the mirrored eyes.
    float c20L = P[0].columns[2][0], c20R = P[1].columns[2][0];
    SOHVR_CHK("offcentre_nonzero", fabsf(c20L) > 0.01f && fabsf(c20R) > 0.01f);
    SOHVR_CHK("offcentre_mirrored", fabsf(c20L + c20R) < 1e-4f);
    // ...and it must live in the z-row skew slots ONLY: nothing else in the
    // matrix may differ between the eyes.
    int strayDiff = 0;
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            if (c == 2 && (r == 0 || r == 1)) {
                continue; // the legitimate skew slots
            }
            if (fabsf(P[0].columns[c][r] - P[1].columns[c][r]) > 1e-5f) {
                strayDiff++;
            }
        }
    }
    SOHVR_CHK("skew_only_difference", strayDiff == 0);

    // --- 3. a point at +X in eye space lands on the right NDC side -----------
    // Non-tautological: the ground truth is a POSITION (1 m right, 3 m ahead),
    // not an angle, and the expectation is a sign, not a matrix element.
    int sideOk = 1;
    for (int e = 0; e < 2; e++) {
        simd_float4 vRight = simd_make_float4(1.0f, 0.0f, -3.0f, 1.0f);
        simd_float4 vLeft = simd_make_float4(-1.0f, 0.0f, -3.0f, 1.0f);
        simd_float4 cr = simd_mul(P[e], vRight), cl = simd_mul(P[e], vLeft);
        // Relative to the EYE'S OWN axis, which an asymmetric frustum puts at
        // NDC -c20, not at 0. A host model of this suite caught the naive
        // version: eye 0's axis sits at +0.268, so a point 1 m to the LEFT at
        // 3 m still lands at +0.024 and "xl < 0" fails on a perfectly correct
        // matrix. The frustum's asymmetry is the thing under test; it must not
        // also be baked into the expectation.
        float pp = -P[e].columns[2][0];
        float xr = cr.x / cr.w - pp, xl = cl.x / cl.w - pp;
        if (!(xr > 0.0f && xl < 0.0f && xr > xl)) {
            sideOk = 0;
        }
    }
    SOHVR_CHK("ndc_side_of_axis", sideOk);

    // --- 4. the composed row-vector eye matrices differ by the eye offset ----
    // Two eyes at +/- 31.5 mm along eye-space X, same orientation, same P.
    // The composed A.V.P pair must differ by exactly the clip-x translation
    // that offset produces at a known depth — and the DIFFERENCE must be
    // horizontal only (a vertical component is the classic fusion killer).
    float rows[2][16];
    simd_float4x4 pose[2];
    for (int e = 0; e < 2; e++) {
        pose[e] = matrix_identity_float4x4;
        pose[e].columns[3] =
            simd_make_float4((e == 0 ? -kSohVRHalfIpd : kSohVRHalfIpd) * sohvr_scale, 0.0f, 0.0f, 1.0f);
        sohvr_compose_eye(pose[e], P[e], rows[e]);
    }
    // Project one GAME-space point (10 m ahead of the origin, in game units)
    // through both composed matrices, row-vector order, exactly as the
    // interpreter does.
    float px = 0.0f, py = 0.0f, pz = -10.0f * sohvr_scale;
    float cx[2], cy[2], cw[2];
    for (int e = 0; e < 2; e++) {
        const float* m = rows[e];
        cx[e] = px * m[0] + py * m[4] + pz * m[8] + m[12];
        cy[e] = px * m[1] + py * m[5] + pz * m[9] + m[13];
        cw[e] = px * m[3] + py * m[7] + pz * m[11] + m[15];
    }
    float ndx0 = cx[0] / cw[0], ndx1 = cx[1] / cw[1];
    float ndy0 = cy[0] / cw[0], ndy1 = cy[1] / cw[1];
    // A point straight ahead appears to the RIGHT of centre in the left eye and
    // to the LEFT of centre in the right eye, relative to each eye's own axis.
    // With the mirrored frustums above, "each eye's own axis" is NOT at NDC 0:
    // clip.x = P00*x + c20*z and clip.w = -z, so ndc.x = P00*x/d - c20 and the
    // principal point (x = 0) sits at -c20. Subtracting the WRONG sign here
    // would make the assert read the disparity backwards, which is exactly the
    // class of tautology trap D11 warns about.
    float ppx0 = -P[0].columns[2][0], ppx1 = -P[1].columns[2][0];
    SOHVR_CHK("disparity_sign", (ndx0 - ppx0) > (ndx1 - ppx1));
    SOHVR_CHK("no_vertical_disparity", fabsf(ndy0 - ndy1) < 1e-4f);
    // ...and its magnitude is the IPD at that depth, to within a percent.
    float wantDisp = (2.0f * kSohVRHalfIpd * sohvr_scale) * P[0].columns[0][0] / (10.0f * sohvr_scale);
    float gotDisp = (ndx0 - ppx0) - (ndx1 - ppx1);
    SOHVR_CHK("disparity_magnitude", fabsf(gotDisp - wantDisp) < fabsf(wantDisp) * 0.01f + 1e-5f);

    // --- 5. the depth conversion, at the fixture's own near plane ------------
    const float nearM = 0.1f, scale = sohvr_scale;
    float derr = 0.0f;
    for (int i = 0; i < 3; i++) {
        float dm[3] = { 1.0f, 10.0f, 1000.0f };
        float d = dm[i] * scale;
        float zf = (f * (n - d)) / ((n - f) * d);
        float den = zf * (n - f) + f;
        float dBack = (fabsf(den) > 1e-6f) ? (f * n / den) : f;
        float zr = (nearM * scale) / (dBack > 1e-3f ? dBack : 1e-3f);
        float want = nearM / dm[i];
        if (d > n && d < f) {
            derr = fmaxf(derr, fabsf(zr - want));
        }
    }
    SOHVR_CHK("depth_conversion", derr < 0.002f);
#undef SOHVR_CHK

    [s appendFormat:@"\n  result=%s tan_rt_err=%.6f p00=%.6f/%.6f p11=%.6f/%.6f c20=%.6f/%.6f "
                     @"disp_ndc=%.6f want=%.6f depth_err=%.6f scale=%.2f near=%.1f far=%.1f seq=%llu",
                    pass ? "PASS" : "FAIL", rtErr, P[0].columns[0][0], P[1].columns[0][0], P[0].columns[1][1],
                    P[1].columns[1][1], c20L, c20R, gotDisp, wantDisp, derr, sohvr_scale, sohvr_near, sohvr_far,
                    (unsigned long long)(++sohvr_dumpSeq)];
    return s;
}

NSString* SohVR_HandleCommand(NSArray<NSString*>* args) {
    NSString* sub = args.count >= 1 ? args[0].lowercaseString : @"";
    if (sub.length == 0) {
        return [@[ sohvr_dump_mode(), sohvr_dump_pose(), sohvr_dump_contract(), sohvr_dump_depth(),
                   sohvr_dump_pace(), sohvr_dump_room(), sohvr_dump_selftest() ] componentsJoinedByString:@"\n"];
    }
    if ([sub isEqualToString:@"depth"]) {
        return sohvr_dump_depth();
    }
    if ([sub isEqualToString:@"selftest"]) {
        // Deliberately runnable WITHOUT the immersive loop: the headset has to
        // be worn for a VR session, so an eye-math regression must be catchable
        // from the flat 2D window over the bridge.
        return sohvr_dump_selftest();
    }
    if ([sub isEqualToString:@"recenter"] || [sub isEqualToString:@"recalibrate"]) {
        // R8 item 5: one path. A recenter IS a height calibration -- it re-seats
        // the room origin on the live head, which is exactly what puts the
        // wearer's eyes at Link's eye height -- so the settings sheet's
        // "Re-calibrate VR height" button and this command are the same code.
        SohVR_RecalibrateHeight();
        usleep(120 * 1000); // serviced on the loop thread, on the first REAL pose
        return [NSString
            stringWithFormat:@"ok vr %@ recenters=%llu height_cals=%llu pending=%d deferred=%llu trim=%+.2fm "
                             @"(nothing captured into steering)",
                             sub, (unsigned long long)sohvr_recenters, (unsigned long long)sohvr_heightCals,
                             sohvr_heightCalReq, (unsigned long long)sohvr_heightCalDeferred, sohvr_height];
    }
    if ([sub isEqualToString:@"pose"]) {
        return sohvr_dump_pose();
    }
    if ([sub isEqualToString:@"mode"]) {
        return sohvr_dump_mode();
    }
    if ([sub isEqualToString:@"contract"]) {
        return sohvr_dump_contract();
    }
    if ([sub isEqualToString:@"audio"]) {
        // R17 part B (g): THE MANUAL DOOR. The watchdog is now conservative on
        // purpose -- two windows, an unchanged failure counter, no action inside
        // an immersive transition -- so there has to be a way to ask for the two
        // things it does, by hand, from the console. `reopen` goes through the
        // ONE-WRITER request path (never the direct close, which is the watchdog's
        // own privilege and only while the audio thread is provably not turning);
        // `prepare` re-activates the AVAudioSession without touching the device.
        if (args.count >= 2) {
            NSString* sohAudioVerb = args[1].lowercaseString;
            extern volatile int gSohAudioReopenReq;
            extern volatile unsigned long long gSohAudioReopens;
            extern void SohIos_AudioNote(const char* what);
            extern int SohIos_AudioPrepareSession(void);
            if ([sohAudioVerb isEqualToString:@"reopen"]) {
                unsigned long long before = gSohAudioReopens;
                gSohAudioReopenReq = 1;
                SohIos_AudioNote("console asked for a reopen (request path)");
                // The audio thread services it at the top of its next tick
                // (~5 ms), but a thread that is not turning never will -- so
                // this reports what happened rather than claiming success.
                for (int i = 0; i < 100 && gSohAudioReopens == before; i++) {
                    usleep(20 * 1000);
                }
                return [NSString stringWithFormat:@"ok vr_audio_reopen serviced=%d reopens=%llu req=%d",
                                                  (int)(gSohAudioReopens != before),
                                                  (unsigned long long)gSohAudioReopens, gSohAudioReopenReq];
            }
            if ([sohAudioVerb isEqualToString:@"prepare"]) {
                int ok = SohIos_AudioPrepareSession();
                SohIos_AudioNote("console asked for a session prepare");
                return [NSString stringWithFormat:@"ok vr_audio_prepare active=%d", ok];
            }
        }
        // R3 (overlay 0044): audio liveness, in one line. `beats` climbing
        // proves the audio thread is alive; `buffered` pinned at or above
        // `desired` with `skipped` climbing and `produced` flat is the
        // stopped-draining device that made 1.0.1.3 silent.
        extern volatile unsigned long long gSohAudioBeats, gSohAudioProduced, gSohAudioSkipped;
        extern volatile unsigned long long gSohAudioQueueFails, gSohAudioQueueBytes, gSohAudioRecoveries;
        extern volatile int gSohAudioBuffered, gSohAudioDesired;
        extern volatile int gSohAudioAnchorStatus;
        // R14: the launch watchdog's own state. `dev=0` is the silent launch
        // outright; `restarts` climbing says the watchdog saw it and acted.
        extern volatile int gSohAudioDeviceId, gSohAudioBackend, gSohAudioReopenReq;
        extern volatile int gSohAudioWatchdogRestarts, gSohAudioWatchdogState;
        extern volatile unsigned long long gSohAudioOpenTries, gSohAudioOpenFails, gSohAudioReopens;
        extern volatile unsigned long long gSohAudioThreadFaults, gSohAudioSessionFails;
        extern volatile int gSohAudioSaturations, gSohAudioWatchdogSkips, gSohVRTransition;
        static const char* const kSohWdState[4] = { "waiting", "healthy", "unhealthy", "gave-up" };
        AVAudioSession* sohSess = AVAudioSession.sharedInstance;
        NSString* sohRoute = sohSess.currentRoute.outputs.firstObject.portType ?: @"none";
        NSMutableString* sohAudioLine = [NSMutableString
            stringWithFormat:@"ok vr_audio beats=%llu produced=%llu skipped=%llu queue_fails=%llu "
                              "queue_bytes=%llu recoveries=%llu buffered=%d desired=%d "
                              "anchor_status=%d category=%@ mode=%@ out_vol=%.2f route=%@ other_playing=%d "
                              "vr_mode=%d seq=%llu",
                             gSohAudioBeats, gSohAudioProduced, gSohAudioSkipped, gSohAudioQueueFails,
                             gSohAudioQueueBytes, gSohAudioRecoveries, gSohAudioBuffered, gSohAudioDesired,
                             gSohAudioAnchorStatus, sohSess.category, sohSess.mode, sohSess.outputVolume,
                             sohRoute, (int)sohSess.isOtherAudioPlaying, gSohVRMode,
                             (unsigned long long)(++sohvr_dumpSeq)];
        [sohAudioLine appendFormat:@" dev=%d backend=%d open_tries=%llu open_fails=%llu reopens=%llu "
                                    "reopen_req=%d wd_restarts=%d wd_state=%s thread_faults=%llu session_fails=%llu",
                                   gSohAudioDeviceId, gSohAudioBackend, gSohAudioOpenTries, gSohAudioOpenFails,
                                   gSohAudioReopens, gSohAudioReopenReq, gSohAudioWatchdogRestarts,
                                   kSohWdState[(gSohAudioWatchdogState >= 0 && gSohAudioWatchdogState < 4)
                                                   ? gSohAudioWatchdogState
                                                   : 0],
                                   gSohAudioThreadFaults, gSohAudioSessionFails];
        [sohAudioLine appendFormat:@" saturations=%d wd_skips=%d transition=%d", (int)gSohAudioSaturations,
                                   (int)gSohAudioWatchdogSkips, gSohVRTransition];
        return sohAudioLine;
    }
    if ([sub isEqualToString:@"pace"]) {
        return sohvr_dump_pace();
    }
    if ([sub isEqualToString:@"mem"]) {
        // R8 part C: the same fields the 5 s heartbeat writes into vr-mem.log,
        // on demand and in the same format, because a second format would drift
        // from the first. `vr mem trim` fires the governor by hand -- the A/B
        // that turns "the resource cache is the leak" into a number you can
        // watch fall in one command.
        extern int SohIos_MemFields(char* buf, size_t cap);
        extern long SohIos_AvailableMemoryMB(void);
        extern void SohIos_RequestMemoryTrim(const char* why);
        extern volatile int gSohIosMemTrims;
        extern volatile int gSohVRSceneNum;
        if (args.count >= 2 && [args[1].lowercaseString isEqualToString:@"trim"]) {
            int before = gSohIosMemTrims;
            SohIos_RequestMemoryTrim("console");
            // Serviced at the top of the next GAME frame, never here: this is
            // the bridge thread, and only the game thread may free a resource.
            for (int i = 0; i < 120 && gSohIosMemTrims == before; i++) {
                usleep(25 * 1000);
            }
        }
        char sohMem[512];
        SohIos_MemFields(sohMem, sizeof(sohMem));
        return [NSString stringWithFormat:@"ok vr_mem mode=%d scene=%d avail_mem_mb=%ld %s seq=%llu",
                                          gSohVRMode, (int)gSohVRSceneNum, SohIos_AvailableMemoryMB(), sohMem,
                                          (unsigned long long)(++sohvr_dumpSeq)];
    }
    // R9 part A: open the settings sheet without a tap. The visionOS simulator
    // has no scripted touch, so this is the only way the sheet's LAYOUT gets
    // looked at before a human wears it -- and "compiled but never seen" is
    // exactly how R8's tabs shipped.
    if ([sub isEqualToString:@"settings"]) {
        extern void SohVR_ShowSettings(int on); // SohVisionApp.swift (@_cdecl)
        // R10 verdict 6: 2 means "open it AND scroll to the 3D/VR boundary",
        // which is where the overlap he reported lives and which is 900 points
        // down a page nothing in a simulator can drag.
        // 3 scrolls to the temporary left-hand calibration section instead.
        int on = (args.count >= 2) ? args[1].intValue : 1;
        if (on < 0 || on > 3) {
            on = (on != 0);
        }
        SohVR_ShowSettings(on);
        return [NSString stringWithFormat:@"ok vr settings sheet=%d vr_active=%d", on, SohVR_IsActive()];
    }
    if ([sub isEqualToString:@"room"] || [sub isEqualToString:@"fp"] || [sub isEqualToString:@"hud"]) {
        return sohvr_dump_room();
    }
    if ([sub isEqualToString:@"on"] || [sub isEqualToString:@"off"]) {
        BOOL on = [sub isEqualToString:@"on"];
        // R0 review finding: `vr off` used to call the shared 3D exit
        // unconditionally, so it tore down the 3D PANEL too. spec D1's
        // tri-state is the authority — `vr off` only ever leaves VR.
        int mode = Soh_GetMode();
        if (on && mode == 1) {
            return @"err already in the 3D panel — `3d off` first (D1: 3D<->VR is dismiss-then-open)";
        }
        if (on && mode == 2) {
            return @"ok vr already on";
        }
        if (!on && mode != 2) {
            return [NSString stringWithFormat:@"ok vr already off (mode=%s — not touched)",
                                              mode == 1 ? "panel3D" : "flat"];
        }
        Soh_EnterVR(on);
        return [NSString stringWithFormat:@"ok vr %@ requested (space=%d)", sub, sohvr_variant];
    }
    if ([sub isEqualToString:@"space"] && args.count >= 2) {
        NSString* w = args[1].uppercaseString;
        sohvr_variant = [w isEqualToString:@"A"] ? 1 : ([w isEqualToString:@"B"] ? 2 : 0);
        return [NSString stringWithFormat:@"ok vr space=%d (takes effect on the next `vr on`)", sohvr_variant];
    }
    if ([sub isEqualToString:@"style"]) {
        // R7 verdict 1: kept as a REPORTING no-op. VR is full immersion with the
        // wearer's limbs hidden and there is no longer anything to choose.
        sohvr_styleFull = 1;
        extern void SohVR_PushStyle(int full); // SohVisionApp.swift (@_cdecl)
        SohVR_PushStyle(1);
        return @"ok vr style=full limbs=hidden (R7 verdict 1: not a setting any more)";
    }
    if ([sub isEqualToString:@"world"] && args.count >= 2) {
        sohvr_worldMode = [args[1].lowercaseString isEqualToString:@"on"] ? 1 : 0;
        return [NSString stringWithFormat:@"ok vr world=%d", sohvr_worldMode];
    }
    if ([sub isEqualToString:@"inject"]) {
        if (args.count >= 2 && [args[1].lowercaseString isEqualToString:@"off"]) {
            sohvr_injectOn = 0;
            usleep(40 * 1000); // let the loop recompose before the dump is read
            return sohvr_dump_pose();
        }
        if (args.count >= 6) {
            sohvr_injectPos[0] = args[1].floatValue;
            sohvr_injectPos[1] = args[2].floatValue;
            sohvr_injectPos[2] = args[3].floatValue;
            sohvr_injectYawDeg = args[4].floatValue;
            sohvr_injectPitchDeg = args[5].floatValue;
            sohvr_injectOn = 1;
            // Give the loop a frame to recompose before the dump is read.
            usleep(40 * 1000);
            return sohvr_dump_pose();
        }
        return @"err usage: vr inject X Y Z YAW PITCH | vr inject off";
    }
    // --- R4: hands, the swing detector, and the scripted trajectory ----------
    if ([sub isEqualToString:@"sky"]) {
        // R7 verdict 8: the skybox matrix, so the invariant can be ASSERTED
        // rather than eyeballed. Inject two head positions with the SAME
        // rotation and this matrix must not move; inject two rotations and it
        // must. That is the whole claim -- the sky follows where you look and
        // ignores where you stand -- and it is one diff of two lines.
        if (!gSohVRRunning) {
            return @"err vr sky needs the VR loop running (`vr on`)";
        }
        int sl = gSohVRPairSlot & 1;
        NSMutableString* r = [NSMutableString stringWithFormat:@"ok vr_sky slot=%d sky=", sl];
        for (int i = 0; i < 16; i++) {
            [r appendFormat:@"%s%.4f", i ? "," : "", gSohVRSkyVP[sl][0][i]];
        }
        [r appendString:@" eye="];
        for (int i = 0; i < 16; i++) {
            [r appendFormat:@"%s%.4f", i ? "," : "", gSohVREyeVP[sl][0][i]];
        }
        [r appendFormat:@" cam_eye=%.1f,%.1f,%.1f sky_seat=%.2f,%.2f,%.2f eye_seat=%.2f,%.2f,%.2f",
                        gSoh3DCamEye[0], gSoh3DCamEye[1], gSoh3DCamEye[2], sohvr_skySeat.x, sohvr_skySeat.y,
                        sohvr_skySeat.z, sohvr_eyeGame[0].x, sohvr_eyeGame[0].y, sohvr_eyeGame[0].z];
        // R11 verdict 1: THE TRANSLATION 0031 DROPPED, and the proof that
        // dropping it is what makes the sky still. `sky_mdrop` is the game's own
        // skybox model translation for the last drawn frame -- `play->view.eye`
        // as Fast3D interpolated it, which is the quantity every previous round
        // tried to chase with a seat. `sky_ndc` is a canonical +X sphere vertex
        // (126 units, the sphere's own radius) pushed through the FINAL composed
        // MVP the hardware received. Under any head translation and under Link
        // running, sky_mdrop moves and sky_ndc must not: that is the assertion,
        // and it reads the shipped path rather than a copy of it.
        {
            const float kR = 126.0f;
            const float v[4] = { kR, 0.0f, 0.0f, 1.0f };
            float clip[4] = { 0, 0, 0, 0 };
            for (int j = 0; j < 4; j++) {
                float acc = 0.0f;
                for (int i = 0; i < 4; i++) {
                    acc += v[i] * gSohVRSkyMP[i * 4 + j]; // row-vector, Fast3D order
                }
                clip[j] = acc;
            }
            float w = (fabsf(clip[3]) > 1e-9f) ? clip[3] : 1e-9f;
            [r appendFormat:@" sky_mdrop=%.2f,%.2f,%.2f sky_drops=%u sky_ndc=%.5f,%.5f,%.5f",
                            gSohVRSkyMDrop[0], gSohVRSkyMDrop[1], gSohVRSkyMDrop[2], gSohVRSkyDrops,
                            clip[0] / w, clip[1] / w, clip[2] / w];
            // THE ASSERTION ITSELF is this row, not the NDC above. In row-vector
            // order the last row of a composed MVP is the ONLY place a
            // translation can land: M's translation row times VP. With M's row
            // zeroed by 0031 and the sky view's translation zeroed by the shell,
            // it is exactly the projection's own last row -- (0, 0, near, 0) for
            // this frustum -- so sky_mp_t x, y and w are EXACT ZEROS on a
            // correct build and nothing else can make them so.
            //
            // The NDC above is a REPORT rather than an assertion because the
            // skybox's own 3x3 (skyboxCtx->rot) is animated by the game, so a
            // fixed vertex's screen position legitimately drifts even when no
            // translation reaches it. Asserting on it would be asserting that
            // OoT's sky does not turn.
            [r appendFormat:@" sky_mp_t=%.6f,%.6f,%.6f,%.6f eye_mp_t=%.6f,%.6f,%.6f,%.6f",
                            gSohVRSkyMP[12], gSohVRSkyMP[13], gSohVRSkyMP[14], gSohVRSkyMP[15],
                            gSohVREyeVP[sl][0][12], gSohVREyeVP[sl][0][13], gSohVREyeVP[sl][0][14],
                            gSohVREyeVP[sl][0][15]];
        }
        [r appendFormat:@" seq=%llu", (unsigned long long)(++sohvr_dumpSeq)];
        return r;
    }
    // R11 verdict 2: the whole per-configuration calibration TABLE, read out of
    // the shell's own constants through the accessor the settings sheet uses
    // for its defaults. Four rows of six: rh_l rh_r lh_l lh_r, each
    // x,y,z(cm),yaw,pitch,roll(deg) in STORED convention (z is the negation of
    // the slider's "Forward"). The suite asserts the left-handed rows are the
    // mirror conjugates of the right-handed ones, so a hand-edit of one row
    // without the other fails here rather than in a headset.
    // R12 item 4: THE HELD-ITEM CORRECTION, read and written.
    //
    //   vr itemcal                       -- the whole table plus what is in
    //                                       each hand right now
    //   vr itemcal <name|index> y p r [x y z]
    //                                    -- set one row of the CURRENT
    //                                       configuration (degrees, then game
    //                                       units)
    //
    // Deliberately one row per command rather than one key per number: the user
    // dials these from a headset and reports them, and a row is what he reads.
    // R12 item 6 (Q-VR26): put a sword back on the B button. TEST ONLY -- the
    // game side clears the flag the tick it acts on it and it ships 0.
    if ([sub isEqualToString:@"forcesword"]) {
        gSohVRForceSword = 1;
        return [NSString stringWithFormat:@"ok vr_forcesword pending=1 done=%d seq=%llu", gSohVRForcedSwords,
                                          (unsigned long long)(++sohvr_dumpSeq)];
    }
    if ([sub isEqualToString:@"itemcal"]) {
        int cfg = (gSohVRLeftHanded != 0) ? 1 : 0;
        if (args.count >= 5) {
            NSString* which = args[1].lowercaseString;
            int model = -1;
            for (int m = 0; m < SOHVR_ITEMCAL_N; m++) {
                if ([which isEqualToString:[NSString stringWithUTF8String:SohVR_ItemCalName(m)]]) {
                    model = m;
                    break;
                }
            }
            if (model < 0) {
                int idx = which.intValue;
                if (idx > 0 || [which isEqualToString:@"0"]) {
                    model = idx;
                }
            }
            if (model < 0 || model >= SOHVR_ITEMCAL_N) {
                return [NSString stringWithFormat:@"err vr_itemcal unknown_model=%@", args[1]];
            }
            for (int i = 0; i < 6; i++) {
                if ((int)args.count > 2 + i) {
                    SohVR_SetItemCal(cfg, model, i, args[2 + i].floatValue);
                }
            }
        }
        NSMutableString* r = [NSMutableString stringWithFormat:@"ok vr_itemcal cfg=%d on=%d held=%s,%s", cfg,
                                                              gSohVRItemCal, SohVR_ItemCalName(gSohVRHeldModel[0]),
                                                              SohVR_ItemCalName(gSohVRHeldModel[1])];
        [r appendFormat:@" held_idx=%d,%d", gSohVRHeldModel[0], gSohVRHeldModel[1]];
        for (int m = 0; m < SOHVR_ITEMCAL_N; m++) {
            [r appendFormat:@" %s=%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", SohVR_ItemCalName(m),
                            gSohVRItemRotDeg[m][cfg][0], gSohVRItemRotDeg[m][cfg][1], gSohVRItemRotDeg[m][cfg][2],
                            gSohVRItemOffU[m][cfg][0], gSohVRItemOffU[m][cfg][1], gSohVRItemOffU[m][cfg][2]];
        }
        [r appendFormat:@" seq=%llu", (unsigned long long)(++sohvr_dumpSeq)];
        return r;
    }
    // R13 (Q-VR28): THE AIM, MADE VISIBLE. the user asked for the nut to go where
    // he points; a direction with no readout is a guess with extra steps, and
    // this one prints the direction in force NEXT TO the hand's own forward so
    // the two can be compared by eye. If they disagree, the axis or the frame is
    // wrong and `vr set aimaxis` / `vr set aimframe` fixes it without a rebuild.
    // `dir` and `fwd` are unit vectors in game world space (+Y up); `dot` is
    // their agreement, 1.000 when the shipped axis (1,0,0) is in force and the
    // trims are zero. `hits` counts the times a projectile actually took this
    // path -- a zero there means vanilla's own arithmetic ran, which is the
    // first thing to check before blaming a number.
    if ([sub isEqualToString:@"aim"]) {
        float dot = (gSohVRAimDirW[0] * gSohVRAimFwdW[0]) + (gSohVRAimDirW[1] * gSohVRAimFwdW[1]) +
                    (gSohVRAimDirW[2] * gSohVRAimFwdW[2]);
        float yawDeg = atan2f(gSohVRAimDirW[0], gSohVRAimDirW[2]) * 57.29578f;
        float pitchDeg = atan2f(-gSohVRAimDirW[1], hypotf(gSohVRAimDirW[0], gSohVRAimDirW[2])) * 57.29578f;
        int cfg = (gSohVRLeftHanded != 0) ? 1 : 0;
        NSMutableString* r = [NSMutableString
            stringWithFormat:@"ok vr_aim on=%d frame=%d(%s) cfg=%d valid=%d,%d site=%d hand=%d model=%d(%s) hits=%u",
                             gSohVRAim, gSohVRAimFrame,
                             (gSohVRAimFrame == 2) ? "ray" : (gSohVRAimFrame ? "item" : "hand"), cfg,
                             gSohVRAimValid[0], gSohVRAimValid[1], gSohVRAimSite, gSohVRAimHandUsed, gSohVRAimModel,
                             SohVR_ItemCalName(gSohVRAimModel), gSohVRAimHits];
        // R15: the controller's own aim ray, per hand -- valid, where the
        // runtime got it from (0 = identity, 1 = a real aim location, 3 =
        // injected), the unit direction in game world space and the axis in
        // force in the aim location's frame.
        [r appendFormat:@" ray_valid=%d,%d ray_src=%d,%d ray_axis=%.2f,%.2f,%.2f reticle=%d reticle_range=%.0f",
                        gSohVRAimRayValid[0], gSohVRAimRayValid[1], sohvr_aimRaySrc[0], sohvr_aimRaySrc[1],
                        gSohVRAimRayAxis[0], gSohVRAimRayAxis[1], gSohVRAimRayAxis[2], gSohVRAimReticle,
                        gSohVRAimReticleRange];
        [r appendFormat:@" reticle_scale=%.3f trim_row=%d", gSohVRAimReticleScale, gSohVRAimTrimRow];
        for (int h = 0; h < 2; h++) {
            [r appendFormat:@" ray%d=%.4f,%.4f,%.4f ray%d_yaw=%.1f ray%d_pitch=%.1f", h, gSohVRAimRayDir[h][0],
                            gSohVRAimRayDir[h][1], gSohVRAimRayDir[h][2], h,
                            atan2f(gSohVRAimRayDir[h][0], gSohVRAimRayDir[h][2]) * 57.29578f, h,
                            atan2f(-gSohVRAimRayDir[h][1], hypotf(gSohVRAimRayDir[h][0], gSohVRAimRayDir[h][2])) *
                                57.29578f];
        }
        [r appendFormat:@" dir=%.4f,%.4f,%.4f fwd=%.4f,%.4f,%.4f dot=%.4f yaw_deg=%.1f pitch_deg=%.1f",
                        gSohVRAimDirW[0], gSohVRAimDirW[1], gSohVRAimDirW[2], gSohVRAimFwdW[0], gSohVRAimFwdW[1],
                        gSohVRAimFwdW[2], dot, yawDeg, pitchDeg];
        int trimModel = SohVR_AimTrimModel();
        [r appendFormat:@" pos=%.2f,%.2f,%.2f trim_item=%s trim_yaw=%.2f trim_pitch=%.2f spawn_u=%.2f",
                        gSohVRAimPosW[0], gSohVRAimPosW[1], gSohVRAimPosW[2], SohVR_AimTrimName(trimModel),
                        gSohVRAimTrimDeg[trimModel][cfg][0], gSohVRAimTrimDeg[trimModel][cfg][1], gSohVRAimSpawnU];
        // R14: the two numbers that say whether the hook is running at all,
        // and the hand fix that made the off hand's axis mean anything.
        [r appendFormat:@" path=%d shots_hand=%u shots_vanilla=%u handfix=%d", gSohVRAimPath, gSohVRAimShots,
                        gSohVRAimVanillaShots, gSohVRAimHandFixOn];
        for (int h = 0; h < 2; h++) {
            [r appendFormat:@" fix%d=%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f", h, gSohVRAimHandFix[h][0],
                            gSohVRAimHandFix[h][1], gSohVRAimHandFix[h][2], gSohVRAimHandFix[h][3],
                            gSohVRAimHandFix[h][4], gSohVRAimHandFix[h][5], gSohVRAimHandFix[h][6],
                            gSohVRAimHandFix[h][7], gSohVRAimHandFix[h][8]];
        }
        [r appendFormat:@" held=%s,%s", SohVR_ItemCalName(gSohVRHeldModel[0]), SohVR_ItemCalName(gSohVRHeldModel[1])];
        for (int m = 0; m < SOHVR_ITEMCAL_N; m++) {
            if ((gSohVRAimAxis[m][0] != 1.0f) || (gSohVRAimAxis[m][1] != 0.0f) || (gSohVRAimAxis[m][2] != 0.0f) ||
                (m == gSohVRAimModel)) {
                [r appendFormat:@" axis_%s=%.3f,%.3f,%.3f", SohVR_ItemCalName(m), gSohVRAimAxis[m][0],
                                gSohVRAimAxis[m][1], gSohVRAimAxis[m][2]];
            }
        }
        for (int h = 0; h < 2; h++) {
            [r appendFormat:@" basis%s=%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f", h == 0 ? "L" : "R",
                            gSohVRAimBasis[h][0][0], gSohVRAimBasis[h][0][1], gSohVRAimBasis[h][0][2],
                            gSohVRAimBasis[h][0][3], gSohVRAimBasis[h][0][4], gSohVRAimBasis[h][0][5],
                            gSohVRAimBasis[h][0][6], gSohVRAimBasis[h][0][7], gSohVRAimBasis[h][0][8]];
        }
        [r appendFormat:@" seq=%llu", (unsigned long long)(++sohvr_dumpSeq)];
        return r;
    }
    // R13: one item's forward AXIS, in the frame `aimframe` selects. Three
    // floats, so a sign error in a headset is one command rather than a build.
    // R15: the axis in the AIM location's own frame. -Z is RealityKit's
    // forward and ships; this is the one-command fix if the runtime's aim
    // frame turns out to point along something else.
    if ([sub isEqualToString:@"set"] && args.count >= 5 && [args[1].lowercaseString isEqualToString:@"aimray"]) {
        float ax = [args[2] floatValue], ay = [args[3] floatValue], az = [args[4] floatValue];
        float al = sqrtf((ax * ax) + (ay * ay) + (az * az));
        if (al < 1e-6f) {
            return @"err aimray needs a non-zero vector";
        }
        gSohVRAimRayAxis[0] = ax / al;
        gSohVRAimRayAxis[1] = ay / al;
        gSohVRAimRayAxis[2] = az / al;
        return [NSString stringWithFormat:@"ok aimray=%.3f,%.3f,%.3f", gSohVRAimRayAxis[0], gSohVRAimRayAxis[1],
                                          gSohVRAimRayAxis[2]];
    }
    if ([sub isEqualToString:@"set"] && args.count >= 6 && [args[1].lowercaseString isEqualToString:@"aimaxis"]) {
        NSString* which = args[2].lowercaseString;
        int model = -1;
        for (int m = 0; m < SOHVR_ITEMCAL_N; m++) {
            if ([which isEqualToString:[NSString stringWithUTF8String:SohVR_ItemCalName(m)]]) {
                model = m;
                break;
            }
        }
        if (model < 0) {
            int idx = which.intValue;
            if (idx > 0 || [which isEqualToString:@"0"]) {
                model = idx;
            }
        }
        if (model < 0 || model >= SOHVR_ITEMCAL_N) {
            return [NSString stringWithFormat:@"err vr_set_aimaxis unknown_model=%@", args[2]];
        }
        for (int i = 0; i < 3; i++) {
            gSohVRAimAxis[model][i] = args[3 + i].floatValue;
        }
        return [NSString stringWithFormat:@"ok vr set aimaxis %s=%.3f,%.3f,%.3f seq=%llu", SohVR_ItemCalName(model),
                                          gSohVRAimAxis[model][0], gSohVRAimAxis[model][1], gSohVRAimAxis[model][2],
                                          (unsigned long long)(++sohvr_dumpSeq)];
    }
    if ([sub isEqualToString:@"handcal"]) {
        NSMutableString* r = [NSMutableString stringWithString:@"ok vr_handcal"];
        const char* names[2][2] = { { "rh_l", "rh_r" }, { "lh_l", "lh_r" } };
        for (int c = 0; c < 2; c++) {
            for (int h = 0; h < 2; h++) {
                [r appendFormat:@" %s=", names[c][h]];
                for (int i = 0; i < 6; i++) {
                    [r appendFormat:@"%s%.1f", i ? "," : "", SohVR_HandCalDefault(c, h, i)];
                }
            }
        }
        [r appendFormat:@" lefthanded=%d", gSohVRLeftHanded];
        return r;
    }
    if ([sub isEqualToString:@"hands"]) {
        NSMutableString* r = [NSMutableString stringWithFormat:@"ok %s", SohSense_Dump()];
        [r appendFormat:@" | phys_ver=%d motion=%d lefthanded=%d mirror=%d,%d script=%d "
                        @"pins=%d swings_taken=%d sense_pad=0x%04x item_mask=0x%04x,0x%04x "
                        @"item_both=%d equip_nouse=%u fp=%d "
                        @"hammers=%d hammer_hits=%d hammer_env=%llu atk_kind=%d "
                        @"held_action=%d b_item=%d handlive=%d live_hits=%d hand_search=%d "
                        @"mtx_tag=%d mtx_n=%d,%d rec_valid=%d,%d mtx_clear_req=%d",
                        gSohVRPhysVersion, gSohVRMotionHands, gSohVRLeftHanded, gSohVRHandMirrorSword,
                        gSohVRHandMirrorShield, sohvr_script.active, gSohVRHandPins, gSohVRSwingsTaken,
                        gSohVRSensePadBits, gSohVRItemTriggerMask[0], gSohVRItemTriggerMask[1],
                        gSohVRItemTriggerBoth, gSohVREquipNoUse, gSohVRFpActive,
                        gSohVRHammers, gSohVRHammerHits, (unsigned long long)sohvr_hammerEnvelopes, sohvr_atkKind,
                        gSohVRHeldAction, gSohVRBItem, gSohVRHandLive, gSohVRHandLiveHits,
                        gSohVRHandLiveSearch, gSohVRHandMtxTag, gSohVRHandMtxCount[0],
                        gSohVRHandMtxCount[1], gSohVRHandRecValid[0], gSohVRHandRecValid[1],
                        gSohVRHandMtxClearReq];
        for (int h = 0; h < 2; h++) {
            char line[512];
            if (SohVrPhys_Describe(h, line, (int)sizeof(line)) > 0) {
                [r appendFormat:@" | %s", line];
            }
            [r appendFormat:@" | %s pub_valid=%d swing_seq=%u swing_spd=%.3f jump=%d tier=%d",
                            h == 0 ? "L" : "R", gSohVRHandValid[h], gSohVRSwingSeq[h], gSohVRSwingSpeed[h],
                            gSohVRSwingJump[h], gSohVRSwingTier[h]];
            // R7 verdict 2: THE CALIBRATION, MADE VISIBLE. the user asked to be
            // able to dial the hands; a dial with no readout is a guess with
            // extra steps. This prints the raw ARKit anchor position, the final
            // palm position after the calibration, and the offset/rotation in
            // force -- so the effect of a `vr set handoff` is readable in the
            // same line as the numbers that produced it.
            [r appendFormat:@" cal_off_cm=%.1f,%.1f,%.1f cal_rot_deg=%.1f,%.1f,%.1f "
                            @"raw_m=%.3f,%.3f,%.3f palm_m=%.3f,%.3f,%.3f",
                            sohvr_handOffCm[h][0], sohvr_handOffCm[h][1], sohvr_handOffCm[h][2],
                            sohvr_handRotDeg[h][0], sohvr_handRotDeg[h][1], sohvr_handRotDeg[h][2],
                            sohvr_handRawPose[h].columns[3].x, sohvr_handRawPose[h].columns[3].y,
                            sohvr_handRawPose[h].columns[3].z, sohvr_handCalPose[h].columns[3].x,
                            sohvr_handCalPose[h].columns[3].y, sohvr_handCalPose[h].columns[3].z];
            // R8 part B: the PUBLISHED palm -- calibrated AND thrust. palm_m is
            // what calibration produced; atk_m is what the game is drawing, and
            // the difference between them is the attack envelope. Two fields
            // rather than one because the rigidity claim below is about the
            // calibration and an envelope must not be able to break it.
            [r appendFormat:@" atk_m=%.3f,%.3f,%.3f", sohvr_handAtkPose[h].columns[3].x,
                            sohvr_handAtkPose[h].columns[3].y, sohvr_handAtkPose[h].columns[3].z];
            // R9 part A: the calibrated palm's OWN +X axis in world. With the
            // offsets re-based to zero in grip space, a wrist roll leaves
            // palm_m standing still -- which is the fix, and which also means
            // palm_m can no longer witness that a rotation sweep did anything.
            // This is the quantity that turns while the origin does not, so
            // "the hand rotates IN PLACE" is one assertion on two fields
            // instead of an inference. It is also the axis `atk_axdot`
            // compares against the solver's blade direction.
            [r appendFormat:@" palm_x=%.3f,%.3f,%.3f", sohvr_handCalPose[h].columns[0].x,
                            sohvr_handCalPose[h].columns[0].y, sohvr_handCalPose[h].columns[0].z];
            // R8 item 2(i): THE RIGIDITY READOUT. inverse(raw) * calibrated --
            // the transform that carries the tracked anchor onto the drawn
            // hand. If the chain is a rigid attach this is CONSTANT under any
            // anchor motion, and if it is not constant then the user's "the hand
            // rolls around my controller" has a cause in the composition rather
            // than in his offsets. Twelve numbers (the 3x3 basis and the
            // translation) rather than sixteen, because the bottom row of a
            // rigid transform carries no information and printing it would only
            // give a string comparison something to differ on.
            {
                simd_float4x4 rel = simd_mul(simd_inverse(sohvr_handRawPose[h]), sohvr_handCalPose[h]);
                [r appendString:@" rigid_m="];
                for (int c = 0; c < 4; c++) {
                    for (int e = 0; e < 3; e++) {
                        [r appendFormat:@"%s%.3f", (c == 0 && e == 0) ? "" : ",", rel.columns[c][e]];
                    }
                }
            }
        }
        return r;
    }
    // --- R5: the physical blade -------------------------------------------
    if ([sub isEqualToString:@"shield"]) {
        NSMutableString* r = [NSMutableString
            stringWithFormat:@"ok shield_physical=%d facing_deg=%.1f shield_hand=%d hand_valid=%d",
                             gSohVRShieldPhysical, gSohVRShieldFacingDeg, ((gSohVRLeftHanded != 0) ? 0 : 1) ^ 1,
                             gSohVRHandValid[((gSohVRLeftHanded != 0) ? 0 : 1) ^ 1]];
        [r appendString:@" | quad="];
        for (int i = 0; i < 9; i++) {
            [r appendFormat:@"%s%.2f", i ? "," : "", gSohVRShieldQuad[i]];
        }
        [r appendFormat:@" | held=%d vetoes=%d blocks=%d", gSohVRShieldHeld, gSohVRShieldVetoes, gSohVRShieldBlocks];
        return r;
    }
    if ([sub isEqualToString:@"item"]) {
        // The compass in one line. `open` with `sector` stuck at 0 is a flick
        // that never crossed the threshold (raise itemseldist or check the hand
        // is tracked); `opens` climbing with `picks` not is a release that found
        // no sector, which is the CENTRE pick and is legitimate.
        return [NSString
            stringWithFormat:@"ok vr_item itemsel=%d hand_cfg=%d hand=%d btn=0x%02x dist_cm=%.1f "
                             @"open=%d sector=%d opens=%d picks=%d draws=%d ticks=%u calls=%d avail=%d btn_seen=0x%02x "
                             @"world_scale=%.1f trigger_mask=0x%04x,0x%04x fp=%d "
                             @"wheel3d=%d wheelscale=%.2f models=%d wheelhalo=%d",
                             gSohVRItemSel, gSohVRItemSelHandCfg, gSohVRItemSelHand, gSohVRItemSelBtn,
                             gSohVRItemSelDistCm, gSohVRItemSelOpen, gSohVRItemSelSector, gSohVRItemSelOpens,
                             gSohVRItemSelPicks, gSohVRItemSelDraws, gSohVRItemSelTickSeq,
                             gSohVRItemSelCalls, gSohVRItemSelAvail, gSohVRItemSelBtnSeen, gSohVRWorldScale,
                             gSohVRItemTriggerMask[0], gSohVRItemTriggerMask[1], gSohVRFpActive,
                             gSohVRWheel3D, gSohVRWheelScale, gSohVRItemSelModels, gSohVRWheelHalo];
    }
    if ([sub isEqualToString:@"lens"]) {
        // R18 part B. `draws` climbing is the VR overlay running (it counts
        // rects emitted, so a tinted draw counts `passes` of them); `draws`
        // stuck at 0 with the lens on means the branch was not taken -- check
        // vr_mode and that the flat latch is clear.
        // R19 part B: `world` is the head-locked quad (1) versus the screen
        // rect (0); `dist` is where it sits, in metres; `tv` is the vertical
        // half-tangent the quad sizes vanilla's proportion against, taken as
        // the max of |tanT| and |tanB| over BOTH eyes because one display list
        // is rasterised into both.
        float sohTv = 0.0f;
        for (int e = 0; e < 2; e++) {
            float b = fabsf(gSohVREyeTan[e][2]);
            float t = fabsf(gSohVREyeTan[e][3]);
            if (b > sohTv) {
                sohTv = b;
            }
            if (t > sohTv) {
                sohTv = t;
            }
        }
        return [NSString stringWithFormat:@"ok vr_lens tint=%.2f scale=%.2f zfar=%d world=%d dist=%.2f tv=%.4f "
                                          @"draws=%d passes=%d "
                                          @"eye=%dx%d hudplane=%d vr_mode=%d flat_latch=%d cam_valid=%d "
                                          @"world_scale=%.1f",
                                          gSohVRLensTint, gSohVRLensScale, gSohVRLensZFar, gSohVRLensWorld,
                                          gSohVRLensDist, sohTv, gSohVRLensDraws,
                                          gSohVRLensPasses, gSoh3DEyeW, gSoh3DEyeH, gSohVRHudPlane, gSohVRMode,
                                          gSohVRFlatLatch, gSohVRCamValid, gSohVRWorldScale];
    }
    if ([sub isEqualToString:@"blade"]) {
        NSMutableString* r = [NSMutableString
            stringWithFormat:@"ok blade_damage=%d sword_hand=%d mesh_tris=%d mesh_dyna=%d mesh_bodies=%d "
                             @"mesh_seq=%u contacts=%d quads=%d hits=%d strikes=%d haptics=%u",
                             gSohVRBladeDamage, (gSohVRLeftHanded != 0) ? 0 : 1, gSohVRMeshCount, gSohVRBladeDyna,
                             gSohVRBladeBodies, gSohVRMeshSeq, gSohVRBladeContacts,
                             gSohVRBladeQuads, gSohVRBladeHits, gSohVRBladeStrikes, SohSense_HapticCount()];
        SohVrPhysCfg* c = SohVrPhys_Cfg();
        [r appendFormat:@" | cfg contact=%d pivot=%d radius=%.4f width=%.4f taper=%.2f fric=%.2f "
                        @"pass=%.2f drag=%.2f touch=%.4f",
                        c->contactEnabled, c->pivotOnly, c->bladeRadiusM, c->bladeHalfWidthM, c->tipTaper,
                        c->friction, c->passthroughMps, c->cutDrag, c->touchTolM];
        for (int h = 0; h < 2; h++) {
            SohVrPhysOut po;
            int ok = SohVrPhys_Get(h, &po);
            [r appendFormat:@" | %s line_valid=%d hit_seq=%u", h == 0 ? "L" : "R", gSohVRBladeValid[h],
                            gSohVRBladeHitSeq[h]];
            if (ok) {
                [r appendFormat:@" contacts=%d pass=%d off=%.4f base=%.3f,%.3f,%.3f tip=%.3f,%.3f,%.3f",
                                po.contactCount, po.passthrough, po.bladeOffset, po.bladeBase.x, po.bladeBase.y,
                                po.bladeBase.z, po.bladeTip.x, po.bladeTip.y, po.bladeTip.z];
            }
            if (gSohVRBladeValid[h]) {
                int s = gSohVRPairSlot & 1;
                [r appendFormat:@" game_base=%.1f,%.1f,%.1f game_tip=%.1f,%.1f,%.1f", gSohVRBladeLine[s][h][0],
                                gSohVRBladeLine[s][h][1], gSohVRBladeLine[s][h][2], gSohVRBladeLine[s][h][3],
                                gSohVRBladeLine[s][h][4], gSohVRBladeLine[s][h][5]];
            }
        }
        return r;
    }
    if ([sub isEqualToString:@"swing"] || [sub isEqualToString:@"wave"]) {
        int isWave = [sub isEqualToString:@"wave"];
        int hand = SOHSENSE_RIGHT;
        if (args.count >= 2) {
            hand = [args[1].uppercaseString isEqualToString:@"L"] ? SOHSENSE_LEFT : SOHSENSE_RIGHT;
        }
        // The two calibrated profiles. FAST is the one that must produce
        // exactly one attack; SLOW is its control and must produce none.
        // Numbers verified against SohVrPhys.c's own host suite.
        sohvr_script.hand = hand;
        sohvr_script.peak = isWave ? 0.4f : 3.0f;
        sohvr_script.angPeak = isWave ? 0.5f : 12.0f;
        sohvr_script.dur = isWave ? 1.0f : 0.5f;
        if (args.count >= 5) {
            sohvr_script.peak = args[2].floatValue;
            sohvr_script.angPeak = args[3].floatValue;
            sohvr_script.dur = args[4].floatValue;
        }
        if (!(sohvr_script.dur > 0.05f && sohvr_script.dur < 5.0f)) {
            return @"err duration must be 0.05 .. 5 s";
        }
        sohvr_script.seqAtStart = gSohVRSwingSeq[hand];
        sohvr_script.t0 = CACurrentMediaTime();
        sohvr_script.active = 1;
        // Block for the trajectory plus a couple of ticks, so the reply
        // already carries the verdict and the caller needs no sleep.
        usleep((useconds_t)((sohvr_script.dur + 0.25f) * 1000000.0f));
        unsigned int fired = gSohVRSwingSeq[hand] - sohvr_script.seqAtStart;
        return [NSString stringWithFormat:@"ok %s hand=%s peak=%.2f ang=%.2f dur=%.2f swings_fired=%u "
                                          @"seq=%u last_spd=%.3f jump=%d tier=%d",
                                          isWave ? "wave" : "swing", hand == SOHSENSE_LEFT ? "L" : "R",
                                          sohvr_script.peak, sohvr_script.angPeak, sohvr_script.dur, fired,
                                          gSohVRSwingSeq[hand], gSohVRSwingSpeed[hand], gSohVRSwingJump[hand],
                                          gSohVRSwingTier[hand]];
    }
    if ([sub isEqualToString:@"hand"] && args.count >= 2) {
        NSString* a1 = args[1].lowercaseString;
        if ([a1 isEqualToString:@"off"]) {
            sohvr_script.active = 0;
            SohSense_InjectClear();
            usleep(40 * 1000);
            return [NSString stringWithFormat:@"ok hands released | %s", SohSense_Dump()];
        }
        if ([a1 isEqualToString:@"doff"]) {
            sohvr_script.active = 0;
            SohSense_InjectDoff();
            usleep(40 * 1000);
            return [NSString stringWithFormat:@"ok doff | %s", SohSense_Dump()];
        }
        int hand = [args[1].uppercaseString isEqualToString:@"L"] ? SOHSENSE_LEFT : SOHSENSE_RIGHT;
        NSString* verb = args.count >= 3 ? args[2].lowercaseString : @"";
        if ([verb isEqualToString:@"vel"] && args.count >= 6) {
            SohSense_InjectVelocity(hand, args[3].floatValue, args[4].floatValue, args[5].floatValue);
        } else if ([verb isEqualToString:@"angvel"] && args.count >= 6) {
            SohSense_InjectAngVelocity(hand, args[3].floatValue, args[4].floatValue, args[5].floatValue);
        } else if ([verb isEqualToString:@"btn"] && args.count >= 5) {
            SohSense_InjectButton(hand, args[3].UTF8String, args[4].intValue);
        } else if ([verb isEqualToString:@"stick"] && args.count >= 5) {
            SohSense_InjectStick(hand, args[3].floatValue, args[4].floatValue);
        } else if ([verb isEqualToString:@"grip"] && args.count >= 6) {
            // R9 part A: the accessory's anchor->grip translation, in METRES.
            // The simulator has no spatial hardware, so this is the only way
            // the grip composition can be exercised off a headset.
            SohSense_InjectGrip(hand, args[3].floatValue, args[4].floatValue, args[5].floatValue);
        } else if ([verb isEqualToString:@"euler"] && args.count >= 9) {
            SohSense_InjectHandEuler(hand, args[3].floatValue, args[4].floatValue, args[5].floatValue,
                                     args[6].floatValue, args[7].floatValue, args[8].floatValue);
        } else if (args.count >= 9) {
            // vr hand L|R X Y Z QX QY QZ QW
            SohSense_InjectHand(hand, args[2].floatValue, args[3].floatValue, args[4].floatValue,
                                args[5].floatValue, args[6].floatValue, args[7].floatValue, args[8].floatValue);
        } else if (args.count >= 5) {
            // vr hand L|R X Y Z -- identity rotation, the common case
            SohSense_InjectHand(hand, args[2].floatValue, args[3].floatValue, args[4].floatValue, 0, 0, 0, 1);
        } else {
            return @"err usage: vr hand L|R X Y Z [QX QY QZ QW] | vr hand L|R euler X Y Z YAW PITCH ROLL "
                   @"| vr hand L|R vel VX VY VZ | vr hand L|R angvel WX WY WZ "
                   @"| vr hand L|R btn trigger|grip|primary|secondary|thumbclick|menu 0|1 "
                   @"| vr hand L|R stick X Y | vr hand L|R grip GX GY GZ (metres) "
                   @"| vr hand off | vr hand doff";
        }
        usleep(40 * 1000); // let the loop commit and filter before the dump
        return [NSString stringWithFormat:@"ok %s", SohSense_Dump()];
    }
    // R8 part B: `vr atk stab|chop` and `vr crouch 0|1|auto`. The GAME side
    // decides when an attack or a shield stance happens; the SHELL owns the
    // envelope and the eased eye drop. These two verbs drive the shell's half
    // directly, exactly as `vr hand` drives the tracking half, because a
    // Z-target chop and a raised shield both depend on where Link is standing
    // and a simulator cannot promise either. The end-to-end path is still
    // exercised where the game will cooperate; this is what makes the SHELL's
    // arithmetic assertable when it will not.
    if ([sub isEqualToString:@"atk"] && args.count >= 2) {
        NSString* which = args[1].lowercaseString;
        if ([which isEqualToString:@"chop"]) {
            gSohVRChops = gSohVRChops + 1;
        } else if ([which isEqualToString:@"stab"]) {
            gSohVRStabs = gSohVRStabs + 1;
        // R19 item 1: and the hammer, for the same reason the other two are
        // here -- the GAME decides when a hammer swing starts and it needs a
        // hammer, a target and a floor to do it. The shell's envelope is
        // arithmetic and is assertable without any of the three.
        } else if ([which isEqualToString:@"hammer"]) {
            gSohVRHammers = gSohVRHammers + 1;
        } else {
            return @"err usage: vr atk stab|chop|hammer";
        }
        return [NSString stringWithFormat:@"ok vr_atk %@ stabs=%d chops=%d hammers=%d", which, gSohVRStabs,
                                          gSohVRChops, gSohVRHammers];
    }
    // R9 part B: THE FLIP CAMERA'S SIGN, made testable. `vr flip back|roll` forces
    // the source the integrator reads; `off`/`auto` hands it back to the game. A
    // backflip needs a lock-on target and a roll needs room, so without this the
    // sign assertion would only run where the harness happened to leave Link.
    if ([sub isEqualToString:@"flip"] && args.count >= 2) {
        NSString* which = args[1].lowercaseString;
        if ([which isEqualToString:@"back"] || [which isEqualToString:@"backflip"]) {
            sohvr_flipForce = 1;
        } else if ([which isEqualToString:@"roll"]) {
            sohvr_flipForce = 2;
        } else if ([which isEqualToString:@"off"] || [which isEqualToString:@"none"]) {
            sohvr_flipForce = 0;
        } else if ([which isEqualToString:@"auto"]) {
            sohvr_flipForce = -1;
        } else {
            return @"err usage: vr flip back|roll|off|auto";
        }
        return [NSString stringWithFormat:@"ok vr_flip force=%d kind=%d deg=%.1f flipcam=%d "
                                          @"eye_fwd=%.3f,%.3f,%.3f flips=%llu rolls=%llu",
                                          sohvr_flipForce, sohvr_flipKind,
                                          sohvr_flipAngle * (180.0f / (float)M_PI), sohvr_flipCam,
                                          sohvr_eyeFwd[0].x, sohvr_eyeFwd[0].y, sohvr_eyeFwd[0].z,
                                          (unsigned long long)sohvr_flips, (unsigned long long)sohvr_rolls];
    }
    // R9 part B: the ocarina profile, forced. It is the ONE place a stick may
    // become a C button now, and reaching it for real needs an ocarina, a song
    // and a textbox -- none of which a simulator suite can arrange.
    if ([sub isEqualToString:@"ocarina"] && args.count >= 2) {
        NSString* which = args[1].lowercaseString;
        if ([which isEqualToString:@"auto"]) {
            gSohVROcarinaForce = -1;
        } else {
            gSohVROcarinaForce = (args[1].intValue != 0) ? 1 : 0;
        }
        usleep(60 * 1000); // one game tick, so `out=` is this setting's answer
        return [NSString stringWithFormat:@"ok vr_ocarina force=%d out=%d sense_pad=0x%04x",
                                          gSohVROcarinaForce, gSohVROcarinaOut,
                                          (unsigned)gSohVRSensePadBits];
    }
    // R9 part B: the SDL-side of "a Sense controller is not a gamepad" (overlay
    // 0052). `vr sdlpads` reports how many spatial devices were skipped and how
    // many names the Sense registration has learned; `vr sensename NAME` asks
    // the predicate itself, which is the only part of this a simulator with no
    // controller attached can actually exercise.
    if ([sub isEqualToString:@"sdlpads"]) {
        return [NSString stringWithFormat:@"ok vr_sdlpads spatial_skips=%d spatial_names=%d sense_active=%d",
                                          SohSense_SdlSpatialSkips(), SohSense_SpatialNameCount(),
                                          gSohVRSenseActive];
    }
    if ([sub isEqualToString:@"sensename"] && args.count >= 2) {
        NSString* nm = [[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@" "];
        return [NSString stringWithFormat:@"ok vr_sensename name='%@' spatial=%d", nm,
                                          SohSense_IsSpatialControllerName(nm.UTF8String)];
    }
    // R9 part B: the shield stance, forced. the user: "the left grip shield crouch
    // lowers your height but now you can move around, which you're not supposed
    // to." The STOP is what this round adds; whether Link owns a shield is not.
    if ([sub isEqualToString:@"shieldstance"] && args.count >= 2) {
        NSString* which = args[1].lowercaseString;
        if ([which isEqualToString:@"auto"]) {
            gSohVRShieldStanceForce = -1;
        } else {
            gSohVRShieldStanceForce = (args[1].intValue != 0) ? 1 : 0;
        }
        usleep(60 * 1000);
        return [NSString stringWithFormat:@"ok vr_shieldstance force=%d crouch=%d stops=%d link_vel=%.2f",
                                          gSohVRShieldStanceForce, gSohVRCrouch, gSohVRShieldStops, gSohVRLinkVel];
    }
    if ([sub isEqualToString:@"crouch"] && args.count >= 2) {
        NSString* which = args[1].lowercaseString;
        if ([which isEqualToString:@"auto"]) {
            sohvr_crouchForce = -1;
        } else {
            sohvr_crouchForce = (args[1].intValue != 0) ? 1 : 0;
        }
        return [NSString stringWithFormat:@"ok vr_crouch force=%d game=%d now=%.3f frac=%.2f drop=%.2f",
                                          sohvr_crouchForce, gSohVRCrouch, sohvr_crouchNow, sohvr_crouchFrac,
                                          sohvr_crouch_drop()];
    }
    // R7 verdict 2: `vr set handoff L|R  px py pz  ry rp rr` -- six numbers per
    // hand, in the units the user will think in (CENTIMETRES for the offset,
    // DEGREES for the rotation), applied in the controller's own frame. Handled
    // ahead of the generic key/value `set` because it takes eight arguments
    // rather than two. Any trailing argument may be omitted; what is omitted
    // keeps its current value, so a single axis can be nudged without retyping
    // the other five.
    if ([sub isEqualToString:@"set"] && args.count >= 3 && [args[1].lowercaseString isEqualToString:@"handoff"]) {
        NSString* w = args[2].uppercaseString;
        int hand = [w hasPrefix:@"L"] ? 0 : ([w hasPrefix:@"R"] ? 1 : -1);
        if (hand < 0) {
            return @"err vr set handoff needs L or R "
                   @"(usage: vr set handoff L|R [px_cm py_cm pz_cm] [yaw_deg pitch_deg roll_deg])";
        }
        for (int i = 0; i < 3 && (int)args.count > 3 + i; i++) {
            float v = args[3 + i].floatValue;
            if (v > -50.0f && v < 50.0f) {
                sohvr_handOffCm[hand][i] = v;
            }
        }
        for (int i = 0; i < 3 && (int)args.count > 6 + i; i++) {
            float v = args[6 + i].floatValue;
            if (v >= -360.0f && v <= 360.0f) {
                sohvr_handRotDeg[hand][i] = v;
            }
        }
        return [NSString stringWithFormat:@"ok vr handoff %s off_cm=%.1f,%.1f,%.1f rot_deg=%.1f,%.1f,%.1f "
                                          @"(read the effect back with `vr hands`)",
                                          hand == 0 ? "L" : "R", sohvr_handOffCm[hand][0], sohvr_handOffCm[hand][1],
                                          sohvr_handOffCm[hand][2], sohvr_handRotDeg[hand][0],
                                          sohvr_handRotDeg[hand][1], sohvr_handRotDeg[hand][2]];
    }
    if ([sub isEqualToString:@"set"] && args.count >= 3) {
        NSString* k = args[1].lowercaseString;
        float v = args[2].floatValue;
        // R8 item 4: `scale` is an EXPERIMENT knob. It does not persist and
        // nothing pushes it at VR entry -- the shipped value is the hardcoded
        // 34 and the settings row is gone.
        if ([k isEqualToString:@"scale"] && v > 0.1f && v < 10000.0f) {
            SohVR_SetWorldScale(v);
        } else if ([k isEqualToString:@"height"]) {
            // R8 item 5: the TRIM, in metres from the calibrated state.
            sohvr_height = v;
        } else if ([k isEqualToString:@"near"] && v > 0.01f) {
            sohvr_near = v;
        } else if ([k isEqualToString:@"far"] && v > 1.0f) {
            sohvr_far = v;
        } else if ([k isEqualToString:@"rendezvous"] && v >= 0.0f && v <= 20.0f) {
            sohvr_rendezvousMs = v;
        } else if ([k isEqualToString:@"flatworld"]) {
            sohvr_flatWorldBackdrop = (v != 0.0f);
        } else if ([k isEqualToString:@"hostdiv"] && v >= 0.0f && v <= 4.0f) {
            // 0 = auto (present_hz / hostdiv <= 60). Forcing 1 on device is the
            // A/B that reproduces the 1.0.1.1 pacing exactly.
            sohvr_hostDiv = (int)(v + 0.5f);
        } else if ([k isEqualToString:@"eyescale"] && v >= 0.25f && v <= 2.0f) {
            sohvr_eyeScale = v;
        } else if ([k isEqualToString:@"eyebudget"] && v >= 256.0f && v <= 8192.0f) {
            sohvr_eyeBudget = v;
        } else if ([k isEqualToString:@"roommode"] && v >= 0.0f && v <= 2.0f) {
            SohVR_SetRoomMode((int)(v + 0.5f));
        } else if ([k isEqualToString:@"flipcam"]) {
            // R7 verdict 5's red control: 0 keeps the head level through a
            // backflip, which is the comfort path and the A/B.
            SohVR_SetFlipCam(v != 0.0f);
        } else if ([k isEqualToString:@"hudplane"]) {
            // The red control for the D7 fix: 0 chains the HUD back onto the
            // world list, i.e. 1.0.1.2's doubled behaviour, in one command.
            gSohVRHudPlane = (v != 0.0f);
        } else if ([k isEqualToString:@"huddist"] && v >= 0.5f && v <= 8.0f) {
            sohvr_hudDist = v;
        } else if ([k isEqualToString:@"hudsize"] && v >= 0.2f && v <= 6.0f) {
            sohvr_hudWidth = v;
        } else if ([k isEqualToString:@"hudkey"] && v >= 0.0f && v <= 64.0f) {
            // R7 verdict 7's red control: 0 restores the alpha-only composite,
            // which is the state in which the user saw no HUD at all.
            sohvr_hudKeyGain = v;
        } else if ([k isEqualToString:@"hudup"] && v >= -2.0f && v <= 2.0f) {
            sohvr_hudUp = v;
        } else if ([k isEqualToString:@"turn"] && v >= 0.0f && v <= 90.0f) {
            sohvr_turnDeg = v; // 0 = SMOOTH (default), else the snap angle
        } else if ([k isEqualToString:@"turnspeed"] && v >= 30.0f && v <= 360.0f) {
            sohvr_smoothDegPerSec = v; // donor gVrSmoothTurnSpeed, default 120
        } else if ([k isEqualToString:@"ladderfollow"]) {
            // R16 item 4: turn the world with Link when the GAME turns him.
            sohvr_ladderFollow = (v != 0.0f);
        } else if ([k isEqualToString:@"boomdirect"]) {
            // R16 item 2: 0 restores vanilla's hold-to-aim boomerang.
            gSohVRBoomDirect = (v != 0.0f);
        } else if ([k isEqualToString:@"hidebody"]) {
            gSohVRHideBody = (v != 0.0f); // donor gVrHideBody, default 1
        } else if ([k isEqualToString:@"followhead"]) {
            gSohVRBodyFollowsHead = (v != 0.0f); // donor gVrBodyFollowsHead, 1
        } else if ([k isEqualToString:@"eyeoffset"] && v >= -40.0f && v <= 10.0f) {
            gSohVRHeadHeightOffset = v; // donor gVrHeadHeightOffset, default -9
        } else if ([k isEqualToString:@"fpforward"] && v >= -40.0f && v <= 40.0f) {
            gSohVRHeadOffsetFwd = v; // donor gVrHeadOffsetForward, default 6
        } else if ([k isEqualToString:@"fpfar"] && v >= 200.0f && v <= 20000.0f) {
            gSohVRFpFallbackDist = v; // donor gVrFpFallbackDist, default 1200
        // --- R4 (DONOR-MAP 3 + 8 + 9) ---------------------------------------
        } else if ([k isEqualToString:@"motionhands"]) {
            gSohVRMotionHands = (v != 0.0f); // donor gVrMotionHands, default 1
        } else if ([k isEqualToString:@"lefthanded"]) {
            gSohVRLeftHanded = (v != 0.0f); // donor gVrLeftHanded, default 0
        } else if ([k isEqualToString:@"mirrorsword"]) {
            gSohVRHandMirrorSword = (v != 0.0f); // donor gVrHandMirrorSword, 1
        } else if ([k isEqualToString:@"mirrorshield"]) {
            gSohVRHandMirrorShield = (v != 0.0f); // donor gVrHandMirrorShield, 1
        } else if ([k isEqualToString:@"swingsens"] && v >= 0.5f && v <= 2.0f) {
            // ONE knob over all five speed thresholds -- higher is easier to
            // trigger. The five underlying numbers stay reachable below for
            // tuning, but this is the row the settings sheet shows.
            SohVrPhys_Cfg()->sensitivity = v;
        } else if ([k isEqualToString:@"swingarm"] && v > 0.0f && v <= 20.0f) {
            SohVrPhys_Cfg()->tierArmed = v; // donor gVrPhysArmSpeed 2.0
        } else if ([k isEqualToString:@"swinghit"] && v > 0.0f && v <= 20.0f) {
            SohVrPhys_Cfg()->tierHot = v; // donor gVrPhysHitSpeed 5.0
        } else if ([k isEqualToString:@"swingidle"] && v > 0.0f && v <= 20.0f) {
            SohVrPhys_Cfg()->tierIdle = v; // donor gVrPhysReArmSpeed 0.8
        } else if ([k isEqualToString:@"swingheavy"] && v > 0.0f && v <= 40.0f) {
            SohVrPhys_Cfg()->jumpSlash = v; // donor gVrPhysHeavySpeed 8.0
        } else if ([k isEqualToString:@"swinghandfloor"] && v >= 0.0f && v <= 20.0f) {
            SohVrPhys_Cfg()->handFloor = v; // donor gVrPhysMinHandSpeed 1.2
        } else if ([k isEqualToString:@"bladelen"] && v > 0.05f && v <= 4.0f) {
            SohVrPhys_Cfg()->bladeLenM = v; // metres; Master sword = 35u/35 = 1.0
        } else if ([k isEqualToString:@"weightlag"] && v >= 0.0f && v <= 0.5f) {
            SohVrPhys_Cfg()->visualLagS = v; // donor WeightLagMs, ships 0 (off)
        } else if ([k isEqualToString:@"weightsnap"] && v >= 0.5f && v <= 30.0f) {
            SohVrPhys_Cfg()->visualSnapHz = v; // donor WeightSnapHz 2
        } else if ([k isEqualToString:@"handlive"]) {
            gSohVRHandLive = (v != 0.0f); // 0 = R4's 20 Hz interpolated hands
        } else if ([k isEqualToString:@"shieldphysical"]) {
            gSohVRShieldPhysical = (v != 0.0f); // donor gVrPhysShield
        } else if ([k isEqualToString:@"itemsel"]) {
            gSohVRItemSel = (v != 0.0f); // the Alyx compass; 0 = R4's trigger mirror alone
        } else if ([k isEqualToString:@"itemselhand"]) {
            gSohVRItemSelHandCfg = (v != 0.0f); // 0 = sword hand, 1 = off hand
        } else if ([k isEqualToString:@"itemselbtn"]) {
            gSohVRItemSelBtn = (unsigned int)v; // SOHSENSE_BTN_* mask; 8 = grip, 16 = thumbclick
        } else if ([k isEqualToString:@"wheel3d"]) {
            // R18 part C (D-070): 1 = the game's own 3D get-item models in the
            // wheel, 0 = the donor's flat gItemIcons quads for every slot.
            gSohVRWheel3D = (v != 0.0f);
        } else if ([k isEqualToString:@"wheelscale"]) {
            // Multiplies the derived model size. The game side clamps it to
            // 0.02 .. 4.0 as well; clamped here too so the status line never
            // reports a number the wheel is not using.
            if (v < 0.02f) {
                v = 0.02f;
            } else if (v > 4.0f) {
                v = 4.0f;
            }
            gSohVRWheelScale = v;
        } else if ([k isEqualToString:@"lensworld"]) {
            // R19 part B (D-073): 1 = the mask is a head-locked WORLD quad, so
            // both eyes see the same world point and the circle fuses; 0 = the
            // screen-space rect, which fuses at infinity and lands off-axis by
            // the frustum asymmetry in opposite directions per eye (the user's
            // "doubled red circles"). This is the one-command A/B.
            gSohVRLensWorld = (v != 0.0f);
        } else if ([k isEqualToString:@"lensdist"]) {
            // Metres in front of the head. Clamped rather than trusted: the
            // console is reachable from inside the headset and a mask at 0.05 m
            // is a red screen with no way back except this same command.
            if (v < 0.4f) {
                v = 0.4f;
            } else if (v > 4.0f) {
                v = 4.0f;
            }
            gSohVRLensDist = v;
        } else if ([k isEqualToString:@"wheelhalo"]) {
            // R19 part B (D-073): 0 none / 1 thin gold ring / 2 soft glow.
            if (v < 0.0f) {
                v = 0.0f;
            } else if (v > 2.0f) {
                v = 2.0f;
            }
            gSohVRWheelHalo = (int)v;
        } else if ([k isEqualToString:@"lenstint"] && v >= 1.0f && v <= 6.0f) {
            // R18 part B: the multiplier on vanilla's 74/255 mask alpha. The
            // game side clamps to exactly this range as well.
            gSohVRLensTint = v;
        } else if ([k isEqualToString:@"lensscale"] && v >= 0.3f && v <= 2.0f) {
            gSohVRLensScale = v;
        } else if ([k isEqualToString:@"lenszfar"]) {
            // 0 = vanilla: the near-plane depth field reaches the compositor.
            gSohVRLensZFar = (v != 0.0f);
        } else if ([k isEqualToString:@"crouch"]) {
            // R8 part B: how far the eye drops in the shield stance, as a
            // fraction of standing eye height. Clamped rather than trusted --
            // a crouch of 1.0 puts the camera on the floor and the console is
            // reachable from a headset where a typo is easy.
            if (v < 0.0f) {
                v = 0.0f;
            } else if (v > 0.5f) {
                v = 0.5f;
            }
            sohvr_crouchFrac = v;
        // --- R9 part B: THE SLASH ENVELOPE ----------------------------------
        // Six numbers, all clamped, because the console is reachable from a
        // headset where a typo is easy and an envelope that lasts a minute is
        // a hand nobody can put down.
        } else if ([k isEqualToString:@"slasharc"] && v >= 0.0f && v <= 180.0f) {
            sohvr_slashArcDeg = v; // how far toward world-up the windup lifts the tip
        } else if ([k isEqualToString:@"slashdown"] && v >= -30.0f && v <= 80.0f) {
            sohvr_slashDownDeg = v; // how far below the horizon the strike finishes
        } else if ([k isEqualToString:@"slashreach"] && v >= 0.0f && v <= 1.0f) {
            sohvr_slashReachM = v; // metres the grip pivot travels along body forward
        } else if ([k isEqualToString:@"slashsecs"] && v >= 0.10f && v <= 1.5f) {
            sohvr_slashSecs = v;
        } else if ([k isEqualToString:@"jumparc"] && v >= 0.0f && v <= 180.0f) {
            sohvr_jumpArcDeg = v;
        } else if ([k isEqualToString:@"jumpsecs"] && v >= 0.10f && v <= 1.5f) {
            sohvr_jumpSecs = v;
        // --- R10: the follow-through -----------------------------------------
        } else if ([k isEqualToString:@"slashdrop"] && v >= 0.0f && v <= 0.5f) {
            sohvr_slashDropM = v; // metres the grip drops as it goes forward
        } else if ([k isEqualToString:@"slashhold"] && v >= 0.0f && v <= 0.5f) {
            sohvr_slashHoldSecs = v; // the beat held at the finish
        } else if ([k isEqualToString:@"slashback"] && v >= 0.05f && v <= 1.0f) {
            sohvr_slashBackSecs = v; // the ease back to the tracked pose
        } else if ([k isEqualToString:@"jumpreach"] && v >= 0.0f && v <= 1.2f) {
            sohvr_jumpReachM = v;
        // --- R19 item 1: THE HAMMER'S CHOP, eight of its own (R20) ------------
        // Same clamps as the slash's, one range apart: hammerdown goes PAST
        // vertical (110) because a hammer chop legitimately finishes straight
        // down at 90 and a wearer may want it to carry through, where a sword's
        // 80 was already generous.
        } else if ([k isEqualToString:@"hammerarc"] && v >= 0.0f && v <= 180.0f) {
            sohvr_hammerArcDeg = v; // degrees the head lifts before it comes down
        } else if ([k isEqualToString:@"hammerdown"] && v >= -30.0f && v <= 110.0f) {
            sohvr_hammerDownDeg = v; // degrees below the horizon the head finishes
        } else if ([k isEqualToString:@"hammerreach"] && v >= 0.0f && v <= 1.0f) {
            sohvr_hammerReachM = v; // metres forward -- a chop travels DOWN
        } else if ([k isEqualToString:@"hammerdrop"] && v >= 0.0f && v <= 0.8f) {
            sohvr_hammerDropM = v; // metres the grip drops: the number that matters
        } else if ([k isEqualToString:@"hammersecs"] && v >= 0.10f && v <= 1.5f) {
            sohvr_hammerSecs = v; // 0.35 is vanilla's frame 7 at 20 Hz
        } else if ([k isEqualToString:@"hammerhold"] && v >= 0.0f && v <= 0.5f) {
            sohvr_hammerHoldSecs = v;
        } else if ([k isEqualToString:@"hammerback"] && v >= 0.05f && v <= 1.0f) {
            sohvr_hammerBackSecs = v;
        } else if ([k isEqualToString:@"hammerprobe"] && v >= 0.0f && v <= 40.0f) {
            // R20 item 1c: GAME UNITS the ground line test is extended past the
            // hammer's tip, for the hammer only and in VR only. 15 units is
            // 0.44 m at the shipped world scale of 34 units/m -- the gap a
            // waist-height chop leaves between the head and the floor now that
            // the grip drop is zero.
            gSohVRHammerProbe = v;
        } else if ([k isEqualToString:@"itemseldist"]) {
            gSohVRItemSelDistCm = v; // donor gVrItemSelDistance, cm of real hand travel
        } else if ([k isEqualToString:@"shieldfacing"]) {
            gSohVRShieldFacingDeg = v; // donor gVrPhysShieldFacingDeg 65; >=179 off
        } else if ([k hasPrefix:@"shieldq"]) {
            // shieldq0..shieldq8: width top / width bottom / height / shift
            // across / shift up / shift out / pitch / yaw / roll. One key per
            // slider rather than nine names, because every one of them is going
            // to be swept from a headset and a numeric index is what a sweep
            // script wants.
            int idx = [[k substringFromIndex:7] intValue];
            if (idx >= 0 && idx < 9) {
                gSohVRShieldQuad[idx] = v;
            }
        } else if ([k isEqualToString:@"bladedamage"]) {
            gSohVRBladeDamage = (v != 0.0f); // 0 = R4's authored attack
        } else if ([k isEqualToString:@"contact"]) {
            SohVrPhys_Cfg()->contactEnabled = (v != 0.0f); // donor gVrPhysBladeInertia
        } else if ([k isEqualToString:@"pivotonly"]) {
            SohVrPhys_Cfg()->pivotOnly = (v != 0.0f); // donor gVrPhysPivotOnly
        } else if ([k isEqualToString:@"bladeradius"]) {
            SohVrPhys_Cfg()->bladeRadiusM = v; // donor kBladeRadiusM 0.012
        } else if ([k isEqualToString:@"bladewidth"]) {
            SohVrPhys_Cfg()->bladeHalfWidthM = v; // half-width, metres
        } else if ([k isEqualToString:@"bladetaper"]) {
            SohVrPhys_Cfg()->tipTaper = v; // donor gVrPhysBladeTipTaper 0.2
        } else if ([k isEqualToString:@"bladefriction"]) {
            SohVrPhys_Cfg()->friction = v; // donor gVrPhysBladeFriction 0.5
        } else if ([k isEqualToString:@"passthrough"]) {
            SohVrPhys_Cfg()->passthroughMps = v; // donor gVrPhysPassthroughSpeed 2.2
        } else if ([k isEqualToString:@"cutdrag"]) {
            SohVrPhys_Cfg()->cutDrag = v; // donor gVrPhysCutDragWorld 0.73
        } else if ([k isEqualToString:@"touchtol"]) {
            SohVrPhys_Cfg()->touchTolM = v; // donor kTouchToleranceM 0.008
        } else if ([k isEqualToString:@"aim"]) {
            // R13 (Q-VR28): 0 = vanilla's own arithmetic at all three sites.
            // The A/B for "is the new aim better than the old one", which is a
            // question only a headset can answer.
            gSohVRAim = (v != 0.0f) ? 1 : 0;
        } else if ([k isEqualToString:@"aimframe"] && v >= 0.0f && v <= 2.0f) {
            // 0 = the calibrated HAND pose, 1 = the ITEM-corrected one, 2 = the
            // controller's own AIM location (R15, shipped). 0 and 1 are the A/B
            // and the fallback for a hand the runtime has not answered for.
            gSohVRAimFrame = (int)(v + 0.5f);
        } else if ([k isEqualToString:@"aimpitch"] && v >= -180.0f && v <= 180.0f) {
            // R14: the trims are PER ITEM and PER CONFIGURATION. The verb writes
            // the row for whatever aimable item is in hand right now, and the
            // BOW/SLINGSHOT row when nothing is -- which is what the simulator
            // and the suite always see. `vr aim` prints trim_item so the row
            // that was written is never in doubt. Negative aims UP.
            gSohVRAimTrimDeg[SohVR_AimTrimModel()][gSohVRLeftHanded ? 1 : 0][1] = v;
        } else if ([k isEqualToString:@"aimyaw"] && v >= -180.0f && v <= 180.0f) {
            gSohVRAimTrimDeg[SohVR_AimTrimModel()][gSohVRLeftHanded ? 1 : 0][0] = v;
        } else if ([k isEqualToString:@"aimhandfix"]) {
            // R14: 0 = use the axis table in the AIMING hand's own frame (rev14's
            // behaviour), 1 = carry it out of the sword hand's frame first. The
            // A/B for "is the off hand's calibration what turned the aim".
            gSohVRAimHandFixOn = (v != 0.0f) ? 1 : 0;
        } else if ([k isEqualToString:@"aimreticle"]) {
            gSohVRAimReticle = (v != 0.0f) ? 1 : 0; // R15: the crosshair
        } else if ([k isEqualToString:@"aimreticlerange"] && v >= 1000.0f && v <= 1000000.0f) {
            gSohVRAimReticleRange = v; // limb model units (x0.01 game units)
        } else if ([k isEqualToString:@"aimreticlescale"] && v >= 0.05f && v <= 4.0f) {
            // R17 item 2: the crosshair's size, as a multiplier on vanilla's
            // own distance term. 0.5 ships ("half the size"); 1.0 is vanilla.
            gSohVRAimReticleScale = v;
        } else if ([k isEqualToString:@"aimspawn"] && v >= -100.0f && v <= 100.0f) {
            gSohVRAimSpawnU = v; // game units along the aim, from the hand origin
        } else if ([k isEqualToString:@"gripspace"] && SohSense_SetTunable(k.UTF8String, v)) {
            // R9 part A: 1 = publish the accessory's GRIP coordinate space,
            // 0 = publish the raw anchor (every build before R9). The A/B for
            // the roll orbit; `vr hands` reports gripspace= and grip_src=.
        } else if ([k hasPrefix:@"vel"] && SohSense_SetTunable(k.UTF8String, v)) {
            // velsource / velcutoff / velbeta / veldcutoff -- the one-euro
            // filter and which velocity provenance is in force. See SohSense.h.
        } else {
            // R9 part B: `lockon` went with R8 item 9 and had outlived its
            // mention here; `gripspace` (R9 part A) and the six slash keys are
            // added. A usage string that names a key the parser has no branch
            // for is a bug report waiting to be filed against the wrong thing.
            return @"err usage: vr set scale|height|near|far|rendezvous|flatworld|hostdiv|eyescale|eyebudget|"
                   @"roommode|flipcam|hudplane|huddist|hudsize|hudup|hudkey|turn|turnspeed|hidebody|followhead|"
                   @"eyeoffset|fpforward|fpfar|motionhands|lefthanded|gripspace|mirrorsword|mirrorshield|swingsens|"
                   @"swingarm|swinghit|swingidle|swingheavy|swinghandfloor|bladelen|weightlag|weightsnap|"
                   @"slasharc|slashdown|slashreach|slashsecs|slashdrop|slashhold|slashback|"
                   @"jumparc|jumpsecs|jumpreach|"
                   @"hammerarc|hammerdown|hammerreach|hammerdrop|hammersecs|hammerhold|hammerback|hammerprobe|"
                   @"aim|aimframe|aimpitch|aimyaw|aimhandfix|aimspawn|aimaxis <item> x y z|"
                   @"aimreticle|aimreticlerange|aimreticlescale|"
                   @"lenstint|lensscale|lenszfar|lensworld|lensdist|wheelhalo|"
                   @"velsource|velcutoff|velbeta|veldcutoff|crouch V";
        }
        usleep(40 * 1000); // published matrices are one compositor frame behind
        return [NSString
            stringWithFormat:@"ok vr set %@=%.3f scale=%.2f height=%.3f near=%.1f far=%.1f rendezvous_ms=%.1f "
                             @"flatworld=%d hostdiv=%d(eff %d) eyescale=%.2f eyebudget=%.0f engine_eye_fb=%dx%d "
                             @"roommode=%d",
                             k, v, sohvr_scale, sohvr_height, sohvr_near, sohvr_far, sohvr_rendezvousMs,
                             sohvr_flatWorldBackdrop, sohvr_hostDiv, sohvr_hostDivEff, sohvr_eyeScale,
                             sohvr_eyeBudget, gSoh3DEyeW, gSoh3DEyeH, gSohVRRoomMode];
    }
    if ([sub isEqualToString:@"hudprobe"]) {
        // R7 verdict 7: what is ACTUALLY in the HUD framebuffer. See
        // sohvr_probe_hud for why this exists and what its numbers mean.
        if (!gSohVRRunning) {
            return @"err vr hudprobe needs the VR loop running (`vr on`)";
        }
        sohvr_hudProbeDone = 0;
        sohvr_hudProbeReq = 1;
        for (int i = 0; i < 300 && !sohvr_hudProbeDone; i++) {
            usleep(10 * 1000);
        }
        if (!sohvr_hudProbeDone) {
            return @"err vr hudprobe timed out";
        }
        return [NSString
            stringWithFormat:@"ok vr_hudprobe texels=%u a_nonzero=%u rgb_nonzero=%u a_mean=%u rgb_mean=%u "
                              "probes=%llu hud_frames=%d hud_presents=%llu file=Documents/vr-hud.png seq=%llu",
                             sohvr_hudProbeTexels, sohvr_hudProbeANonzero, sohvr_hudProbeRGBNonzero,
                             sohvr_hudProbeAMean, sohvr_hudProbeRGBMean, (unsigned long long)sohvr_hudProbes,
                             gSohVRHudFrames, (unsigned long long)sohvr_hudPresents,
                             (unsigned long long)(++sohvr_dumpSeq)];
    }
    if ([sub isEqualToString:@"eyedump"]) {
        if (!gSohVRRunning) {
            return @"err vr eyedump needs the VR loop running (`vr on`)";
        }
        sohvr_captureDone = 0;
        sohvr_captureReq = 1;
        for (int i = 0; i < 300 && !sohvr_captureDone; i++) {
            usleep(10 * 1000);
        }
        if (!sohvr_captureDone) {
            return @"err vr eyedump timed out";
        }
        return [NSString stringWithFormat:@"ok vr_eyedump eye0=%dx%d hash0=0x%08x mean0=%u eye1=%dx%d hash1=0x%08x "
                                           "mean1=%u differ=%d files=Documents/vr-eye0.png,vr-eye1.png seq=%llu",
                                          sohvr_captureW[0], sohvr_captureH[0], sohvr_captureHash[0],
                                          sohvr_captureMean[0], sohvr_captureW[1], sohvr_captureH[1],
                                          sohvr_captureHash[1], sohvr_captureMean[1],
                                          (int)(sohvr_captureHash[0] != sohvr_captureHash[1] &&
                                                sohvr_captureHash[0] != 0 && sohvr_captureHash[1] != 0),
                                          (unsigned long long)(++sohvr_dumpSeq)];
    }
    return @"err usage: vr [pose|mode|contract|depth|pace|room|selftest|recenter|recalibrate|on|off|"
           @"space A|B|VR|style mixed|full|world on|off|settings 0|1|2|3|inject X Y Z YAW PITCH|inject off|"
           @"set scale|height|near|far|rendezvous|flatworld|hostdiv|eyescale|eyebudget|roommode|hudplane|"
           @"huddist|hudsize|hudup|hudkey|turn|turnspeed|hidebody|followhead|lefthanded|gripspace|eyeoffset|"
           @"fpforward|fpfar|slasharc|slashdown|slashreach|slashsecs|slashdrop|slashhold|slashback|"
           @"jumparc|jumpsecs|jumpreach|"
           @"hammerarc|hammerdown|hammerreach|hammerdrop|hammersecs|hammerhold|hammerback|hammerprobe|crouch V|"
           @"eyedump|hudprobe|sky|handcal|itemcal [item y p r [x y z]]|aim|forcesword|audio|atk stab|chop|hammer|crouch 0|1|auto|flip back|roll|off|auto|"
           @"ocarina 0|1|auto|shieldstance 0|1|auto|sdlpads|sensename NAME|lens]";
}
