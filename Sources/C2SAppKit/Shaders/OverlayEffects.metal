//
//  OverlayEffects.metal
//  切片 E(F14):四点渐变微光 + 出现涟漪(ui-style §4.2/§5,机制 §8)。
//  两个 [[stitchable]] 函数,Swift 侧经 ShaderLibrary.bundle(.module) 取用。
//  坐标纪律:position/origin/tipPoint 均为覆盖层点坐标(左上原点)。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// 品牌四色(仅微光可用,ui-style §1.3)
constant float3 kC2SBrand[4] = {
    float3(0.259, 0.522, 0.957), // Blue   #4285F4
    float3(0.918, 0.263, 0.208), // Red    #EA4335
    float3(0.984, 0.737, 0.020), // Yellow #FBBC05
    float3(0.204, 0.659, 0.325), // Green  #34A853
};

// 各色点的 Lissajous 参数(uv 空间;频率互不成简单整数比,避免轨迹同步)
constant float2 kC2SCenter[4] = {
    float2(0.28, 0.30), float2(0.74, 0.26), float2(0.30, 0.74), float2(0.72, 0.72),
};
constant float2 kC2SRadius[4] = {
    float2(0.21, 0.19), float2(0.18, 0.17), float2(0.19, 0.18), float2(0.20, 0.16),
};
constant float2 kC2SFreq[4] = {
    float2(0.42, 0.31), float2(0.33, 0.47), float2(0.51, 0.37), float2(0.29, 0.53),
};
constant float2 kC2SPhase[4] = {
    float2(0.0, 1.7), float2(2.1, 0.4), float2(4.2, 2.6), float2(1.0, 3.9),
};

/// 单个色点的 Lissajous 游走 + 高频微抖("android wiggle",机制 §8;返回 uv 空间位置)。
/// 微抖让慢速大轨道之上始终有肉眼可感的生命感(2026-07-03 实机反馈:纯慢轨道看着像静止)。
static inline float2 c2s_lissajous(float t, int i) {
    const float2 base = kC2SCenter[i] + kC2SRadius[i] * float2(sin(t * kC2SFreq[i].x + kC2SPhase[i].x),
                                                               cos(t * kC2SFreq[i].y + kC2SPhase[i].y));
    const float fi = float(i);
    const float2 wiggle = 0.028f * float2(sin(t * 1.9f + fi * 2.1f) + 0.5f * sin(t * 3.1f + fi),
                                          cos(t * 2.3f + fi * 1.3f) + 0.5f * cos(t * 2.9f + fi * 0.7f));
    return base + wiggle;
}

/// colorEffect:AE "4-Color Gradient" —— 4 个色点慢速游走,逐像素按距离高斯加权混色。
/// trackingAmount 0→1:色点位置向 tipPoint 收敛、spread 0.12→0.05 收窄 → 笔尖单点辉光。
/// saturation 0→1:与亮度灰阶混合(ambient 降饱和)。
/// opacity:显隐总闸,渐显 + bloom 亮度脉冲由 Swift 侧并入后传入。
[[stitchable]] half4 c2s_fourPointGradient(float2 position, half4 color,
                                           float2 size, float time,
                                           float trackingAmount, float2 tipPoint,
                                           float saturation, float opacity)
{
    // 尺寸退化保护:避免除零
    if (size.x < 1.0f || size.y < 1.0f) {
        return half4(0.0h);
    }

    const float t = time * 1.7f; // 速度系数(2026-07-03 实机调校:0.8 观感近似静止)
    const float ta = clamp(trackingAmount, 0.0f, 1.0f);

    // 除以 min(size) 归一化(保纵横比):q 空间下 spread 即「×min(size)」的比例
    const float minDim = min(size.x, size.y);
    const float2 q = position / minDim;
    const float2 tipQ = tipPoint / minDim;

    // spread ≈ 0.12×min(size) 起步,tracking 收窄到 ~0.06
    const float spread = mix(0.12f, 0.06f, ta);
    const float inv2s2 = 1.0f / (2.0f * spread * spread);

    // 逐点高斯加权(权重在 float 域计算,防 half 下溢)。
    // tracking 收敛目标不是笔尖「一个点」——四点重合会把四色平均成一团浑浊的
    // 均匀色(2026-07-03 实机反馈"光球没有渐变")——而是笔尖周围的小半径公转
    // 轨道(相位差 90°,持续旋转),光球内部保有流动的四色渐变。
    const float orbitR = 0.045f;
    float wSum = 0.0f;
    float3 mixRGB = float3(0.0f);
    for (int i = 0; i < 4; ++i) {
        float2 pq = c2s_lissajous(t, i) * size / minDim; // uv → q 空间
        const float ang = t * 2.6f + float(i) * 1.5708f; // 四点均布,绕笔尖公转
        const float2 orbit = tipQ + orbitR * float2(sin(ang), cos(ang));
        pq = mix(pq, orbit, ta);
        const float2 d = q - pq;
        const float w = exp(-dot(d, d) * inv2s2);
        wSum += w;
        mixRGB += w * kC2SBrand[i];
    }

    // 归一化混色(AE 4-Color Gradient 数学);远处权重齐零时退回四色均值,避免除零
    const float3 meanRGB = (kC2SBrand[0] + kC2SBrand[1] + kC2SBrand[2] + kC2SBrand[3]) * 0.25f;
    float3 rgb = (mixRGB + meanRGB * 1e-4f) / (wSum + 1e-4f);

    // ambient 降饱和:与亮度灰阶混合。
    // idle 额外过饱和 ×1.35(2026-07-03 实机:plusLighter 叠亮底会把颜色洗白,
    // 拉高色度才看得见四色);tracking(光球)保持 1.0 不动 —— 用户已认可其观感。
    const float luma = dot(rgb, float3(0.2126f, 0.7152f, 0.0722f));
    const float satBoost = mix(1.35f, 1.0f, ta);
    rgb = clamp(mix(float3(luma), rgb, clamp(saturation, 0.0f, 1.0f) * satBoost), 0.0f, 1.0f);

    // 亮度掩码:idle 有全屏底 + 近点增辉;tracking 时底归零 → 纯笔尖局部辉光
    // (2026-07-03 实机两轮:0.55×0.42 → 0.72×0.50 仍不够 → 底亮 0.85、层透明度 0.58;光球不动)
    const float glow = 1.0f - exp(-1.2f * wSum);
    const float base = mix(0.85f, 0.0f, ta);
    const float intensity = base + (1.0f - base) * glow;

    // 乘视图自身 alpha(遮罩/边缘);输出预乘 alpha,严格钳在 [0,1]
    const float a = clamp(intensity * max(opacity, 0.0f), 0.0f, 1.0f) * float(color.a);
    return half4(half3(rgb * a), half(a));
}

/// layerEffect:出现涟漪 —— 有机正弦波 × 指数衰减对采样位置做径向位移(苹果 ripple 数学)。
/// progress 0→1(约 1.1s 线性驱动);amplitude ~12px、frequency ~14、decay ~9(均以 progress 为单位)。
[[stitchable]] half4 c2s_ripple(float2 position, SwiftUI::Layer layer,
                                float2 origin, float progress,
                                float amplitude, float frequency, float decay)
{
    // 播放区间外恒等采样(Swift 侧 progress>=1 后会整体停用本效果)
    if (progress <= 0.0f || progress >= 1.0f) {
        return layer.sample(position);
    }

    const float2 delta = position - origin;
    const float dist = length(delta);

    // 波前以固定速度外扩(pt / progress 单位)。签名无 size,取覆盖典型全屏的常数:
    // progress=1 时波前已行进 2400pt,可扫过常见屏幕的大部分区域。
    const float kWaveSpeed = 2400.0f;
    const float tau = progress - dist / kWaveSpeed;
    if (tau <= 0.0f) {
        return layer.sample(position); // 波前未到,原样采样
    }

    // 位移 = 振幅 × sin(频率·τ) × e^(−衰减·τ);decay≈9 时 τ=1 已近零,自然收尾
    const float ripple = amplitude * sin(frequency * tau) * exp(-decay * tau);
    const float2 dir = (dist > 1e-3f) ? (delta / dist) : float2(0.0f);
    half4 c = layer.sample(position + dir * ripple);

    // 极轻的波峰增亮(ui-style §5「极轻」);预乘约束:各通道钳在 [0, alpha]
    const float highlight = 0.18f * (ripple / max(amplitude, 1e-3f));
    c.rgb = clamp(c.rgb + half(highlight) * c.a, 0.0h, c.a);
    return c;
}
