// AimMath.h – matemática pura da mira (sem Unity/UIKit), para poder ser
// verificada fora do jogo. Convenção Unity: mão esquerda, +X direita, +Y cima,
// +Z frente; ângulos em graus; quaternion = (x, y, z, w).
#pragma once
#include <cmath>
#include "il2cpp_api.h"

inline Vector3 AM_Sub(Vector3 a, Vector3 b) { return { a.x - b.x, a.y - b.y, a.z - b.z }; }
inline Vector3 AM_Lerp(Vector3 a, Vector3 b, float t) {
    return { a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t };
}
inline float   AM_Len(Vector3 v) { return std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z); }
inline Vector3 AM_Cross(Vector3 a, Vector3 b) {
    return { a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x };
}

// Equivalente a Quaternion.LookRotation(forward, up): z = frente, x = up x z,
// y = z x x; a matriz de colunas (x, y, z) vira quaternion.
// Retorna false se forward é nulo ou paralelo a up.
inline bool AM_LookRotation(Vector3 forward, Vector3 up, Quaternion& out) {
    float fl = AM_Len(forward);
    if (!(fl > 1e-6f)) return false;
    Vector3 z = { forward.x / fl, forward.y / fl, forward.z / fl };
    Vector3 x = AM_Cross(up, z);
    float xl = AM_Len(x);
    if (!(xl > 1e-6f)) return false;
    x = { x.x / xl, x.y / xl, x.z / xl };
    Vector3 y = AM_Cross(z, x);
    float m00 = x.x, m01 = y.x, m02 = z.x;
    float m10 = x.y, m11 = y.y, m12 = z.y;
    float m20 = x.z, m21 = y.z, m22 = z.z;
    float tr = m00 + m11 + m22;
    if (tr > 0.0f) {
        float s = std::sqrt(tr + 1.0f) * 2.0f;
        out = { (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25f * s };
    } else if (m00 > m11 && m00 > m22) {
        float s = std::sqrt(1.0f + m00 - m11 - m22) * 2.0f;
        out = { 0.25f * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s };
    } else if (m11 > m22) {
        float s = std::sqrt(1.0f + m11 - m00 - m22) * 2.0f;
        out = { (m01 + m10) / s, 0.25f * s, (m12 + m21) / s, (m02 - m20) / s };
    } else {
        float s = std::sqrt(1.0f + m22 - m00 - m11) * 2.0f;
        out = { (m02 + m20) / s, (m12 + m21) / s, 0.25f * s, (m10 - m01) / s };
    }
    return true;
}

// Raio (em pontos) do círculo de FOV. Mesma regra que o aimbot usa para decidir
// se um alvo está dentro do FOV: distância ao centro <= meia-diagonal * sin(fov/2).
inline float AM_FovRadius(float halfW, float halfH, float fovDeg) {
    return std::sqrt(halfW * halfW + halfH * halfH) *
           std::sin(fovDeg * 0.5f * 3.14159265358979f / 180.0f);
}

// Fim do segmento de wallcheck: recua `pad` metros antes do alvo (no máximo
// metade do segmento) para a linha não bater no collider do próprio alvo.
inline Vector3 AM_SegmentEnd(Vector3 from, Vector3 to, float pad) {
    Vector3 d = AM_Sub(to, from);
    float len = AM_Len(d);
    if (!(len > 1e-4f)) return to;
    float p = pad < len * 0.5f ? pad : len * 0.5f;
    float k = (len - p) / len;
    return { from.x + d.x * k, from.y + d.y * k, from.z + d.z * k };
}
