/// Metal shader source, compiled when the app starts (there's no Metal compiler without Xcode).
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Must match FrameUniforms in FrameLayout.swift.
    struct FrameUniforms {
        float4 background;
        float4 gradientA;
        float4 gradientB;
        float4 bgParams;     // kind, gradient angle
        float4 wallpaper0, wallpaper1, wallpaper2, wallpaper3;
        float4 contentRect;  // where the video sits on the canvas, 0–1, origin top-left
        float4 sourceRect;   // which part of the source frame to show, 0–1, origin top-left
        float4 shape;        // corner radius, shadow opacity, shadow blur, shadow offset (pixels)
        float4 canvas;       // canvas size in pixels
        float4 camera;       // part of the canvas in view (zoom), 0–1
    };

    // Must match CursorUniforms in CursorLayout.swift. Positions and sizes are in recording pixels.
    struct CursorUniforms {
        float4 position;    // xy = where the cursor is now, zw = where the motion blur starts
        float4 params;      // opacity (0 = not drawn), cell side, style (0 black, 1 white, 2 dot), blur samples
        float4 cell;        // the picture's place in the cursor texture, 0–1
        float4 hotspot;     // xy = hotspot as a fraction of the cell, z = click effect (0 none, 1 circle, 2 ripple), w = its radius
        float4 recording;   // xy = recording size, z = shadow strength, w = dot radius
        float4 dark;        // colour of the dark parts
        float4 light;       // colour of the light parts
        float4 dotFill;     // dot style's fill (with alpha)
        float4 clickColor;  // rgb + strength
        float4 clicks[4];   // xy = where, z = progress 0–1 (negative = none), w = strength of the faint dark edge
    };

    struct VOut { float4 position [[position]]; float2 uv; };

    // One triangle that covers the whole target.
    vertex VOut fullscreenVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Distance from point p to a rounded box (negative inside), in pixels.
    float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
        float2 q = abs(p) - halfSize + radius;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    }

    float4 backgroundColor(float2 uv, constant FrameUniforms &u, texture2d<float> image) {
        int kind = int(u.bgParams.x + 0.5);
        float2 size = u.canvas.xy;
        if (kind == 0) {
            // Wallpaper: four colours blended smoothly, one near each corner.
            float2 pts[4] = { float2(0.1, 0.1), float2(0.9, 0.15), float2(0.15, 0.9), float2(0.9, 0.85) };
            float4 cols[4] = { u.wallpaper0, u.wallpaper1, u.wallpaper2, u.wallpaper3 };
            float4 sum = 0.0; float total = 0.0;
            for (int i = 0; i < 4; i++) {
                float2 d = (uv - pts[i]) * float2(size.x / size.y, 1.0);
                float w = 1.0 / pow(dot(d, d) + 0.04, 1.6);
                sum += cols[i] * w; total += w;
            }
            return float4((sum / total).rgb, 1.0);
        }
        if (kind == 1) {
            float2 dir = float2(sin(u.bgParams.y), -cos(u.bgParams.y));
            float2 p = (uv - 0.5) * size;
            float t = dot(p, dir) / (abs(dir.x) * size.x + abs(dir.y) * size.y) + 0.5;
            return float4(mix(u.gradientA, u.gradientB, clamp(t, 0.0, 1.0)).rgb, 1.0);
        }
        if (kind == 3) {
            // The user's picture, scaled to fill the canvas.
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float imageAspect = float(image.get_width()) / float(image.get_height());
            float canvasAspect = size.x / size.y;
            float2 t = uv - 0.5;
            if (canvasAspect > imageAspect) { t.y *= imageAspect / canvasAspect; } else { t.x *= canvasAspect / imageAspect; }
            return float4(image.sample(s, t + 0.5).rgb, 1.0);
        }
        return float4(u.background.rgb, 1.0);
    }

    // Click effects: a circle that pops and fades, or a ring that spreads out. Drawn over the video, under the cursor.
    float3 drawClicks(float3 c, float2 p, float aa, constant CursorUniforms &u) {
        int kind = int(u.hotspot.z + 0.5);
        if (kind == 0) { return c; }
        float R = u.hotspot.w;
        for (int i = 0; i < 4; i++) {
            float4 k = u.clicks[i];
            if (k.z < 0.0) { continue; }
            float t = k.z;
            float e = 1.0 - pow(1.0 - t, 3.0);
            float fade = 1.0 - t;
            float d = length(p - k.xy);
            if (kind == 2) {
                float radius = R * (0.25 + 0.75 * e);
                float w = max(R * 0.14 * (1.0 - 0.5 * t), aa);
                float off = abs(d - radius);
                float ring = 1.0 - smoothstep(w * 0.5 - aa * 0.5, w * 0.5 + aa * 0.5, off);
                float edge = 1.0 - smoothstep(w * 0.5, w * 0.5 + max(R * 0.1, aa * 1.5), off);
                c = mix(c, float3(0.0), edge * k.w * fade);
                c = mix(c, u.clickColor.rgb, ring * u.clickColor.a * fade);
            } else {
                float radius = R * (0.5 + 0.5 * e);
                float disc = 1.0 - smoothstep(radius - aa * 0.5, radius + aa * 0.5, d);
                float edge = 1.0 - smoothstep(0.0, max(R * 0.1, aa * 1.5), abs(d - radius));
                c = mix(c, float3(0.0), edge * k.w * fade);
                c = mix(c, u.clickColor.rgb, disc * u.clickColor.a * 0.6 * fade);
            }
        }
        return c;
    }

    // The cursor, blended along its last bit of movement for motion blur (n copies).
    float3 drawCursor(float3 c, float2 p, float aa, float2 gx, float2 gy, constant CursorUniforms &u, texture2d<float> atlas) {
        float opacity = u.params.x;
        if (opacity <= 0.001) { return c; }
        float side = u.params.y;
        int style = int(u.params.z + 0.5);
        int n = max(int(u.params.w + 0.5), 1);
        float2 a = u.position.zw, b = u.position.xy;
        float2 lo = min(a, b) - side * 1.1, hi = max(a, b) + side * 1.1;
        if (any(p < lo) || any(p > hi)) { return c; }
        if (style == 2) {
            float r = u.recording.w, ringW = max(r * 0.19, aa);
            float fill = 0.0, whole = 0.0;
            for (int i = 0; i < n; i++) {
                float2 q = n == 1 ? b : mix(a, b, (float(i) + 0.5) / float(n));
                float d = length(p - q);
                fill += 1.0 - smoothstep(r - aa * 0.5, r + aa * 0.5, d);
                whole += 1.0 - smoothstep(r + ringW - aa * 0.5, r + ringW + aa * 0.5, d);
            }
            fill /= float(n); whole /= float(n);
            c = mix(c, u.light.rgb, max(whole - fill, 0.0) * opacity);
            return mix(c, u.dotFill.rgb, fill * u.dotFill.a * opacity);
        }
        constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float2 dx = gx / side * u.cell.zw, dy = gy / side * u.cell.zw;
        float4 acc = 0.0;
        for (int i = 0; i < n; i++) {
            float2 q = n == 1 ? b : mix(a, b, (float(i) + 0.5) / float(n));
            float2 local = (p - q) / side + u.hotspot.xy;
            if (all(local >= 0.0) && all(local <= 1.0)) {
                acc += atlas.sample(s, u.cell.xy + local * u.cell.zw, gradient2d(dx, dy));
            }
        }
        acc /= float(n);
        float dark = acc.r, body = max(acc.g, acc.r), shadow = acc.b * u.recording.z;
        float3 darkC = style == 1 ? u.light.rgb : u.dark.rgb;
        float3 lightC = style == 1 ? u.dark.rgb : u.light.rgb;
        c *= 1.0 - shadow * opacity;
        float3 premult = lightC * (body - dark) + darkC * dark;
        return c * (1.0 - body * opacity) + premult * opacity;
    }

    fragment float4 frameFragment(VOut in [[stage_in]],
                                  constant FrameUniforms &u [[buffer(0)]],
                                  constant CursorUniforms &cu [[buffer(1)]],
                                  texture2d<float> source [[texture(0)]],
                                  texture2d<float> backgroundImage [[texture(1)]],
                                  texture2d<float> cursorAtlas [[texture(2)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // The background zooms with everything else.
        float4 color = backgroundColor(u.camera.xy + in.uv * u.camera.zw, u, backgroundImage);

        // Geometry in canvas pixels.
        float2 px = in.uv * u.canvas.xy;
        float2 center = (u.contentRect.xy + u.contentRect.zw * 0.5) * u.canvas.xy;
        float2 halfSize = u.contentRect.zw * 0.5 * u.canvas.xy;
        float radius = min(u.shape.x, min(halfSize.x, halfSize.y));

        // Drop shadow: a softened copy of the rounded box, moved down.
        float blur = max(u.shape.z, 0.001);
        float shadowDistance = roundedBoxDistance(px - center - float2(0.0, u.shape.w), halfSize, radius);
        float shadow = u.shape.y * (1.0 - smoothstep(-blur * 0.6, blur * 0.6, shadowDistance));
        color.rgb *= (1.0 - shadow);

        // Where this pixel is in the recording (worked out for every pixel, so the cursor's sharpness
        // can be measured from neighbouring pixels).
        float2 local = clamp((in.uv - u.contentRect.xy) / u.contentRect.zw, 0.0, 1.0);
        float2 suv = u.sourceRect.xy + local * u.sourceRect.zw;
        float2 rec = suv * cu.recording.xy;
        float2 gx = dfdx(rec), gy = dfdy(rec);
        float aa = max(length(gx), length(gy));
        float2 footprint = fwidth(suv) * 0.25;

        // The video, with anti-aliased rounded corners (one pixel of softness).
        float inside = clamp(0.5 - roundedBoxDistance(px - center, halfSize, radius), 0.0, 1.0);
        if (inside > 0.0) {
            // When shrinking a big recording, average four samples so small text stays clean.
            float4 c = source.sample(s, suv + float2(-footprint.x, -footprint.y * 0.5))
                     + source.sample(s, suv + float2( footprint.x,  footprint.y * 0.5))
                     + source.sample(s, suv + float2( footprint.x * 0.5, -footprint.y))
                     + source.sample(s, suv + float2(-footprint.x * 0.5,  footprint.y));
            float3 video = (c * 0.25).rgb;
            // Cursor step: clicks and the cursor are drawn on the recording, so they follow crop and zoom.
            if (cu.params.x > 0.001) {
                video = drawClicks(video, rec, aa, cu);
                video = drawCursor(video, rec, aa, gx, gy, cu, cursorAtlas);
            }
            color.rgb = mix(color.rgb, video, inside);
        }
        return float4(color.rgb, 1.0);
    }
    """
}
