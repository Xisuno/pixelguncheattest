#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Inicializa toda a infra: resolve API il2cpp, encontra classes, instala hooks.
// Chamado uma vez após a GameAssembly ser carregada.
void HookManager_Init(void);

// Retorna true se o HookManager está pronto para operação.
bool HookManager_IsReady(void);

#ifdef __cplusplus
} // extern "C"
#endif

// ---- Estado do cheat (acessível por Menu e Tweak.xm) ----
#ifdef __cplusplus
struct CheatState {
    bool aimbot;       // aimlock para o alvo mais próximo no crosshair
    bool aimLock;      // trava no alvo mesmo sem pressionar
    float aimbotFov;   // raio FOV em graus para seleção de alvo
    bool esp;          // box / nome / health ESP
    bool espSkeleton;  // linhas de skeleton no ESP
    bool acBypass;     // desabilita ClickerDetector e CheatDetectedBanner
    bool initialized;
};
extern CheatState g_cheat;
#endif
