// Тестовый вершинный шейдер для screenspace_general ($vertexshader): передаёт цвет вершины и UV.
// Матрица — стандартная константа Source cViewProj в регистре c8 (меш Lua рисуется в мировых координатах).
float4x4 cViewProj : register(c8);

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
    o.pos = mul(float4(i.pos.xyz, 1), cViewProj);
    o.uv = i.uv;
    o.col = i.col;
    return o;
}
