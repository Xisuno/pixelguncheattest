#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Log de diagnóstico: grava em NSLog (syslog/`log stream`) E em arquivo,
// porque em alguns bootstraps o processo do jogo não aparece no `log stream`
// do NewTerm (sandbox/predicate), mas o arquivo sempre pode ser lido depois
// com `cat`. Tenta /var/mobile primeiro, cai para /tmp se o sandbox do app
// bloquear escrita em /var/mobile. Cada chamada abre, escreve e fecha o
// arquivo (sem handle global) para garantir que a linha é persistida mesmo
// se o processo crashar logo em seguida.
void PG3D_Log(const char* fmt, ...);

// Caminho do arquivo de log efetivamente em uso (definido na primeira
// chamada de PG3D_Log que conseguir escrever). Vazio = ainda não escreveu.
const char* PG3D_LogPath(void);

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
