// Copyright 2026 Ahimsa Labs
// SPDX-License-Identifier: Apache-2.0

import VNCCore
import Foundation
import Metal
import MetalKit

/// Draws the framebuffer texture into the view. Downscaling uses an N×N box filter of bilinear taps so large
/// remote desktops (5K, 6K) stay legible in small windows; integer upscales use nearest-neighbor to stay crisp.
final class Renderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var dstOrigin: SIMD2<Float>
        var dstSize: SIMD2<Float>
        var srcOrigin: SIMD2<Float>
        var ratio: SIMD2<Float>
        var background: SIMD4<Float>
        var smooth: Int32
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cached: (fb: ObjectIdentifier, texture: MTLTexture)?

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Renderer.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vncx_vertex")
            desc.fragmentFunction = library.makeFunction(name: "vncx_fragment")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("vncx: failed to build Metal pipeline: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let rv = view as? RemoteView,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer() else { return }
        encode(rv, pass: pass, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Renders synchronously into an arbitrary texture (used for debug captures).
    func render(view rv: RemoteView, into target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = rv.clearColor
        guard let cmd = queue.makeCommandBuffer() else { return }
        encode(rv, pass: pass, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func encode(_ rv: RemoteView, pass: MTLRenderPassDescriptor, cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let fb = rv.framebuffer, let tex = texture(for: fb) {
            let layout = rv.currentLayout()
            let bs = Float(rv.backingScale)
            let scale = Float(layout.scale) * bs // drawable pixels per framebuffer pixel
            var u = Uniforms(
                dstOrigin: SIMD2(Float(layout.dst.minX) * bs, Float(layout.dst.minY) * bs),
                dstSize: SIMD2(Float(layout.dst.width) * bs, Float(layout.dst.height) * bs),
                srcOrigin: SIMD2(Float(layout.srcOrigin.x), Float(layout.srcOrigin.y)),
                ratio: SIMD2(repeating: 1 / scale),
                background: rv.backgroundRGBA,
                smooth: rv.smoothScaling ? 1 : 0)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    private func texture(for fb: Framebuffer) -> MTLTexture? {
        let id = ObjectIdentifier(fb)
        if let cached, cached.fb == id { return cached.texture }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: fb.width, height: fb.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = fb.buffer.makeTexture(descriptor: desc, offset: 0, bytesPerRow: fb.bytesPerRow) else { return nil }
        cached = (id, tex)
        return tex
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 dstOrigin;
        float2 dstSize;
        float2 srcOrigin;
        float2 ratio;      // framebuffer pixels per drawable pixel
        float4 background;
        int smooth;
    };

    vertex float4 vncx_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    fragment float4 vncx_fragment(float4 pos [[position]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]]) {
        float2 p = pos.xy - u.dstOrigin;
        if (p.x < 0.0 || p.y < 0.0 || p.x >= u.dstSize.x || p.y >= u.dstSize.y) {
            return u.background;
        }
        float2 ts = float2(tex.get_width(), tex.get_height());
        float2 src = u.srcOrigin + p * u.ratio;
        constexpr sampler nearest(coord::normalized, filter::nearest, address::clamp_to_edge);
        constexpr sampler linear(coord::normalized, filter::linear, address::clamp_to_edge);

        float2 inv = 1.0 / u.ratio;
        bool integerUpscale = all(abs(inv - round(inv)) < 0.001);
        if (u.smooth == 0 || integerUpscale) {
            return float4(tex.sample(nearest, src / ts).rgb, 1.0);
        }
        if (u.ratio.x <= 1.0 && u.ratio.y <= 1.0) {
            return float4(tex.sample(linear, src / ts).rgb, 1.0);
        }
        // Downscale: average an n×n grid of bilinear taps covering this output pixel's footprint.
        int2 n = int2(clamp(ceil(u.ratio), float2(1.0), float2(8.0)));
        float2 stepv = u.ratio / float2(n);
        float2 start = src - 0.5 * u.ratio + 0.5 * stepv;
        float3 acc = float3(0.0);
        for (int y = 0; y < n.y; y++) {
            for (int x = 0; x < n.x; x++) {
                acc += tex.sample(linear, (start + float2(x, y) * stepv) / ts).rgb;
            }
        }
        return float4(acc / float(n.x * n.y), 1.0);
    }
    """
}
