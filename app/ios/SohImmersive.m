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
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>

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
