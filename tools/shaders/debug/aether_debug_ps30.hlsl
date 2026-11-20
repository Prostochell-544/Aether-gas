// Диагностика пути «свой шейдер» в GMod (материал screenspace_general, $pixshader = aether_debug_ps30).
// Регистры GMod: s0 — $basetexture, s1 — $texture1; c0 — $c0_x..$c0_w.
//   c0.x — режим: 0 — глубина кадра (s1 = _rt_ResolvedFullFrameDepth): слева канал R, справа канал A, ×c0.y;
//                  1 — тестовый квад в мире: слева цвет вершины (COLOR0), справа UV и альфа текстуры s0.
//   c0.zw — 1/ширина, 1/высота экрана (VPOS → UV экрана).
sampler TexBase  : register(s0);
sampler TexDepth : register(s1);
float4 C0 : register(c0);

struct PS_IN
{
    float2 uv   : TEXCOORD0;
    float4 col  : COLOR0;
    float2 vpos : VPOS;
};

float4 main(PS_IN i) : COLOR
{
    float2 suv = (i.vpos + 0.5) * C0.zw;
    if (C0.x < 0.5)
    {
        float4 d = tex2D(TexDepth, suv) * C0.y;
        float g = suv.x < 0.5 ? d.r : d.a;
        return float4(g, g, g, 1);
    }
    float4 t = tex2D(TexBase, i.uv);
    if (i.uv.x < 0.5)
        return float4(i.col.rgb, 1);
    return float4(i.uv.x, i.uv.y, t.a, 1);
}
