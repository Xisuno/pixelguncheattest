// offsets.h – Offsets derivados do dump.cs fornecido.
//
// Fonte de cada offset: leitura direta do dump.cs (campo "// 0xXX" na classe).
// Todos os valores são offsets de INSTÂNCIA relativos ao ponteiro do objeto IL2CPP
// (ou seja, incluem o header de 0x10 bytes do Il2CppObject).
//
// NUNCA use estes offsets sem validar o módulo e tamanho do .deb em runtime.
// Se o jogo atualizar, re-dump e atualize este arquivo.

#pragma once
#include <stddef.h>

// ============================================================
// Player_move_c   (dump.cs linha 66540)
// ============================================================
namespace PlayerMove {
    // UnityEngine.TextMesh nickLabel @ 0x4A8
    static constexpr ptrdiff_t nickLabel           = 0x4A8;
    // UnityEngine.BoxCollider headCollider @ 0x188
    static constexpr ptrdiff_t headCollider        = 0x188;
    // UnityEngine.Collider _aimCollider @ 0x1B0
    static constexpr ptrdiff_t aimCollider         = 0x1B0;
    // UnityEngine.Transform PlayerHeadTransform @ 0x540
    static constexpr ptrdiff_t headTransform       = 0x540;
    // UnityEngine.Transform myPlayerTransform @ 0x488
    static constexpr ptrdiff_t myPlayerTransform   = 0x488;
    // PhotonView photonView @ 0x4D0
    static constexpr ptrdiff_t photonView          = 0x4D0;
    // PixelView pixelView @ 0x4E0
    static constexpr ptrdiff_t pixelView           = 0x4E0;
    // bool isHideInHideFromMonster @ 0x400
    static constexpr ptrdiff_t isHideInMonster     = 0x400;
    // float shoulderZoomFovForScope @ 0x560
    static constexpr ptrdiff_t shoulderFov         = 0x560;
    // UniqueEffects.Outline.OutlineEffectComponent enemyOutlineEffect @ 0x1E8
    static constexpr ptrdiff_t enemyOutline        = 0x1E8;
    // UniqueEffects.Outline.OutlineEffectComponent allyOutlineEffect @ 0x1F0
    static constexpr ptrdiff_t allyOutline         = 0x1F0;
}

// ============================================================
// BaseDummy   (dump.cs linha 9136)
// ============================================================
namespace BaseDummyOff {
    // float health @ 0x20
    static constexpr ptrdiff_t health    = 0x20;
    // bool flyTarget @ 0x32
    static constexpr ptrdiff_t flyTarget = 0x32;
    // bool hidingTarget @ 0x33
    static constexpr ptrdiff_t hiding    = 0x33;
}

// ============================================================
// BotHealth   (dump.cs linha 102318)
// ============================================================
namespace BotHealthOff {
    // string myName @ 0x68
    static constexpr ptrdiff_t myName    = 0x68;
    // Player_move_c 东丄业丄丁上丘丈丌 @ 0x50
    static constexpr ptrdiff_t playerRef = 0x50;
}

// ============================================================
// ClickerDetector   (dump.cs linha 18641)
// ============================================================
namespace ClickerDetectorOff {
    // internal bool 丂丑丝三丈丞与丌丝 @ 0x20   <-- flag que habilita detecção
    static constexpr ptrdiff_t enabled   = 0x20;
    // static ClickerDetector 上世丞丐丅不丙东丝 @ 0x0  (campo estático)
    // Resolvido via il2cpp_class_get_field_from_name em runtime
}

// ============================================================
// CheatDetectedBanner   (dump.cs linha 15716)
// ============================================================
namespace CheatBannerOff {
    // bool 丗世丈丆一丙丙专七 @ 0x30
    static constexpr ptrdiff_t flag0 = 0x30;
    // bool 丆丟丘丝丄丘且七丌 @ 0x31
    static constexpr ptrdiff_t flag1 = 0x31;
}

// ============================================================
// PhotonView  (Photon library – campo isMine é propriedade,
//              o backing field tipicamente fica em 0xE0 no Photon2)
// ============================================================
namespace PhotonViewOff {
    // bool isMine @ 0xE0  (dump.cs linha 784 – classe unnamed próxima a PhotonView)
    static constexpr ptrdiff_t isMine   = 0xE0;
    // int viewID – normalmente 0x28 no Photon para Unity, confirmar com breakpoint
    // MARCADO COMO DESCONHECIDO: use get_isMine() via icall em vez disso
}

// ============================================================
// Unity Transform – offsets internos do objeto C# wrapper
// position/rotation são obtidos via icall (get_position_Injected etc.)
// Não há offset direto confiável sem o mono_field_offset.
// ============================================================
