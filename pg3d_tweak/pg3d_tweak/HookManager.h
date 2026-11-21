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

// Aplica os filtros de alvo (teamcheck e minimum range; o wallcheck vale só
// para a mira, por ponto do corpo, e não esconde ninguém no ESP) com a
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

// ---- Mira: FOV, lock e wallcheck (usados pelo Menu.mm) ----
// Tamanho (em pontos) da view do overlay; o ESPView chama isto no layout para que
// projeção, círculo de FOV e centro de mira usem exatamente o mesmo retângulo.
void  Overlay_SetSize(float w, float h);
// Raio do círculo de FOV em pontos (mesma regra que o aimbot usa para escolher alvo).
float Aim_FovRadiusPoints(void);
// Trava a mira no melhor alvo que está agora dentro do círculo de FOV.
// Liga g_cheat.aimLock e devolve true; devolve false (sem travar) se não há alvo.
bool  Aim_LockAcquire(void);
// Solta a trava (g_cheat.aimLock = false).
void  Aim_LockRelease(void);
// true se Physics.Linecast(Vector3, Vector3) foi resolvido neste build.
bool  Aim_WallCheckAvailable(void);
// Pede ao HookManager que grave agora (no log e em pg3d_fields.txt) os campos de
// Player_move_c e o valor dos que parecem de time, para o local e até 5 outros.
void  Diag_RequestTeamDump(void);

#ifdef __cplusplus
} // extern "C"
#endif

// ---- Estado do cheat (acessível por Menu e Tweak.xm) ----
#ifdef __cplusplus
// Partes do corpo da mira (máscara de bits em CheatState::aimParts).
enum AimPartBit { AIM_PART_HEAD = 1, AIM_PART_CHEST = 2, AIM_PART_STOMACH = 4, AIM_PART_LEGS = 8 };

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
    unsigned char aimParts; // máscara AimPartBit; sempre >= 1 parte
    bool showFov;      // desenha o círculo de FOV no overlay
    bool lockButton;   // mostra o botão flutuante de lock (fora do menu)
    bool aimBodyYaw;   // mira gira o CORPO (yaw) e a câmera (pitch), em vez de só o myCameraContainer
};
extern CheatState g_cheat;
#endif
