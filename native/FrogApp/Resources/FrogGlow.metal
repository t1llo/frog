// The light inside Frog's glass, drawn by `FrogGlow` (Views/Design/FrogGlow.swift) as a SwiftUI colour effect.
// It returns a premultiplied colour over a clear layer: a soft glow in the accent's colours and a glare on the
// rim nearest the light. Everything is computed per pixel, so it costs no textures and no CPU work per frame.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float hash(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

static float noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
}

static float fbm(float2 p) {
    float value = 0, amplitude = 0.5;
    for (int octave = 0; octave < 4; octave++) {
        value += amplitude * noise(p);
        p = p * 2.03 + 17.0;
        amplitude *= 0.5;
    }
    return value;
}

/// Signed distance from `p` to the edge of a rounded rectangle centred on the origin: negative inside.
static float roundedBox(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

/// - size: the layer in points. time: seconds, for the drift. style: 0 halo, 1 aurora, 2 prism.
/// - first, second, third: the accent and two neighbouring hues. light: where the light is, 0 to 1 across the layer.
/// - strength: 0 to 1. radius: the surface's corner radius. rim: how much glare the edge takes, 0 to 1.
/// - dark: 1 in dark mode, where light adds; 0 in light mode, where it tints.
[[ stitchable ]] half4 frogGlow(float2 position, half4 color, float2 size, float time, float style,
                                half4 first, half4 second, half4 third, float2 light, float strength,
                                float radius, float rim, float dark) {
    float extent = max(max(size.x, size.y), 1.0);
    float2 uv = position / extent;
    float2 lightPoint = light * size;
    float lightDistance = distance(position, lightPoint) / extent;
    float3 a = float3(first.rgb), b = float3(second.rgb), c = float3(third.rgb);

    float3 glowColor;
    float glowAlpha;
    if (style < 0.5) {
        // Halo: one wide light in the accent, whitened at its heart, and a faint counter-light in the second hue.
        float bloom = exp(-lightDistance * lightDistance * 6.0);
        float core = exp(-lightDistance * lightDistance * 30.0);
        float back = exp(-pow(distance(position, (1.0 - light) * size) / extent, 2.0) * 5.0) * 0.4;
        float3 lit = mix(a, float3(1.0), core * 0.5);
        float total = bloom * 0.75 + back;
        glowColor = (lit * bloom * 0.75 + b * back) / max(total, 1e-3);
        glowAlpha = total;
    } else if (style < 1.5) {
        // Aurora: three soft ribbons of the hues, waving slowly across the surface, brighter near the light.
        float t = time * 0.18;
        float x = uv.x * 2.4;
        float3 sum = float3(0);
        float weight = 0;
        for (int ribbon = 0; ribbon < 3; ribbon++) {
            float r = float(ribbon);
            float wave = 0.22 + r * 0.2 + 0.12 * sin(x * (0.9 + r * 0.35) + t * (1.0 + r * 0.3) + r * 2.1)
                + 0.08 * sin(x * 2.3 - t * 0.7 + r) + (noise(float2(x * 0.8 + t * 0.3, r * 7.0)) - 0.5) * 0.12;
            float y = position.y / max(size.y, 1.0);
            float width = 0.13 + 0.05 * sin(x * 1.3 + t + r * 4.0);
            float intensity = exp(-pow((y - wave) / width, 2.0)) * (0.75 + 0.25 * sin(x * 3.1 + t * 1.7 + r * 3.0));
            float3 hue = ribbon == 0 ? a : (ribbon == 1 ? b : c);
            sum += hue * intensity;
            weight += intensity;
        }
        float bloom = exp(-lightDistance * lightDistance * 5.0);
        glowColor = mix(sum / max(weight, 1e-3), float3(1.0), bloom * 0.15);
        glowAlpha = min(weight, 1.0) * 0.7 + bloom * 0.18;
    } else {
        // Prism: thin-film colours that shift with the light, and a bright sheen through it.
        float t = time * 0.05;
        float2 direction = normalize(float2(0.8, 0.6));
        float phase = dot(uv, direction) * 0.9 + lightDistance * 1.3 + fbm(uv * 2.5 + t) * 0.6 - t;
        float3 film = 0.5 + 0.5 * cos(6.2831853 * (phase + float3(0.0, 0.33, 0.67)));
        film = mix(film, a, 0.3);
        float across = dot(position - lightPoint, direction) / extent;
        float sheen = exp(-across * across * 14.0);
        glowColor = mix(film, float3(1.0), sheen * 0.3);
        glowAlpha = 0.16 + sheen * 0.36;
    }

    // Glare: a hairline and a soft inner glow along the edge, strongest on the side facing the light.
    float2 halfSize = size * 0.5;
    float inside = max(-roundedBox(position - halfSize, halfSize, radius), 0.0);
    float edge = exp(-inside / 1.1) * 0.85 + exp(-inside / 10.0) * 0.22;
    float facing = exp(-lightDistance * lightDistance * 2.5);
    float glare = edge * (0.12 + 0.88 * facing) * rim;
    float3 glareColor = mix(a, float3(1.0), dark > 0.5 ? 0.7 : 0.15);

    float amount = clamp(strength, 0.0, 1.0);
    float glowOpacity = clamp(glowAlpha * amount * (dark > 0.5 ? 0.85 : 0.75), 0.0, 0.6);
    float glareOpacity = clamp(glare * amount * (dark > 0.5 ? 1.0 : 0.7), 0.0, 1.0);
    float3 premultiplied = glowColor * glowOpacity * (1.0 - glareOpacity) + glareColor * glareOpacity;
    float alpha = glowOpacity + glareOpacity * (1.0 - glowOpacity);
    // A little noise keeps the soft gradients from banding.
    float dither = (hash(position + fract(time)) - 0.5) / 255.0 * step(0.001, alpha);
    return half4(half3(max(premultiplied + dither, 0.0)), half(alpha));
}
