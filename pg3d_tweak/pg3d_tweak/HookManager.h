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

// Forward decl apenas para ponteiro opaco — definição completa está em
// il2cpp_api.h, incluído separadamente onde o layout real é necessário.
struct Il2CppObject;

// Aplica os filtros de alvo (teamcheck, minimum range, wallcheck) com a
// MESMA lógica usada pelo aimbot, para que o ESP (Menu.mm) mostre
// exatamente os jogadores que o aimbot também considera válidos.
// Retorna false se o jogador deve ser ignorado (aliado filtrado, muito
// perto do minRange, ou sem linha de visada com wallcheck ligado).
// Quando um dado necessário não pôde ser lido (ex.: wallcheck sem
// MethodInfo de Physics.Raycast resolvido), a função falha aberta
// (retorna true / não filtra) em vez de esconder um alvo real por engano.
bool Player_PassesFilters(struct Il2CppObject* player);

// Loga no arquivo/NSLog o estado real (resolvido ou não) de tudo que
// teamcheck/wallcheck dependem, mais os ponteiros/flags atuais. "who" é
// só uma etiqueta pra identificar no log de onde veio a chamada
// (ex.: "toggleTeamCheck", "toggleWallCheck").
void Diag_LogFilterStatus(const char* who);

#ifdef __cplusplus
} // extern "C"
#endif

// ---- Estado do cheat (acessível por Menu e Tweak.xm) ----
#ifdef __cplusplus
struct CheatState {
    bool aimbot;       // aimlock para o alvo mais próximo no crosshair
    bool aimLock;      // trava no alvo mesmo sem pressionar (também ligado pelo botão flutuante)
    float aimbotFov;   // raio FOV em graus para seleção de alvo
    bool esp;          // box / nome / health ESP
    bool espSkeleton;  // linhas de skeleton no ESP
    bool acBypass;     // desabilita ClickerDetector e CheatDetectedBanner
    bool teamCheck;    // quando true, ignora aliados confirmados (via allyOutline/enemyOutline) no ESP e no aimbot
    bool wallCheck;    // quando true, exige linha de visada (Physics.Raycast) entre o player local e o alvo
    float minRange;    // metros; 0 = desabilitado. Alvos mais perto que isso são ignorados pelo ESP e pelo aimbot
    bool initialized;
};
extern CheatState g_cheat;
#endif
