#version 460 core
#include <flutter/runtime_effect.glsl>

out vec4 fragColor;

// 0, 1: Viewport Size
uniform vec2 uSize;
// 2..5: Lift (R, G, B, Master Y)
uniform vec4 uLift;
// 6..9: Gamma (R, G, B, Master Y)
uniform vec4 uGamma;
// 10..13: Gain (R, G, B, Master Y)
uniform vec4 uGain;
// 14..17: Offset (R, G, B, Master Y)
uniform vec4 uOffset;

// 18..26: Primary Adjustments
uniform float uContrast;
uniform float uPivot;
uniform float uSaturation;
uniform float uTemp;
uniform float uTint;
uniform float uColorBoost;
uniform float uShadows;
uniform float uHighlights;
uniform float uLumMix;

// 27..30: Color Science (CST) & LUT Engine
uniform float uInputCST;     // 0=Rec709, 1=Sony S-Log3, 2=ARRI LogC3, 3=DJI D-Log, 4=Linear RAW
uniform float uOutputCST;    // 0=Rec709, 1=sRGB, 2=DaVinci Wide Gamut, 3=ACEScct, 4=Rec2020 HLG
uniform float uLutPreset;    // 0=None, 1=Kodak 2383, 2=Fuji 3513, 3=Teal & Orange, 4=Bleach Bypass
uniform float uLutStrength;

// 31..37: 3D HSL Qualifier
uniform float uQualEnabled;
uniform float uQualHueCenter;
uniform float uQualHueWidth;
uniform float uQualSoftness;
uniform float uQualSatMin;
uniform float uQualLumMin;
uniform float uShowMatte;

// 38..44: Power Window (Circular/Elliptical Mask)
uniform float uWinEnabled;
uniform float uWinCenterX;
uniform float uWinCenterY;
uniform float uWinRadiusX;
uniform float uWinRadiusY;
uniform float uWinFeather;
uniform float uWinInvert;

// 45..46: Viewport Split Wipe & Global Bypass
uniform float uSplitWipe;
uniform float uBypass;

uniform sampler2D uTexture;

const vec3 REC709_LUMA = vec3(0.2126, 0.7152, 0.0722);

// --- 1. INPUT COLOR SPACE TRANSFORM (Log to Working Linear/DWG) ---
vec3 applyInputCST(vec3 c, float mode) {
    c = max(c, vec3(0.0));
    if (mode > 0.5 && mode < 1.5) {
        // Sony S-Log3 to Linear
        vec3 lin;
        for (int i = 0; i < 3; i++) {
            if (c[i] >= 171.2102946929 / 1023.0) {
                lin[i] = pow(10.0, ((c[i] * 1023.0 - 420.0) / 261.5)) * (0.18 + 0.01) - 0.01;
            } else {
                lin[i] = (c[i] * 1023.0 - 95.0) * 0.01125000 / (171.2102946929 - 95.0);
            }
        }
        return clamp(pow(max(lin, vec3(0.0)), vec3(1.0 / 2.2)), 0.0, 2.0);
    } else if (mode >= 1.5 && mode < 2.5) {
        // ARRI LogC3 to Graded Normalized Space
        vec3 lin = (pow(vec3(10.0), (c - 0.385537) / 0.2471896) - 0.052272) / 5.555556;
        return clamp(pow(max(lin, vec3(0.0)), vec3(1.0 / 2.2)), 0.0, 2.0);
    } else if (mode >= 2.5 && mode < 3.5) {
        // DJI D-Log
        vec3 lin = (pow(vec3(10.0), (c - 0.584555) / 0.256663) - 0.0108) / 0.9892;
        return clamp(pow(max(lin, vec3(0.0)), vec3(1.0 / 2.2)), 0.0, 2.0);
    } else if (mode >= 3.5) {
        // Linear RAW to Gamma 2.2 working state
        return pow(max(c, vec3(0.0)), vec3(1.0 / 2.2));
    }
    return c;
}

// --- 2. RGB <-> HSV CONVERSION FOR 3D QUALIFIER ---
vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// --- 3. FILM EMULATION LUT ENGINE ---
vec3 applyFilmLUT(vec3 c, float preset) {
    if (preset < 0.5) return c;
    float luma = dot(c, REC709_LUMA);
    if (preset < 1.5) {
        // Kodak 2383 Print Film Emulation (Dense blacks, warm highlights, rich cobalt blues)
        vec3 sCurve = smoothstep(0.02, 0.98, c);
        vec3 shadowTint = vec3(0.95, 0.98, 1.05);
        vec3 highTint = vec3(1.06, 1.01, 0.92);
        vec3 graded = mix(sCurve * shadowTint, sCurve * highTint, luma);
        graded.r = pow(max(graded.r, 0.0), 0.95);
        return graded;
    } else if (preset < 2.5) {
        // Fujifilm 3513 (Soft emerald greens, creamy highlights)
        vec3 sCurve = mix(c, smoothstep(0.0, 1.0, c), 0.45);
        sCurve.g = pow(max(sCurve.g, 0.0), 0.94);
        sCurve.b = sCurve.b * 0.96 + 0.02;
        return sCurve;
    } else if (preset < 3.5) {
        // Hollywood Teal & Orange Blockbuster Look
        vec3 shadows = vec3(0.0, 0.12, 0.18) * (1.0 - luma);
        vec3 highs = vec3(0.16, 0.08, -0.05) * luma;
        return clamp(c + shadows + highs, 0.0, 1.0);
    } else {
        // Bleach Bypass (Silver Retention Look - High contrast, desaturated metallic tone)
        vec3 gray = vec3(luma);
        vec3 desat = mix(c, gray, 0.65);
        vec3 overlay = mix(2.0 * desat * gray, 1.0 - 2.0 * (1.0 - desat) * (1.0 - gray), step(0.5, gray));
        return clamp(overlay, 0.0, 1.0);
    }
}

// --- 4. OUTPUT COLOR SPACE TRANSFORM ---
vec3 applyOutputCST(vec3 c, float mode) {
    c = max(c, vec3(0.0));
    if (mode > 0.5 && mode < 1.5) {
        // sRGB Display Transfer
        return pow(c, vec3(1.0 / 1.05));
    } else if (mode >= 1.5 && mode < 2.5) {
        // DaVinci Wide Gamut Log Preview
        return log2(c * 5.5 + 1.0) / 2.8;
    } else if (mode >= 2.5 && mode < 3.5) {
        // ACEScct RRT+ODT Approximation (Filmic Toe & Shoulder Roll-off)
        vec3 x = max(vec3(0.0), c - 0.004);
        return (x * (6.2 * x + 0.5)) / (x * (6.2 * x + 1.7) + 0.06);
    } else if (mode >= 3.5) {
        // Rec.2020 HLG (Hybrid Log-Gamma HDR)
        return pow(c, vec3(0.82));
    }
    return clamp(c, 0.0, 1.0);
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uSize;
    vec4 texColor = texture(uTexture, uv);
    vec3 origColor = texColor.rgb;

    // Split-Screen Wipe & Global Bypass Check
    if (uBypass > 0.5 || uv.x < uSplitWipe) {
        if (abs(uv.x - uSplitWipe) < 0.0025 && uSplitWipe > 0.01) {
            fragColor = vec4(1.0, 0.35, 0.1, 1.0); // DaVinci Orange Split Line
            return;
        }
        fragColor = vec4(origColor, texColor.a);
        return;
    }

    // Step 1: Input CST
    vec3 color = applyInputCST(origColor, uInputCST);

    // Step 2: White Balance (Temp & Tint Chromatic Adaptation)
    color.r += uTemp * 0.25;
    color.b -= uTemp * 0.25;
    color.g -= uTint * 0.25;
    color.r += uTint * 0.08;
    color.b += uTint * 0.08;

    // Step 3: DaVinci Resolve Primary Wheels (Lift, Gamma, Gain, Offset) + Lum Mix
    vec3 liftVec = uLift.rgb + vec3(uLift.a);
    vec3 gammaVec = max(vec3(0.05), vec3(1.0) + uGamma.rgb + vec3(uGamma.a));
    vec3 gainVec = max(vec3(0.0), vec3(1.0) + uGain.rgb + vec3(uGain.a));
    vec3 offsetVec = uOffset.rgb + vec3(uOffset.a);

    float inLuma = dot(color, REC709_LUMA);
    // Apply Lift: C_lifted = C + Lift * (1 - C)
    vec3 lifted = color + liftVec * (1.0 - color);
    // Apply Gain & Offset: C_gained = C_lifted * Gain + Offset
    vec3 gained = lifted * gainVec + offsetVec;
    // Apply Gamma: C_out = max(C_gained, 0)^(1 / Gamma)
    vec3 gradedPrimaries = pow(max(gained, vec3(0.0)), 1.0 / gammaVec);

    // Lum Mix (Balances RGB independent grading vs Y-channel luminance preservation)
    float outLuma = dot(gradedPrimaries, REC709_LUMA);
    float targetLuma = inLuma + uLift.a * (1.0 - inLuma);
    targetLuma = pow(max(targetLuma * (1.0 + uGain.a) + uOffset.a, 0.0), 1.0 / max(0.05, 1.0 + uGamma.a));
    vec3 lumaPreserved = gradedPrimaries * (targetLuma / max(outLuma, 0.0001));
    color = mix(lumaPreserved, gradedPrimaries, uLumMix);

    // Step 4: Contrast & Pivot (True S-Curve around Pivot)
    float pivot = clamp(uPivot, 0.05, 0.95);
    vec3 safeColor = max(color, vec3(0.0001));
    vec3 contrasted = pow(safeColor / pivot, vec3(uContrast)) * pivot;
    color = mix(color, contrasted, 1.0);

    // Step 5: HDR Shadows & Highlights Recovery
    float curLuma = dot(color, REC709_LUMA);
    float shadowWeight = pow(1.0 - clamp(curLuma, 0.0, 1.0), 2.2);
    float highWeight = pow(clamp(curLuma, 0.0, 1.0), 2.2);
    color += color * uShadows * shadowWeight * 1.2;
    color += color * uHighlights * highWeight * 0.8;

    // Step 6: Saturation & Color Boost (Skin-Tone Protected Vibrance)
    float lumaAfter = dot(color, REC709_LUMA);
    vec3 chroma = color - vec3(lumaAfter);
    float currentSat = length(chroma);
    // Color Boost affects low-saturation areas more than already-saturated areas
    float boostFactor = 1.0 + uColorBoost * (1.0 - clamp(currentSat * 2.5, 0.0, 1.0));
    color = vec3(lumaAfter) + chroma * uSaturation * boostFactor;

    // Step 7: Film LUT Application
    vec3 lutColor = applyFilmLUT(clamp(color, 0.0, 1.0), uLutPreset);
    color = mix(color, lutColor, uLutStrength);

    // Step 8: Output CST
    color = applyOutputCST(color, uOutputCST);

    // Step 9: Compute Node Mask (3D HSL Qualifier & Power Window)
    float mask = 1.0;

    if (uQualEnabled > 0.5) {
        vec3 hsv = rgb2hsv(clamp(origColor, 0.0, 1.0));
        float origLuma = dot(origColor, REC709_LUMA);
        // Circular Hue Distance (0..0.5)
        float hueDiff = abs(hsv.x - uQualHueCenter);
        hueDiff = min(hueDiff, 1.0 - hueDiff);
        float hueMask = 1.0 - smoothstep(uQualHueWidth * 0.5, uQualHueWidth * 0.5 + max(0.005, uQualSoftness), hueDiff);
        float satMask = smoothstep(uQualSatMin - 0.05, uQualSatMin + 0.05, hsv.y);
        float lumMask = smoothstep(uQualLumMin - 0.05, uQualLumMin + 0.05, origLuma);
        mask *= (hueMask * satMask * lumMask);
    }

    if (uWinEnabled > 0.5) {
        vec2 d = (uv - vec2(uWinCenterX, uWinCenterY)) / max(vec2(0.01), vec2(uWinRadiusX, uWinRadiusY));
        float dist = length(d);
        float winMask = 1.0 - smoothstep(1.0 - uWinFeather, 1.0 + uWinFeather, dist);
        if (uWinInvert > 0.5) {
            winMask = 1.0 - winMask; // Outside Node
        }
        mask *= winMask;
    }

    // Highlight Matte View (Like Shift+H in DaVinci Resolve)
    if (uShowMatte > 0.5) {
        vec3 matteView = mix(vec3(0.18), color, mask);
        fragColor = vec4(matteView, 1.0);
        return;
    }

    // Final Blend between Input & Graded Node Output via Mask
    vec3 finalRGB = mix(origColor, clamp(color, 0.0, 1.0), mask);
    fragColor = vec4(finalRGB, texColor.a);
}
