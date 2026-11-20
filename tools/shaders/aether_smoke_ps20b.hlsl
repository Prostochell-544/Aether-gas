// «Ультра»: пиксельный шейдер облаков Aether — мягкие частицы по глубине кадра и течение рисунка клубов.
// Регистры GMod: s0 — $basetexture (атлас клубов smoke_puff4, 4×4), s1 — $texture1 (_rt_ResolvedFullFrameDepth,
// глубина сцены в альфе — проверено в игре); c0 — $c0_x..$c0_w:
//   c0.x — сколько юнитов соответствует альфе 1.0 в текстуре глубины (у Source ≈ 192, ConVar aether_ultra_depth);
//   c0.y — 1 / ширина затухания у поверхности, юниты (ConVar aether_ultra_fade);
//   c0.zw — полтекселя экрана (0.5/ширина, 0.5/высота): выборка D3D9 по центру пикселя.
// Клуб гаснет попиксельно там, где за ним близко поверхность (глубина сцены − глубина клуба → 0): ни линии
// пересечения с полом и стенами, ни среза.
// Течение: рисунок внутри клуба смещается связным полем по мировым координатам (TEXCOORD2.xyz) со временем
// (TEXCOORD2.w — уже умноженное на силу движения): клубы «клубятся». Выборка не выходит за свою ячейку атласа.
sampler TexBase  : register(s0);
sampler TexDepth : register(s1);
float4 C0 : register(c0);

struct PS_IN
{
    float2 uv   : TEXCOORD0;
    float4 proj : TEXCOORD1;
    float4 flow : TEXCOORD2;
    float4 col  : COLOR0;
};

float4 main(PS_IN i) : COLOR
{
    // течение рисунка в пределах ячейки атласа (ячейка 0.25, смещение до ~0.018 — 7 % ячейки)
    float3 w = i.flow.xyz * 0.045;
    float t = i.flow.w;
    float2 fl = float2(sin(w.y + w.z + t * 0.35), cos(w.x - w.z + t * 0.3)) * 0.018 * saturate(abs(t) * 1000);
    float2 cell = floor(i.uv * 4) * 0.25;
    float2 uv = clamp(i.uv + fl, cell + 0.004, cell + 0.246);
    float4 tx = tex2D(TexBase, uv);

    float2 suv = i.proj.xy / i.proj.w * float2(0.5, -0.5) + 0.5 + C0.zw;
    // Глубина в альфе насыщается на C0.x юнитах: дальше поверхность считаем бесконечно далёкой,
    // иначе всё облако дальше этого диапазона пропало бы.
    float a = tex2D(TexDepth, suv).a;
    float scene = a > 0.97 ? 1e6 : a * C0.x;
    float soft = saturate((scene - i.proj.w) * C0.y);
    return float4(i.col.rgb * tx.rgb, i.col.a * tx.a * soft);
}
