// Тестовый вершинный шейдер для screenspace_general ($vertexshader): передаёт цвет вершины и UV.
// Матрица — стандартная константа Source cModelViewProj в регистре c4 (common_vs_fxc.h).
float4x4 cModelViewProj : register(c4);

struct VS_IN
{
    float4 pos : POSITION;
    float4 col : COLOR0;
    float2 uv  : TEXCOORD0;
};

struct VS_OUT
{
    float4 pos : POSITION;
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
};

VS_OUT main(VS_IN i)
{
    VS_OUT o;
    o.pos = mul(float4(i.pos.xyz, 1), cModelViewProj);
    o.uv = i.uv;
    o.col = i.col;
    return o;
}
