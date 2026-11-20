// Диагностика на ps_2_b (пара со стандартным вершинным шейдером screenspace_general второй версии).
// Регистры GMod: s0 — $basetexture, s1 — $texture1; c0 — $c0_x..$c0_w.
//   c0.x — режим: 0 — глубина кадра (полноэкранный квад, TEXCOORD0 = UV экрана; s1 = _rt_ResolvedFullFrameDepth):
//                     глубина в альфе (проверено в игре): слева полосы frac(A·c0.y), справа сырая A;
//                  1 — тестовый квад в мире: слева цвет вершины (COLOR0), справа UV и альфа текстуры s0;
//                  2 — заливка ярко-пурпурным: шейдер вообще выполняется.
sampler TexBase  : register(s0);
sampler TexDepth : register(s1);
float4 C0 : register(c0);

struct PS_IN
{
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
};

float4 main(PS_IN i) : COLOR
{
    if (C0.x > 1.5)
        return float4(1, 0, 1, 1);
    if (C0.x < 0.5)
    {
        // калибровка: глубина — в альфе. Слева «линии уровня» frac(A·c0.y), справа сырая A.
        float a = tex2D(TexDepth, i.uv).a;
        float g = i.uv.x < 0.5 ? frac(a * C0.y) : a;
        return float4(g, g, g, 1);
    }
    float4 t = tex2D(TexBase, i.uv);
    if (i.uv.x < 0.5)
        return float4(i.col.rgb, 1);
    return float4(i.uv.x, i.uv.y, t.a, 1);
}
