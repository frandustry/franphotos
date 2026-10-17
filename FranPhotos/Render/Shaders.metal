#include <metal_stdlib>
using namespace metal;

struct EDRBlitOut {
    float4 position [[position]];
    float2 uv;
};

vertex EDRBlitOut edrBlitVS(uint vertexID [[vertex_id]]) {
    // Fullscreen triangle.
    float2 p = float2((vertexID << 1) & 2, vertexID & 2);
    EDRBlitOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 edrBlitFS(EDRBlitOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Source and destination share the extended-linear Display P3 space:
    // sample and write through unchanged so values > 1.0 reach the EDR layer.
    return tex.sample(s, in.uv);
}
