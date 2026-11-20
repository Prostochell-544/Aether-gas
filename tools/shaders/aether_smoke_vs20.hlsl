// «Ультра»: вершинный шейдер облаков Aether (screenspace_general, $vertexshader = aether_smoke_vs20).
// Стандартный вершинный шейдер screenspace_general не передаёт цвет вершины (проверено в игре), а в нём —
// освещение и прозрачность клуба. Здесь: UV и цвет как есть, клип-позиция для пиксельного шейдера (экранные UV
// и глубина клуба = w) и движение клубов.
//
// Движение: констант вершинному шейдеру GMod не передаёт, поэтому время t и сила движения a приходят через
// матрицу модели: Lua рисует облака под cam.PushModelMatrix(перенос (t, a, 0)). Меш построен в мировых
// координатах, позиция считается через cViewProj (c8, без модели), а разница cModelViewProj (c4, с моделью) и
// cViewProj в начале координат = t·VP[0] + a·VP[1] — решаем 2×2 и получаем t и a. Нет переноса — t = a = 0,
// облако неподвижно (откат без поломок).
// Поле смещений — сумма синусов по мировым координатам: соседние клубы движутся согласованно, каждый квад
// слегка деформируется (углы смещаются по-разному) — облако колышется и «дышит». Время периодично
// (Lua: t по модулю 2π·20), частоты кратны 0.05 — шов при переходе через период незаметен.
//
// Течение клубов: целая часть UV несёт код (cl_mesher.lua: FlowCode), дробная — UV атласа (0..1, код ×4 её
// не задевает). u: 1 + ix + 16·iy, v: 1 + iz + 16·фаза; скорость газа в ячейке = (i − 8)·FLOW_Q по осям.
// Код 0 — клуб без течения (у пола, вырожденный, меш без кодов). Клуб «едет» вдоль скорости на FLOW_L юнитов
// за цикл, появляясь и растворяясь (вес альфы 2·sin²(π·f)); фазы клубов ячейки сдвинуты на четверть (два
// клуба LOD — на половину), сумма весов постоянна — плотность облака не мигает, а рисунок течёт.
// Частота цикла округлена до целого числа циклов за период времени — без рывка при переходе через период.
float4x4 cModelViewProj : register(c4);
float4x4 cViewProj      : register(c8);

struct VS_IN
{
    float4 pos : POSITION;
    float4 col : COLOR0;
    float2 uv  : TEXCOORD0;
};

struct VS_OUT
{
    float4 pos  : POSITION;
    float2 uv   : TEXCOORD0;
    float4 proj : TEXCOORD1;   // клип-позиция: xy/w → экран, w → глубина вдоль взгляда (юниты)
    float4 flow : TEXCOORD2;   // xyz — мировая позиция (поле течения рисунка), w — время
    float4 col  : COLOR0;
};

static const float FLOW_Q = 12.0;            // юнит/с на шаг кода (cl_mesher.lua: FLOW_Q)
static const float FLOW_L = 30.0;            // путь клуба за цикл, юниты
static const float FLOW_SPEED = 0.5;         // видимая скорость течения — доля скорости газа (спокойнее)
static const float TIME_PERIOD = 125.66370614;   // 2π·20 (cl_mesher.lua: MOTION_PERIOD)

VS_OUT main(VS_IN i)
{
    VS_OUT o;
    // время и сила движения из матрицы модели
    float4 d = cModelViewProj[3] - cViewProj[3];
    float4 r0 = cViewProj[0], r1 = cViewProj[1];
    float g00 = dot(r0, r0), g01 = dot(r0, r1), g11 = dot(r1, r1);
    float b0 = dot(d, r0), b1 = dot(d, r1);
    float det = g00 * g11 - g01 * g01;
    float t = (b0 * g11 - b1 * g01) / det;
    float a = (g00 * b1 - g01 * b0) / det;

    // код течения из целой части UV
    float2 code = floor(i.uv * 0.25);
    float2 uv = i.uv - code * 4.0;
    float has = saturate(code.x);                // 0 — без течения
    float2 c = max(code - 1.0, 0.0);
    float2 hi = floor(c * 0.0625);               // c / 16 (коды целые, деление на степень двойки точное)
    float2 lo = c - hi * 16.0;
    float3 vel = float3(lo.x - 8.0, hi.x - 8.0, lo.y - 8.0) * FLOW_Q;
    float sp = length(vel);
    float cyc = floor(sp * FLOW_SPEED / FLOW_L * TIME_PERIOD + 0.5) / TIME_PERIOD;   // циклов в секунду
    float moving = has * step(0.5 / TIME_PERIOD, cyc) * saturate(a);
    float f = frac(t * cyc + hi.y * 0.25);
    float sn = sin(3.14159265 * f);
    float3 p = i.pos.xyz + vel / max(sp, 0.001) * ((f - 0.5) * FLOW_L * moving);
    float weight = lerp(1.0, 2.0 * sn * sn, moving);
    // связное поле смещений: два масштаба (крупные волны ~100 ед. и мелкая рябь ~40 ед.)
    float3 w = p * 0.03;
    float3 off;
    // частоты кратны 0.05 (период времени 2π·20); снижены ~в 1.7 раза — спокойное колыхание
    off.x = sin(w.y + t * 0.25) * 3.5 + sin(p.z * 0.08 + t * 0.4) * 1.5;
    off.y = sin(w.x * 1.1 + t * 0.25) * 3.5 + sin(p.x * 0.08 - t * 0.4) * 1.5;
    off.z = sin(w.x + w.y + t * 0.3) * 2.0 + sin(p.y * 0.07 + t * 0.35) * 1.0;
    p += off * a;

    o.pos = mul(float4(p, 1), cViewProj);
    o.proj = o.pos;
    o.uv = uv;
    o.flow = float4(i.pos.xyz, t * a);
    o.col = float4(i.col.rgb, saturate(i.col.a * weight));
    return o;
}
