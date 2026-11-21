// HookManager.mm
// Responsável por:
//   1. Resolver a API IL2CPP via dlopen/dlsym na GameAssembly
//   2. Encontrar as classes Player_move_c, ClickerDetector, CheatDetectedBanner
//   3. Instalar MSHookFunction/MSHookMessageEx nos métodos alvo
//   4. Prover helpers para o resto do cheat
//
// Design: internal DLL injetada pelo Theos/Substrate no processo do PG3D.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <substrate.h>
#include <pthread.h>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>
#include <unistd.h>
#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <os/log.h>

#include "il2cpp_api.h"
#include "offsets.h"
#include "HookManager.h"
#include "AimMath.h"

// ============================================================
//  Globals
// ============================================================
Il2CppAPI    g_il2cpp      = {};
// Ordem tem que bater exatamente com CheatState em HookManager.h:
// aimbot, aimLock, aimbotFov, esp, espSkeleton, acBypass, teamCheck,
// wallCheck, minRange, initialized.
// ... initialized, aimParts (só cabeça), showFov, lockButton.
CheatState   g_cheat       = { false, false, 15.0f, false, false, true, false, false, 0.0f, false,
                               AIM_PART_HEAD, true, false, true };

// ============================================================
//  Log de diagnóstico (NSLog + arquivo)
// ============================================================
// Caminho efetivo onde conseguimos escrever pela última vez (ou string
// vazia se ainda nenhuma chamada conseguiu abrir um arquivo).
static char s_logPath[256] = {0};

const char* PG3D_LogPath(void) { return s_logPath; }

void PG3D_Log(const char* fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    // os_log com %{public}s: NSLog com string dinâmica pode sair como <private>.
    os_log(OS_LOG_DEFAULT, "%{public}s", msg);

    // Arquivo dentro do container do app (o sandbox bloqueia /var/mobile e /tmp
    // para apps do App Store). Caminho: <container>/tmp/pg3d_tweak.log
    const char* tmp = NSTemporaryDirectory().fileSystemRepresentation;
    char path[256];
    snprintf(path, sizeof(path), "%s/pg3d_tweak.log", tmp ? tmp : "/tmp");
    FILE* f = fopen(path, "a");
    if (!f) return;
    time_t now = time(nullptr);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char ts[16];
    strftime(ts, sizeof(ts), "%H:%M:%S", &tmv);
    fprintf(f, "[%s] %s\n", ts, msg);
    fflush(f);
    fclose(f);
    strncpy(s_logPath, path, sizeof(s_logPath) - 1);
}

// Ponteiros para classes IL2CPP (preenchidos em Init)
static Il2CppClass* cls_PlayerMove    = nullptr;
static Il2CppClass* cls_ClickerDet    = nullptr;
static Il2CppClass* cls_CheatBanner   = nullptr;
static Il2CppClass* cls_Camera        = nullptr;
static Il2CppClass* cls_Transform     = nullptr;
static Il2CppClass* cls_Object        = nullptr;
// UnityEngine.Behaviour.get_enabled() — usado pelo teamcheck para ler o
// estado (enabled/disabled) dos componentes OutlineEffectComponent que o
// próprio jogo já usa para colorir aliado vs inimigo (PlayerMove::allyOutline
// / enemyOutline em offsets.h). Não inventamos offset de "time": lemos um
// sinal que o jogo já calcula.
static Il2CppClass* cls_Behaviour     = nullptr;
static MethodInfo*  s_mGetEnabled     = nullptr;
// UnityEngine.Physics.Raycast — usado pelo wallcheck.
// ATENÇÃO (assunção não confirmada em runtime): Physics tem várias
// sobrecargas de Raycast; pegamos a primeira com param_count == 3, que
// deveria ser bool Raycast(Vector3 origin, Vector3 direction, float
// maxDistance). Isso NÃO foi validado contra o dump.cs desta build — há
// risco real de pegar outra sobrecarga de 3 parâmetros (ex.: a que tem
// "out RaycastHit" em vez de maxDistance) e o resultado da chamada ficar
// sem sentido. Antes de confiar no wallcheck: ativar wallCheck sozinho,
// ficar atrás de uma parede sólida e confirmar no log/visualmente que o
// ESP/aimbot some; se o comportamento for errático, resolver a sobrecarga
// certa via il2cpp_method_get_param (tipo de cada parâmetro) em vez de
// param_count.
static Il2CppClass* cls_Physics       = nullptr;
static MethodInfo*  s_mRaycast        = nullptr; // só diagnóstico (overload por contagem de args NÃO é confiável)
// Physics.Linecast(Vector3, Vector3): resolvido por assinatura exata (tipos dos parâmetros).
static MethodInfo*  s_mLinecast       = nullptr;
static MethodInfo*  s_mGetTransform   = nullptr; // Component.get_transform (para a posição da câmera)
static MethodInfo*  s_mSetRot         = nullptr; // Transform.set_rotation(Quaternion)
static MethodInfo*  s_mGetRot         = nullptr; // Transform.get_rotation()
static MethodInfo*  s_mIsChildOf      = nullptr; // Transform.IsChildOf(Transform)

// Icalls Unity que usamos para Transform.position e Camera.WorldToScreenPoint
typedef void (*fn_Transform_GetPos)(void* tr, Vector3* out);
typedef void (*fn_Camera_W2S)(void* cam, Vector3* world, Vector3* out);
typedef void (*fn_Camera_GetFov)(void* cam, float* out);
typedef void (*fn_Camera_SetFov)(void* cam, float fov);
typedef void (*fn_Input_GetMouseButton)(int btn, bool* out);

static fn_Transform_GetPos   icall_Transform_get_position  = nullptr;
static fn_Camera_W2S         icall_Camera_WorldToScreen     = nullptr;
static fn_Camera_GetFov      icall_Camera_GetFov            = nullptr;
static fn_Camera_SetFov      icall_Camera_SetFov            = nullptr;

// Métodos hooked
// (apenas meth_PlayerUpdate é mantido como global: os MethodInfo* de
// ClickerDetector/CheatDetectedBanner são resolvidos e usados localmente
// dentro de InitThread como m_cu/m_ca/m_ba/m_bu, sem necessidade de cache
// a nível de arquivo — por isso não há mais globals correspondentes aqui.)
static MethodInfo* meth_PlayerUpdate      = nullptr;

// FindObjectsOfType<T>() via icall – retorna array de objetos
// Assinatura IL2CPP: Object[] FindObjectsOfTypeAll(Type t)
typedef Il2CppArray* (*fn_FindObjectsOfTypeAll)(void* type, void* ex);
static fn_FindObjectsOfTypeAll icall_FindObjectsAll = nullptr;

// GetType de Il2CppClass
typedef void* (*fn_GetType)(Il2CppClass*);
static fn_GetType icall_GetType = nullptr;

// ============================================================
//  Trampoline originals
// ============================================================
static void (*orig_PlayerUpdate)  (Il2CppObject*, void*)  = nullptr;
static void (*orig_ClickerUpdate) (Il2CppObject*, void*)  = nullptr;
static void (*orig_BannerAwake)   (Il2CppObject*, void*)  = nullptr;
static void (*orig_BannerUpdate)  (Il2CppObject*, void*)  = nullptr;

// ============================================================
//  Helpers de posição/câmera
// ============================================================
// Os helpers abaixo chamam MÉTODOS GERENCIADOS via il2cpp_runtime_invoke, em
// vez de icalls cujos nomes/assinaturas mudam entre versões do Unity.
// Retorno de value type (Vector3, int) vem BOXED: dados em obj + 0x10.
static MethodInfo* s_mGetMain = nullptr;   // static Camera.get_main()
static MethodInfo* s_mW2S     = nullptr;   // Camera.WorldToScreenPoint(Vector3)
static MethodInfo* s_mGetPos  = nullptr;   // Transform.get_position()
static MethodInfo* s_mPixW    = nullptr;   // Camera.get_pixelWidth()
static MethodInfo* s_mPixH    = nullptr;   // Camera.get_pixelHeight()

static Il2CppObject* s_mainCam      = nullptr;
static int           s_camFrameCnt  = 0;
static float         s_pixW         = 0.0f; // tamanho do render target da câmera
static float         s_pixH         = 0.0f;

// ---- Escolha de overload por assinatura exata ----
// Contar parâmetros NÃO distingue overloads (ex.: Physics.Raycast tem várias com 3
// parâmetros; a escolhida por contagem reportava "bloqueado" para tudo). Aqui
// comparamos o nome do tipo de cada parâmetro. type_get_name devolve memória
// alocada pelo runtime; só é chamado na inicialização, então o vazamento é irrelevante.
static MethodInfo* FindMethodBySig(Il2CppClass* cls, const char* name,
                                   const char* const* params, int nparams) {
    if (!cls || !g_il2cpp.class_get_methods || !g_il2cpp.method_get_name ||
        !g_il2cpp.method_get_param_count || !g_il2cpp.method_get_param || !g_il2cpp.type_get_name)
        return nullptr;
    void* iter = nullptr;
    while (MethodInfo* m = g_il2cpp.class_get_methods(cls, &iter)) {
        const char* mn = g_il2cpp.method_get_name(m);
        if (!mn || strcmp(mn, name) != 0) continue;
        if ((int)g_il2cpp.method_get_param_count(m) != nparams) continue;
        bool ok = true;
        for (int i = 0; i < nparams && ok; i++) {
            const Il2CppType* t = g_il2cpp.method_get_param(m, (uint32_t)i);
            char* tn = t ? g_il2cpp.type_get_name(t) : nullptr;
            ok = tn && strcmp(tn, params[i]) == 0;
        }
        if (ok) return m;
    }
    return nullptr;
}

// Loga a assinatura de cada overload de `name` (diagnóstico).
static void LogOverloads(Il2CppClass* cls, const char* name) {
    if (!cls || !g_il2cpp.class_get_methods || !g_il2cpp.method_get_name ||
        !g_il2cpp.method_get_param_count || !g_il2cpp.method_get_param || !g_il2cpp.type_get_name) {
        PG3D_Log("[pg3d_tweak] OVERLOAD %s: API de introspecção indisponível", name);
        return;
    }
    void* iter = nullptr;
    int n = 0;
    while (MethodInfo* m = g_il2cpp.class_get_methods(cls, &iter)) {
        const char* mn = g_il2cpp.method_get_name(m);
        if (!mn || strcmp(mn, name) != 0) continue;
        std::string sig;
        uint32_t pc = g_il2cpp.method_get_param_count(m);
        for (uint32_t i = 0; i < pc; i++) {
            const Il2CppType* t = g_il2cpp.method_get_param(m, i);
            char* tn = t ? g_il2cpp.type_get_name(t) : nullptr;
            if (i) sig += ", ";
            sig += tn ? tn : "?";
        }
        PG3D_Log("[pg3d_tweak] OVERLOAD %s(%s) = %p", name, sig.c_str(), (void*)m);
        if (++n >= 16) break;
    }
}

static void ResolveManagedHelpers() {
    static bool done = false;
    if (done || !g_il2cpp.class_get_method_from_name || !cls_Camera || !cls_Transform) return;
    done = true;
    s_mGetMain = g_il2cpp.class_get_method_from_name(cls_Camera,    "get_main", 0);
    s_mW2S     = g_il2cpp.class_get_method_from_name(cls_Camera,    "WorldToScreenPoint", 1);
    s_mGetPos  = g_il2cpp.class_get_method_from_name(cls_Transform, "get_position", 0);
    s_mPixW    = g_il2cpp.class_get_method_from_name(cls_Camera,    "get_pixelWidth", 0);
    s_mPixH    = g_il2cpp.class_get_method_from_name(cls_Camera,    "get_pixelHeight", 0);
    s_mSetRot = g_il2cpp.class_get_method_from_name(cls_Transform, "set_rotation", 1);
    s_mGetRot = g_il2cpp.class_get_method_from_name(cls_Transform, "get_rotation", 0);
    s_mIsChildOf = g_il2cpp.class_get_method_from_name(cls_Transform, "IsChildOf", 1);
    // get_transform é declarado em Component (ancestral de Camera): sobe a hierarquia.
    for (Il2CppClass* k = cls_Camera; k && !s_mGetTransform; ) {
        s_mGetTransform = g_il2cpp.class_get_method_from_name(k, "get_transform", 0);
        k = g_il2cpp.class_get_parent ? g_il2cpp.class_get_parent(k) : nullptr;
    }
    PG3D_Log("[pg3d_tweak] MANAGED: Camera.get_main=%p WorldToScreenPoint(1)=%p Transform.get_position=%p get_pixelWidth=%p get_pixelHeight=%p set_rotation=%p get_transform=%p",
             (void*)s_mGetMain, (void*)s_mW2S, (void*)s_mGetPos, (void*)s_mPixW, (void*)s_mPixH,
             (void*)s_mSetRot, (void*)s_mGetTransform);
    PG3D_Log("[pg3d_tweak] MANAGED: Transform.get_rotation=%p Transform.IsChildOf=%p",
             (void*)s_mGetRot, (void*)s_mIsChildOf);
}

static float CamPixel(Il2CppObject* cam, MethodInfo* m) {
    if (!cam || !m || !g_il2cpp.runtime_invoke) return 0.0f;
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(m, cam, nullptr, &ex);
    if (!ret || ex) return 0.0f;
    return (float)Field<int32_t>(ret, 0x10);
}

static Vector3 GetTransformPosition(Il2CppObject* transform) {
    Vector3 pos = {0,0,0};
    if (!transform) return pos;
    ResolveManagedHelpers();
    if (s_mGetPos && g_il2cpp.runtime_invoke) {
        void* ex = nullptr;
        Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mGetPos, transform, nullptr, &ex);
        if (ret && !ex) return Field<Vector3>(ret, 0x10);
    }
    if (icall_Transform_get_position)
        icall_Transform_get_position(transform, &pos);
    return pos;
}

// Tamanho do overlay em pontos, informado pelo ESPView a cada layout (rotação
// incluída). Antes do primeiro layout cai para UIScreen.
static float s_ovW = 0.0f, s_ovH = 0.0f;
extern "C" void Overlay_SetSize(float w, float h) { s_ovW = w; s_ovH = h; }
static void OverlaySize(float& w, float& h) {
    if (s_ovW > 1.0f && s_ovH > 1.0f) { w = s_ovW; h = s_ovH; return; }
    CGRect b = [UIScreen mainScreen].bounds;
    w = (float)b.size.width;
    h = (float)b.size.height;
}

// Converte mundo -> coordenadas do overlay UIKit (pontos, origem no canto
// superior esquerdo). O Unity devolve PIXELS do render target com origem no
// canto INFERIOR esquerdo; por isso inverte Y e reescala para os pontos da tela.
// out.z = profundidade (>0 = na frente da câmera).
static bool WorldToScreen(Il2CppObject* camera, Vector3 world, Vector3& out) {
    if (!camera) return false;
    ResolveManagedHelpers();
    if (!s_mW2S || !g_il2cpp.runtime_invoke) return false;
    void* args[1] = { &world };
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mW2S, camera, args, &ex);
    if (!ret || ex) return false;
    Vector3 px = Field<Vector3>(ret, 0x10);
    if (px.z <= 0.0f || !std::isfinite(px.x) || !std::isfinite(px.y)) return false;
    if (s_pixW <= 0.0f || s_pixH <= 0.0f) return false;
    float ow, oh;
    OverlaySize(ow, oh);
    out.x = px.x / s_pixW * ow;
    out.y = (1.0f - px.y / s_pixH) * oh;
    out.z = px.z;
    return true;
}

static Il2CppObject* GetMainCamera() {
    if (s_camFrameCnt++ < 30 && s_mainCam) return s_mainCam;
    s_camFrameCnt = 0;
    ResolveManagedHelpers();
    if (!s_mGetMain || !g_il2cpp.runtime_invoke) {
        static bool s_camLogged = false;
        if (!s_camLogged) {
            s_camLogged = true;
            PG3D_Log("[pg3d_tweak] CAMERA: Camera.get_main indisponivel (get_main=%p cls_Camera=%p)",
                     (void*)s_mGetMain, (void*)cls_Camera);
        }
        return s_mainCam;
    }
    void* ex = nullptr;
    Il2CppObject* cam = g_il2cpp.runtime_invoke(s_mGetMain, nullptr, nullptr, &ex);
    s_mainCam = (cam && !ex) ? cam : nullptr; // nulo se a câmera sumiu (evita ponteiro velho)
    if (s_mainCam) {
        s_pixW = CamPixel(s_mainCam, s_mPixW);
        s_pixH = CamPixel(s_mainCam, s_mPixH);
        static bool s_camOk = false;
        if (!s_camOk) {
            s_camOk = true;
            PG3D_Log("[pg3d_tweak] CAMERA: main=%p pixel=%.0fx%.0f", (void*)s_mainCam, s_pixW, s_pixH);
        }
    }
    return s_mainCam;
}

// ============================================================
//  Lista de players (atualizada no hook de PlayerUpdate)
// ============================================================
// Posição (mundo) da Camera.main.
static bool CameraPosition(Il2CppObject* cam, Vector3& out) {
    ResolveManagedHelpers();
    if (!cam || !s_mGetTransform || !g_il2cpp.runtime_invoke) return false;
    void* ex = nullptr;
    Il2CppObject* tr = g_il2cpp.runtime_invoke(s_mGetTransform, cam, nullptr, &ex);
    if (!tr || ex) return false;
    out = GetTransformPosition(tr);
    return std::isfinite(out.x) && std::isfinite(out.y) && std::isfinite(out.z);
}

static double NowSec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

// Cada entrada guarda quando o Update do player rodou pela última vez. Objetos
// destruídos/desativados param de receber Update; sem isso eles ficavam na lista
// para sempre (ESP desenhando "fantasmas" e ponteiros velhos sendo dereferenciados).
struct PlayerEntry { Il2CppObject* p; double lastSeen; };
static std::vector<PlayerEntry> s_players;
static pthread_mutex_t          s_playerMtx = PTHREAD_MUTEX_INITIALIZER;
static const double kPlayerStaleSec = 1.0;   // sem Update há mais que isso = ausente (uncalibrated)
static const double kPlayerPruneSec = 10.0;  // remove da lista depois disso

static void AddPlayer(Il2CppObject* p) {
    double now = NowSec();
    pthread_mutex_lock(&s_playerMtx);
    for (auto& e : s_players) {
        if (e.p == p) { e.lastSeen = now; pthread_mutex_unlock(&s_playerMtx); return; }
    }
    s_players.push_back({ p, now });
    pthread_mutex_unlock(&s_playerMtx);
}

static void RemoveDeadPlayers() {
    // chamado periodicamente no Update do local player. Só usa o tempo: não
    // dereferencia ponteiros que podem já ter sido coletados.
    double now = NowSec();
    pthread_mutex_lock(&s_playerMtx);
    s_players.erase(
        std::remove_if(s_players.begin(), s_players.end(), [now](const PlayerEntry& e) {
            return !e.p || (now - e.lastSeen) > kPlayerPruneSec;
        }),
        s_players.end());
    pthread_mutex_unlock(&s_playerMtx);
}

// Players vistos recentemente (cópia dos ponteiros).
static void LivePlayers(std::vector<Il2CppObject*>& out) {
    double now = NowSec();
    pthread_mutex_lock(&s_playerMtx);
    for (const auto& e : s_players)
        if (e.p && (now - e.lastSeen) <= kPlayerStaleSec) out.push_back(e.p);
    pthread_mutex_unlock(&s_playerMtx);
}

static bool IsPlayerLive(Il2CppObject* p) {
    if (!p) return false;
    double now = NowSec();
    bool live = false;
    pthread_mutex_lock(&s_playerMtx);
    for (const auto& e : s_players)
        if (e.p == p) { live = (now - e.lastSeen) <= kPlayerStaleSec; break; }
    pthread_mutex_unlock(&s_playerMtx);
    return live;
}

static size_t PlayerCount() {
    pthread_mutex_lock(&s_playerMtx);
    size_t n = s_players.size();
    pthread_mutex_unlock(&s_playerMtx);
    return n;
}

// ============================================================
// ============================================================
//  Aimbot: seleciona alvo mais próximo ao centro da tela
// ============================================================

// Chama PhotonView.get_isMine() via icall
static MethodInfo* meth_isMine = nullptr;
static bool IsLocalPlayer(Il2CppObject* player) {
    if (!meth_isMine) return false;
    Il2CppObject* pv = Field<Il2CppObject*>(player, PlayerMove::photonView);
    if (!pv) return false;
    bool result = false;
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(meth_isMine, pv, nullptr, &ex);
    if (ret) result = Field<bool>(ret, 0x10); // unboxed bool
    return result;
}

static Il2CppObject* s_localPlayer = nullptr;

// Vários objetos podem ter PhotonView.isMine == true ao mesmo tempo (visto no log:
// dois "local players" alternando, cada um girando seu próprio myCameraContainer).
// O verdadeiro é o cujo myCameraContainer (0x478) está colado na Camera.main.
struct LocalCand { Il2CppObject* p; float dist; double seen; };
static LocalCand s_cands[8] = {};
static int       s_candCount = 0;

static void UpdateLocalCandidate(Il2CppObject* self) {
    double now = NowSec();
    float dist = 1e6f; // desconhecida
    Il2CppObject* cam  = GetMainCamera();
    Il2CppObject* cont = Field<Il2CppObject*>(self, 0x478);
    Vector3 cp;
    if (cam && cont && CameraPosition(cam, cp))
        dist = AM_Len(AM_Sub(GetTransformPosition(cont), cp));

    int idx = -1;
    for (int i = 0; i < s_candCount; i++) if (s_cands[i].p == self) { idx = i; break; }
    if (idx < 0) {
        if (s_candCount < 8) idx = s_candCount++;
        else {
            idx = 0;
            for (int i = 1; i < 8; i++) if (s_cands[i].seen < s_cands[idx].seen) idx = i;
        }
        s_cands[idx].p = self;
    }
    s_cands[idx].dist = dist;
    s_cands[idx].seen = now;

    Il2CppObject* best = nullptr;
    float bestDist = 1e30f;
    int fresh = 0;
    for (int i = 0; i < s_candCount; i++) {
        if (now - s_cands[i].seen > 1.0) continue;
        fresh++;
        float d = s_cands[i].dist;
        if (d < bestDist || (d == bestDist && s_cands[i].p == s_localPlayer)) {
            bestDist = d;
            best = s_cands[i].p;
        }
    }
    if (best && best != s_localPlayer) {
        s_localPlayer = best;
        PG3D_Log("[pg3d_tweak] LOCAL: escolhido=%p dist_camera=%.2fm candidatos_isMine=%d",
                 (void*)best, bestDist, fresh);
    }
}

// ============================================================
//  Teamcheck: lê o estado (enabled) dos componentes de outline que o
//  próprio jogo já usa para pintar aliado (allyOutline) vs inimigo
//  (enemyOutline). Não existe offset de "time" confirmado no dump.cs
//  fornecido, então não inventamos um — usamos um sinal que já está no
//  objeto e é medido (offsets.h: PlayerMove::allyOutline/enemyOutline).
// ============================================================
enum class TeamStatus { Unknown, Ally, Enemy };

static bool GetBehaviourEnabled(Il2CppObject* component) {
    if (!component || !s_mGetEnabled || !g_il2cpp.runtime_invoke) return false;
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mGetEnabled, component, nullptr, &ex);
    if (!ret || ex) return false;
    return Field<bool>(ret, 0x10); // bool boxed
}

static TeamStatus GetTeamStatus(Il2CppObject* player) {
    if (!player) return TeamStatus::Unknown;
    Il2CppObject* allyC  = Field<Il2CppObject*>(player, PlayerMove::allyOutline);
    Il2CppObject* enemyC = Field<Il2CppObject*>(player, PlayerMove::enemyOutline);
    bool allyEnabled  = GetBehaviourEnabled(allyC);
    bool enemyEnabled = GetBehaviourEnabled(enemyC);
    if (enemyEnabled && !allyEnabled) return TeamStatus::Enemy;
    if (allyEnabled && !enemyEnabled) return TeamStatus::Ally;
    // Ambos ligados, ambos desligados, ou componentes nulos: ambíguo.
    // Loga uma vez para não gerar ruído por frame.
    static bool s_ambiguousLogged = false;
    if (!s_ambiguousLogged) {
        s_ambiguousLogged = true;
        PG3D_Log("[pg3d_tweak] TEAMCHECK: status ambiguo para player=%p allyC=%p(%d) enemyC=%p(%d) — "
                 "teamcheck vai tratar como inimigo (fail-open) ate confirmar em jogo",
                 (void*)player, (void*)allyC, (int)allyEnabled, (void*)enemyC, (int)enemyEnabled);
    }
    return TeamStatus::Unknown;
}

// ============================================================
//  Wallcheck: Physics.Linecast(Vector3, Vector3) da câmera até o ponto
//  de mira. true = há algo no meio. Resolvido por assinatura exata (a
//  versão por contagem de parâmetros pegava a overload errada).
//  A linha para kWallCheckEndPad metros antes do ponto para não bater no
//  collider do próprio alvo; um Raycast/Linecast que começa DENTRO de um
//  collider (o do jogador local) não o detecta.
// ============================================================
static bool s_wallUnavailLogged = false;

static bool LinecastBlocked(Vector3 from, Vector3 to, float endPad) {
    if (!s_mLinecast || !g_il2cpp.runtime_invoke) {
        if (!s_wallUnavailLogged) {
            s_wallUnavailLogged = true;
            PG3D_Log("[pg3d_tweak] WALLCHECK: Physics.Linecast(Vector3,Vector3) nao resolvido; "
                     "wallcheck sem efeito (falha aberta). Ver linhas OVERLOAD no log.");
        }
        return false; // falha aberta: nunca esconde um alvo por falta de dado
    }
    Vector3 end = AM_SegmentEnd(from, to, endPad);
    void* args[2] = { &from, &end };
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mLinecast, nullptr, args, &ex);
    if (!ret || ex) return false;
    return Field<bool>(ret, 0x10); // bool boxed
}

extern "C" bool Aim_WallCheckAvailable(void) { return s_mLinecast != nullptr; }

// ============================================================
//  Diagnóstico sob demanda: loga o estado REAL (resolvido em runtime ou
//  não) de tudo que teamcheck/wallcheck dependem. Chamado pelo Menu.mm
//  assim que o usuário mexe no switch correspondente, pra não precisar
//  esperar o log periódico do Update. Se os ponteiros saírem NULL aqui,
//  o filtro correspondente é garantidamente um no-op (fail-open) — não
//  pode ser a causa de nada travar.
// ============================================================
extern "C" void Diag_LogFilterStatus(const char* who) {
    PG3D_Log("[pg3d_tweak] DIAG(%s): ready=%d localPlayer=%p players=%zu | "
             "teamcheck: cls_Behaviour=%p get_enabled=%p | "
             "wallcheck: cls_Physics=%p Raycast=%p Linecast=%p | "
             "flags: teamCheck=%d wallCheck=%d minRange=%.1f aimbot=%d aimLock=%d",
             who, (int)g_cheat.initialized, (void*)s_localPlayer, PlayerCount(),
             (void*)cls_Behaviour, (void*)s_mGetEnabled,
             (void*)cls_Physics, (void*)s_mRaycast, (void*)s_mLinecast,
             (int)g_cheat.teamCheck, (int)g_cheat.wallCheck, g_cheat.minRange,
             (int)g_cheat.aimbot, (int)g_cheat.aimLock);
}

// ============================================================
//  Filtro único usado pelo aimbot (SelectAimTarget) e pelo ESP (Menu.mm),
//  para que os dois concordem sobre quem é um alvo válido.
// ============================================================
extern "C" bool Player_PassesFilters(Il2CppObject* player) {
    if (!player || player == s_localPlayer) return false;

    // Log periódico (não por chamada — isso é por frame, por jogador)
    // mostrando a decisão real tomada, só quando algum filtro está ligado.
    // Serve pra ver no log se teamcheck está de fato classificando todo
    // mundo como Ally (o que explicaria o ESP sumir inteiro) ou se o
    // problema é em outro lugar.
    if (g_cheat.teamCheck || g_cheat.wallCheck) {
        static int s_filterLogCnt = 0;
        if (s_filterLogCnt++ % 3000 == 0) {
            TeamStatus dbgTeam = g_cheat.teamCheck ? GetTeamStatus(player) : TeamStatus::Unknown;
            PG3D_Log("[pg3d_tweak] FILTER: player=%p teamCheck=%d team=%d(0=Unk,1=Ally,2=Enemy) "
                     "wallCheck=%d Linecast_resolved=%d",
                     (void*)player, (int)g_cheat.teamCheck, (int)dbgTeam,
                     (int)g_cheat.wallCheck, (int)(s_mLinecast != nullptr));
        }
    }

    if (g_cheat.teamCheck) {
        if (GetTeamStatus(player) == TeamStatus::Ally) return false;
        // Enemy ou Unknown: passa (fail-open — nunca escondemos um inimigo
        // real por causa de um status ambíguo).
    }

    if (g_cheat.minRange > 0.0f && s_localPlayer) {
        Il2CppObject* myTr    = Field<Il2CppObject*>(s_localPlayer, PlayerMove::myPlayerTransform);
        Il2CppObject* theirTr = Field<Il2CppObject*>(player,        PlayerMove::myPlayerTransform);
        if (myTr && theirTr) {
            Vector3 myPos    = GetTransformPosition(myTr);
            Vector3 theirPos = GetTransformPosition(theirTr);
            float dx = theirPos.x - myPos.x, dy = theirPos.y - myPos.y, dz = theirPos.z - myPos.z;
            float dist = sqrtf(dx*dx + dy*dy + dz*dz);
            if (dist < g_cheat.minRange) return false;
        }
        // Sem Transform resolvido: não dá para medir distância -> não filtra.
    }

    // wallcheck NÃO entra aqui: vale só para a MIRA (por ponto do corpo, em
    // BestPointForPlayer). O ESP continua mostrando quem está atrás de parede.
    return true;
}

// ============================================================
//  Aimbot: partes do corpo, wallcheck e lock
// ============================================================
// Valores abaixo são HIPÓTESES, não medidas neste build (ver CALIB no log):
static constexpr float kFeetOffsetY     = -0.1f;  // mesma suposição do ESP: pés = myPlayerTransform - 0.1
static constexpr float kFracHead        = 1.00f;  // fração pés -> cabeça de cada parte do corpo
static constexpr float kFracChest       = 0.75f;
static constexpr float kFracStomach     = 0.55f;
static constexpr float kFracLegs        = 0.25f;
static constexpr float kWallCheckEndPad = 0.6f;   // metros: a linha de visada para antes do ponto alvo

struct AimPoint  { Vector3 world; Vector3 screen; float dist; bool isHead; };
struct AimTarget { Il2CppObject* player; AimPoint pt; };

static Il2CppObject* s_lockedTarget = nullptr;

// Centro (cx, cy) e raio do círculo de FOV, em pontos do overlay.
static float FovRadiusPts(float& cx, float& cy) {
    float w, h;
    OverlaySize(w, h);
    cx = w * 0.5f;
    cy = h * 0.5f;
    return AM_FovRadius(cx, cy, g_cheat.aimbotFov);
}
extern "C" float Aim_FovRadiusPoints(void) {
    float cx, cy;
    return FovRadiusPts(cx, cy);
}

// Pés (myPlayerTransform - kFeetOffsetY) e cabeça (headTransform) em mundo.
static bool PlayerBodyEnds(Il2CppObject* p, Vector3& feet, Vector3& head) {
    Il2CppObject* headTr = Field<Il2CppObject*>(p, PlayerMove::headTransform);
    Il2CppObject* bodyTr = Field<Il2CppObject*>(p, PlayerMove::myPlayerTransform);
    if (!headTr || !bodyTr) return false;
    head = GetTransformPosition(headTr);
    feet = GetTransformPosition(bodyTr);
    feet.y += kFeetOffsetY;
    return std::isfinite(head.x) && std::isfinite(head.y) && std::isfinite(head.z) &&
           std::isfinite(feet.x) && std::isfinite(feet.y) && std::isfinite(feet.z);
}

struct PartDef { unsigned char bit; float frac; };
static const PartDef kParts[] = {
    { AIM_PART_HEAD,    kFracHead    },
    { AIM_PART_CHEST,   kFracChest   },
    { AIM_PART_STOMACH, kFracStomach },
    { AIM_PART_LEGS,    kFracLegs    },
};

// Melhor ponto de mira de UM player: entre as partes marcadas, a mais perto do
// centro da tela que (a) está dentro do círculo de FOV (se requireFov) e (b) não
// tem parede no meio (se wallCheck e a posição da câmera é conhecida).
static bool BestPointForPlayer(Il2CppObject* camera, Il2CppObject* p, bool requireFov,
                               bool haveCam, const Vector3& camPos, AimPoint& out) {
    Vector3 feet, head;
    if (!PlayerBodyEnds(p, feet, head)) return false;
    float cx, cy;
    float radius = FovRadiusPts(cx, cy);
    unsigned char mask = g_cheat.aimParts ? g_cheat.aimParts : (unsigned char)AIM_PART_HEAD;
    bool found = false;
    out.dist = 1e9f;
    for (const PartDef& part : kParts) {
        if (!(mask & part.bit)) continue;
        Vector3 w = AM_Lerp(feet, head, part.frac);
        Vector3 ss;
        if (!WorldToScreen(camera, w, ss)) continue;
        float dx = ss.x - cx, dy = ss.y - cy;
        float d = std::sqrt(dx * dx + dy * dy);
        if (requireFov && d > radius) continue;
        if (g_cheat.wallCheck && haveCam && LinecastBlocked(camPos, w, kWallCheckEndPad)) continue;
        if (d < out.dist) {
            out.world  = w;
            out.screen = ss;
            out.dist   = d;
            out.isHead = (part.bit == AIM_PART_HEAD);
            found = true;
        }
    }
    return found;
}

// Escolhe o alvo: players vivos que passam nos filtros (teamcheck/minRange), com
// algum ponto do corpo visível dentro do círculo de FOV; vence o mais perto do centro.
static AimTarget SelectAimTarget(Il2CppObject* camera) {
    AimTarget best = {};
    best.pt.dist = 1e9f;
    if (!camera) return best;

    Vector3 camPos = {0, 0, 0};
    bool haveCam = g_cheat.wallCheck && CameraPosition(camera, camPos);

    std::vector<Il2CppObject*> live;
    LivePlayers(live);
    for (Il2CppObject* p : live) {
        if (!p || p == s_localPlayer) continue;
        if (!Player_PassesFilters(p)) continue; // teamcheck / minRange
        AimPoint pt;
        if (!BestPointForPlayer(camera, p, true, haveCam, camPos, pt)) continue;
        if (pt.dist < best.pt.dist) { best.player = p; best.pt = pt; }
    }
    return best;
}

// Trava a mira no melhor alvo que está agora dentro do círculo de FOV.
extern "C" bool Aim_LockAcquire(void) {
    if (!s_localPlayer) return false;
    Il2CppObject* cam = GetMainCamera();
    if (!cam) return false;
    AimTarget t = SelectAimTarget(cam);
    if (!t.player) return false;
    s_lockedTarget = t.player;
    g_cheat.aimLock = true;
    PG3D_Log("[pg3d_tweak] LOCK: alvo=%p dist_do_centro=%.1fpt", (void*)t.player, t.pt.dist);
    return true;
}

extern "C" void Aim_LockRelease(void) {
    s_lockedTarget = nullptr;
    g_cheat.aimLock = false;
}

// Rotaciona o myCameraContainer do local player (PG3D lê o look do touch, não de mouse).
// Cabeça: Transform.LookAt(Transform) — caminho que já funcionava. Outras partes:
// Transform.set_rotation(LookRotation(dir, up)), equivalente a um LookAt num ponto.
static MethodInfo* meth_Transform_LookAt = nullptr;

// Limite de pitch (graus) acima do qual NÃO giramos a câmera neste frame: protege
// contra a inversão de joystick relatada quando o LookAt força ~90° de pitch.
// Valor não calibrado (primeiro lugar para apertar/afrouxar se ainda inverter).
static constexpr float kMaxAimPitchDeg = 75.0f;

static bool GetTransformRotation(Il2CppObject* tr, Quaternion& out) {
    ResolveManagedHelpers();
    if (!tr || !s_mGetRot || !g_il2cpp.runtime_invoke) return false;
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mGetRot, tr, nullptr, &ex);
    if (!ret || ex) return false;
    out = Field<Quaternion>(ret, 0x10);
    return std::isfinite(out.x) && std::isfinite(out.w);
}

// child está na hierarquia de parent? (cacheado: só reavalia se os objetos mudarem)
static bool IsDescendantOf(Il2CppObject* child, Il2CppObject* parent) {
    static Il2CppObject* cachedChild = nullptr;
    static Il2CppObject* cachedParent = nullptr;
    static bool cachedResult = false;
    if (child == cachedChild && parent == cachedParent) return cachedResult;
    cachedChild = child;
    cachedParent = parent;
    cachedResult = false;
    if (s_mIsChildOf && g_il2cpp.runtime_invoke) {
        void* args[1] = { parent };
        void* ex = nullptr;
        Il2CppObject* ret = g_il2cpp.runtime_invoke(s_mIsChildOf, child, args, &ex);
        cachedResult = ret && !ex && Field<bool>(ret, 0x10);
    }
    PG3D_Log("[pg3d_tweak] AIMBODY: myCameraContainer=%p IsChildOf(myPlayerTransform=%p) = %d (IsChildOf=%p)",
             (void*)child, (void*)parent, (int)cachedResult, (void*)s_mIsChildOf);
    return cachedResult;
}

// Diagnóstico do joystick invertido: yaw do corpo vs yaw do container da câmera.
// Se, com a mira desligada, a diferença ficar ≠ 0 depois de usar a mira, a mira
// deixou o container "torto" em relação ao corpo.
static void LogYaw() {
    if (!s_localPlayer) return;
    Il2CppObject* bodyTr = Field<Il2CppObject*>(s_localPlayer, PlayerMove::myPlayerTransform);
    Il2CppObject* cont   = Field<Il2CppObject*>(s_localPlayer, 0x478);
    Quaternion qb, qc;
    if (!GetTransformRotation(bodyTr, qb) || !GetTransformRotation(cont, qc)) return;
    float yb = AM_QuatYawDeg(qb), yc = AM_QuatYawDeg(qc);
    PG3D_Log("[pg3d_tweak] YAW: corpo=%.1f container=%.1f dif=%.1f | aimbot=%d aimLock=%d corpoYaw=%d",
             yb, yc, AM_WrapDeg(yc - yb), (int)g_cheat.aimbot, (int)g_cheat.aimLock,
             (int)g_cheat.aimBodyYaw);
}

static void AimAtPoint(Il2CppObject* localPlayer, Il2CppObject* targetPlayer, const AimPoint& pt) {
    if (!localPlayer || !targetPlayer) return;
    // 0x478 = myCameraContainer (confirmado contra o dump.cs, ver offsets.h).
    Il2CppObject* camContainer = Field<Il2CppObject*>(localPlayer, 0x478);
    if (!camContainer) return;

    Vector3 origin = GetTransformPosition(camContainer);
    Vector3 d = AM_Sub(pt.world, origin);
    float horiz = std::sqrt(d.x * d.x + d.z * d.z);
    bool bodyYawed = false;
    float pitchDeg = std::atan2(d.y, horiz) * (180.0f / (float)M_PI);
    if (std::fabs(pitchDeg) > kMaxAimPitchDeg) {
        static int s_skipLogCnt = 0;
        if (s_skipLogCnt++ % 60 == 0) {
            PG3D_Log("[pg3d_tweak] AIMAT: pulando neste frame, pitch=%.1f graus (limite=%.1f) "
                     "para evitar inversao de joystick", pitchDeg, kMaxAimPitchDeg);
        }
        return;
    }

    // Joystick invertido: o jogo move o personagem relativo ao CORPO (hipótese a
    // confirmar com as linhas YAW/AIMBODY do log), mas só girávamos o container da
    // câmera (inclusive o yaw), deixando view e corpo em direções diferentes. Aqui o
    // yaw vai para o corpo (myPlayerTransform) e o container só completa o pitch.
    // Só vale se o container for filho do corpo; senão cai no comportamento antigo.
    Il2CppObject* bodyTr = Field<Il2CppObject*>(localPlayer, PlayerMove::myPlayerTransform);
    if (g_cheat.aimBodyYaw && bodyTr && s_mSetRot && horiz > 1e-3f &&
        IsDescendantOf(camContainer, bodyTr)) {
        Quaternion qy;
        if (AM_LookRotation(Vector3{d.x, 0.0f, d.z}, Vector3{0, 1, 0}, qy)) {
            void* yargs[1] = { &qy };
            void* yex = nullptr;
            g_il2cpp.runtime_invoke(s_mSetRot, bodyTr, yargs, &yex);
            bodyYawed = (yex == nullptr);
            if (bodyYawed) {
                // o container mudou de posição junto com o corpo: recalcula a direção
                origin = GetTransformPosition(camContainer);
                d = AM_Sub(pt.world, origin);
            }
        }
    }

    Il2CppObject* headTr = Field<Il2CppObject*>(targetPlayer, PlayerMove::headTransform);
    void* ex = nullptr;
    const char* path = "?";
    if (pt.isHead && meth_Transform_LookAt && headTr) {
        path = "LookAt(cabeca)";
        void* args[1] = { headTr };
        g_il2cpp.runtime_invoke(meth_Transform_LookAt, camContainer, args, &ex);
    } else if (s_mSetRot) {
        Quaternion q;
        if (!AM_LookRotation(d, Vector3{0, 1, 0}, q)) return;
        path = "set_rotation";
        void* args[1] = { &q };
        g_il2cpp.runtime_invoke(s_mSetRot, camContainer, args, &ex);
    } else if (meth_Transform_LookAt && headTr) {
        path = "LookAt(cabeca, fallback: set_rotation indisponivel)";
        void* args[1] = { headTr };
        g_il2cpp.runtime_invoke(meth_Transform_LookAt, camContainer, args, &ex);
    } else {
        return;
    }

    static int s_aimLogCnt = 0;
    if (s_aimLogCnt++ % 300 == 0) {
        PG3D_Log("[pg3d_tweak] AIMAT: local=%p camContainer=%p alvo=%p via %s corpoYaw=%d", (void*)localPlayer,
                 (void*)camContainer, (void*)targetPlayer, path, (int)bodyYawed);
    }
    if (ex) {
        static bool s_exLogged = false;
        if (!s_exLogged) {
            s_exLogged = true;
            PG3D_Log("[pg3d_tweak] AIMAT: rotacao lancou excecao (ex=%p) via %s", ex, path);
        }
    }
}

// ---- Calibração do ESP/mira: mede a altura cabeça-raiz de um alvo real ----
static void LogCalib() {
    std::vector<Il2CppObject*> live;
    LivePlayers(live);
    for (Il2CppObject* p : live) {
        if (p == s_localPlayer) continue;
        Il2CppObject* headTr = Field<Il2CppObject*>(p, PlayerMove::headTransform);
        Il2CppObject* bodyTr = Field<Il2CppObject*>(p, PlayerMove::myPlayerTransform);
        if (!headTr || !bodyTr) continue;
        Vector3 h = GetTransformPosition(headTr);
        Vector3 r = GetTransformPosition(bodyTr);
        PG3D_Log("[pg3d_tweak] CALIB: alvo=%p head.y-root.y=%.2f head=(%.2f,%.2f,%.2f) root=(%.2f,%.2f,%.2f) vivos=%zu",
                 (void*)p, h.y - r.y, h.x, h.y, h.z, r.x, r.y, r.z, live.size());
        break;
    }
}

// ---- Descoberta do campo de time (medição, não suposição) ----
// O teamcheck por outline sempre dava "desconhecido" (os dois outlines com
// enabled=0). Em vez de inventar um offset, lista TODOS os campos de Player_move_c
// (e das classes pai) em pg3d_fields.txt e loga o valor dos campos escalares com
// nome parecido com time/comando/aliado/bot para o local player e até 3 outros.
static bool FmtScalar(Il2CppObject* o, size_t off, const char* tn, char* out, size_t n) {
    ptrdiff_t po = (ptrdiff_t)off;
    if (!strcmp(tn, "System.Boolean") || !strcmp(tn, "System.Byte") || !strcmp(tn, "System.SByte"))
        { snprintf(out, n, "%u", (unsigned)Field<uint8_t>(o, po)); return true; }
    if (!strcmp(tn, "System.Int16") || !strcmp(tn, "System.UInt16"))
        { snprintf(out, n, "%d", (int)Field<int16_t>(o, po)); return true; }
    if (!strcmp(tn, "System.Int32") || !strcmp(tn, "System.UInt32"))
        { snprintf(out, n, "%d", (int)Field<int32_t>(o, po)); return true; }
    if (!strcmp(tn, "System.Int64") || !strcmp(tn, "System.UInt64"))
        { snprintf(out, n, "%lld", (long long)Field<int64_t>(o, po)); return true; }
    if (!strcmp(tn, "System.Single"))
        { snprintf(out, n, "%.2f", (double)Field<float>(o, po)); return true; }
    return false;
}

std::string Player_GetNickname(Il2CppObject* player); // definida mais abaixo (linkage C++)

static bool s_teamDumpRequested = false;
extern "C" void Diag_RequestTeamDump(void) { s_teamDumpRequested = true; }

static bool IsIntLike(const char* tn) {
    return !strcmp(tn, "System.Boolean") || !strcmp(tn, "System.Byte") || !strcmp(tn, "System.SByte") ||
           !strcmp(tn, "System.Int16") || !strcmp(tn, "System.UInt16") ||
           !strcmp(tn, "System.Int32") || !strcmp(tn, "System.UInt32");
}

// Campo estático: o "offset" dele não é de instância (ler em obj+offset daria lixo).
static bool FieldIsStatic(Il2CppField* fl) {
    return g_il2cpp.field_get_flags && (g_il2cpp.field_get_flags(fl) & 0x10) != 0; // FIELD_ATTRIBUTE_STATIC
}

// Campo de referência para uma classe do jogo (não valuetype, não System/UnityEngine,
// não array/genérico): seguro de seguir um nível para dentro quando o objeto é vivo.
static bool IsGameRefType(const Il2CppType* ty, const char* tn) {
    if (!g_il2cpp.class_from_type || !g_il2cpp.class_is_valuetype || !g_il2cpp.field_get_flags) return false;
    if (!strncmp(tn, "System.", 7) || !strncmp(tn, "UnityEngine.", 12)) return false;
    if (strpbrk(tn, "[`&*<")) return false;
    Il2CppClass* tc = g_il2cpp.class_from_type(ty);
    return tc && !g_il2cpp.class_is_valuetype(tc);
}

// Compara os campos escalares (bool/byte/short/int) de objs[0..n-1] (0 = local) e loga
// só os que DIFEREM entre os jogadores (ou têm nome de time). Os nomes do jogo são
// ofuscados, então o sinal de time se acha pela diferença entre aliados e inimigos.
// Um nível de profundidade: segue referências para classes do jogo.
static void DumpFieldsDiff(const std::string& prefix, Il2CppClass* cls, Il2CppObject** objs, int n,
                           int& logged, int depth, FILE* f) {
    static const char* const kKeys[] = { "team", "command", "ally", "enemy", "friend", "clan",
                                         "bot", "dead", "alive", "mine", "color" };
    for (Il2CppClass* k = cls; k; ) {
        void* it = nullptr;
        while (Il2CppField* fl = g_il2cpp.class_get_fields(k, &it)) {
            const char* name = g_il2cpp.field_get_name(fl);
            size_t off = g_il2cpp.field_get_offset(fl);
            const Il2CppType* ty = g_il2cpp.field_get_type(fl);
            char* tn = ty ? g_il2cpp.type_get_name(ty) : nullptr;
            if (!name || !tn) continue;
            if (off < 0x10 || FieldIsStatic(fl)) continue;
            if (f && depth == 0) fprintf(f, "0x%zx\t%s\t%s\n", off, tn, name);

            char vals[8][32];
            if (IsIntLike(tn) || (strcmp(tn, "System.Single") == 0 && depth == 0)) {
                bool key = false;
                for (const char* kw : kKeys) if (strcasestr(name, kw)) { key = true; break; }
                if (!IsIntLike(tn) && !key) continue; // floats só se o nome parecer de time
                bool ok = true, differs = false;
                for (int i = 0; i < n && ok; i++) {
                    ok = FmtScalar(objs[i], off, tn, vals[i], sizeof(vals[i]));
                    if (ok && i > 0 && strcmp(vals[i], vals[0]) != 0) differs = true;
                }
                if (!ok || (!differs && !key) || logged >= 600) continue;
                std::string joined;
                for (int i = 0; i < n; i++) { if (i) joined += ","; joined += vals[i]; }
                PG3D_Log("[pg3d_tweak] TEAMDUMP: %s%s (%s @0x%zx) [%s]", prefix.c_str(), name, tn, off, joined.c_str());
                logged++;
            } else if (depth == 0 && IsGameRefType(ty, tn)) {
                Il2CppObject* refs[8];
                bool ok = g_il2cpp.object_get_class != nullptr;
                Il2CppClass* rk = nullptr;
                for (int i = 0; i < n && ok; i++) {
                    refs[i] = Field<Il2CppObject*>(objs[i], (ptrdiff_t)off);
                    if (!refs[i]) { ok = false; break; }
                    Il2CppClass* ck = g_il2cpp.object_get_class(refs[i]);
                    if (!ck || (rk && ck != rk)) { ok = false; break; }
                    rk = ck;
                }
                if (ok && rk) {
                    // Se for o MESMO objeto para todos, não distingue ninguém: pula.
                    bool same = true;
                    for (int i = 1; i < n; i++) if (refs[i] != refs[0]) same = false;
                    if (!same) DumpFieldsDiff(std::string(name) + "->", rk, refs, n, logged, 1, nullptr);
                }
            }
        }
        k = g_il2cpp.class_get_parent ? g_il2cpp.class_get_parent(k) : nullptr;
    }
}

static void DumpTeamCandidatesOnce() {
    static bool done = false;
    static double firstSeen = 0.0;
    static int tick = 0;
    if (done && !s_teamDumpRequested) return;
    if (tick++ % 60 != 0 && !s_teamDumpRequested) return;
    double now = NowSec();
    if (firstSeen == 0.0) firstSeen = now;
    if (now - firstSeen < 8.0 && !s_teamDumpRequested) return; // espera a partida estabilizar

    std::vector<Il2CppObject*> live, others;
    LivePlayers(live);
    for (Il2CppObject* p : live)
        if (p != s_localPlayer && others.size() < 5) others.push_back(p);
    if (others.empty()) return; // tenta de novo quando aparecer alguém
    done = true;
    s_teamDumpRequested = false;

    // Quem é quem: apelido (UTF-8) + estado dos outlines que o jogo usa para aliado/inimigo.
    PG3D_Log("[pg3d_tweak] TEAMDUMP: ordem dos valores = [local, outro0, outro1, ...]");
    PG3D_Log("[pg3d_tweak] TEAMDUMP: local=%p nick=%s", (void*)s_localPlayer,
             Player_GetNickname(s_localPlayer).c_str());
    for (size_t i = 0; i < others.size(); i++) {
        Il2CppObject* p = others[i];
        PG3D_Log("[pg3d_tweak] TEAMDUMP: outro%zu=%p nick=%s outline_aliado=%d outline_inimigo=%d", i, (void*)p,
                 Player_GetNickname(p).c_str(),
                 (int)GetBehaviourEnabled(Field<Il2CppObject*>(p, PlayerMove::allyOutline)),
                 (int)GetBehaviourEnabled(Field<Il2CppObject*>(p, PlayerMove::enemyOutline)));
    }

    if (!g_il2cpp.class_get_fields || !g_il2cpp.field_get_name || !g_il2cpp.field_get_offset ||
        !g_il2cpp.field_get_type || !g_il2cpp.type_get_name) {
        PG3D_Log("[pg3d_tweak] TEAMDUMP: API de campos indisponivel neste build");
        return;
    }
    char path[256];
    const char* tmp = NSTemporaryDirectory().fileSystemRepresentation;
    snprintf(path, sizeof(path), "%s/pg3d_fields.txt", tmp ? tmp : "/tmp");
    FILE* f = fopen(path, "w");
    PG3D_Log("[pg3d_tweak] TEAMDUMP: lista completa de campos em %s (local=%p, outros=%zu, profundidade=%s)",
             path, (void*)s_localPlayer, others.size(),
             (g_il2cpp.class_from_type && g_il2cpp.class_is_valuetype && g_il2cpp.field_get_flags) ? "1" : "0 (APIs de tipo ausentes)");

    Il2CppObject* objs[8];
    int n = 0;
    objs[n++] = s_localPlayer;
    for (Il2CppObject* p : others) objs[n++] = p;
    int logged = 0;
    DumpFieldsDiff("", cls_PlayerMove, objs, n, logged, 0, f);
    PG3D_Log("[pg3d_tweak] TEAMDUMP: fim (%d campos que diferem entre jogadores)", logged);
    if (f) fclose(f);
}

// ============================================================
//  Hook: Player_move_c.Update
// ============================================================
static void hook_PlayerUpdate(Il2CppObject* self, void* /*unused*/) {
    {
        static int s_updCnt = 0;
        if (s_updCnt++ % 600 == 0) {
            PG3D_Log("[pg3d_tweak] UPDATE #%d self=%p local=%p isMineMeth=%p cam=%p players=%zu aimbot=%d aimLock=%d esp=%d",
                     s_updCnt, (void*)self, (void*)s_localPlayer, (void*)meth_isMine,
                     (void*)s_mainCam, PlayerCount(), (int)g_cheat.aimbot, (int)g_cheat.aimLock,
                     (int)g_cheat.esp);
        }
    }
    // Registra/atualiza este player na lista global (marca "visto agora")
    AddPlayer(self);

    // Local player: entre os objetos com PhotonView.isMine, o que está colado na câmera
    if (IsLocalPlayer(self)) UpdateLocalCandidate(self);

    // Chama o original
    if (orig_PlayerUpdate) orig_PlayerUpdate(self, nullptr);

    // ---- Lógica do cheat (roda somente para o local player) ----
    if (self != s_localPlayer || !s_localPlayer) return;

    // Limpeza periódica de players ausentes
    static int cleanCnt = 0;
    if (++cleanCnt >= 60) { cleanCnt = 0; RemoveDeadPlayers(); }

    static int calibCnt = 0;
    if (calibCnt++ % 600 == 0) LogCalib();
    static int yawCnt = 0;
    if (yawCnt++ % 300 == 0) LogYaw();
    DumpTeamCandidatesOnce();

    Il2CppObject* camera = GetMainCamera();
    if (!camera) return;

    if (g_cheat.aimLock) {
        // Lock: fica no alvo travado até soltar ou o alvo sumir (mesmo fora do FOV).
        // Se o wallcheck estiver ligado e o alvo ficar atrás de parede, pausa a mira
        // (mantém a trava) até ele voltar a ficar visível.
        if (!s_lockedTarget || !IsPlayerLive(s_lockedTarget)) {
            PG3D_Log("[pg3d_tweak] LOCK: alvo %p sumiu, trava solta", (void*)s_lockedTarget);
            Aim_LockRelease();
        } else {
            Vector3 camPos = {0, 0, 0};
            bool haveCam = g_cheat.wallCheck && CameraPosition(camera, camPos);
            AimPoint pt;
            if (BestPointForPlayer(camera, s_lockedTarget, false, haveCam, camPos, pt))
                AimAtPoint(s_localPlayer, s_lockedTarget, pt);
        }
    } else if (g_cheat.aimbot) {
        AimTarget t = SelectAimTarget(camera);
        if (t.player) AimAtPoint(s_localPlayer, t.player, t.pt);
    }
}

// ============================================================
//  Hook: ClickerDetector.Update  → NOP (bypass anticheat)
// ============================================================
static void hook_ClickerUpdate(Il2CppObject* self, void* /*unused*/) {
    if (g_cheat.acBypass) return; // descarta detecção completamente
    if (orig_ClickerUpdate) orig_ClickerUpdate(self, nullptr);
}

// ============================================================
//  Hook: CheatDetectedBanner.Awake + Update → NOP
// ============================================================
static void hook_BannerAwake(Il2CppObject* self, void* /*unused*/) {
    // Não chama o original: banner nunca se inicializa
    if (!g_cheat.acBypass && orig_BannerAwake) orig_BannerAwake(self, nullptr);
}

static void hook_BannerUpdate(Il2CppObject* self, void* /*unused*/) {
    if (!g_cheat.acBypass && orig_BannerUpdate) orig_BannerUpdate(self, nullptr);
}

// ============================================================
//  Also zera os flags internos do ClickerDetector instance
//  chamado pelo hook de Awake do ClickerDetector
// ============================================================
static void (*orig_ClickerAwake)(Il2CppObject*, void*) = nullptr;
static void hook_ClickerAwake(Il2CppObject* self, void* unused) {
    if (orig_ClickerAwake) orig_ClickerAwake(self, unused);
    if (g_cheat.acBypass && self) {
        // Desabilita via campo enable @ 0x20
        Field<bool>(self, ClickerDetectorOff::enabled) = false;
    }
}

// ============================================================
//  Resolve icalls Unity pelo nome completo
// ============================================================
static void* ResolveIcall(const char* name) {
    if (!g_il2cpp.resolve_icall) return nullptr;
    return g_il2cpp.resolve_icall(name);
}

// ============================================================
//  Instala hook MSHookFunction num método IL2CPP
// ============================================================
static bool HookMethod(MethodInfo* method, void* hook, void** orig, const char* name = "?") {
    if (!method) { PG3D_Log("[pg3d_tweak] HOOK %s: MethodInfo NULL (metodo nao encontrado)", name); return false; }
    // O ponteiro para o código do método fica em method->methodPointer
    // Na struct MethodInfo do IL2CPP:
    //   offset 0x0 = Il2CppMethodPointer methodPointer
    void* methodPtr = *reinterpret_cast<void**>(method);
    if (!methodPtr) { PG3D_Log("[pg3d_tweak] HOOK %s: methodPointer NULL", name); return false; }
    MSHookFunction(methodPtr, hook, orig);
    PG3D_Log("[pg3d_tweak] HOOK %s: instalado em %p (orig=%p)", name, methodPtr, orig ? *orig : nullptr);
    return true;
}

// ============================================================
//  HookManager_Init – roda em thread separada depois de 2s
// ============================================================
static void* InitThread(void*) {
    PG3D_Log("[pg3d_tweak] InitThread iniciada, aguardando 2s...");
    sleep(2); // aguarda a GameAssembly terminar de inicializar
    PG3D_Log("[pg3d_tweak] InitThread acordou, tentando dlopen GameAssembly...");

    // 1. Localiza a API IL2CPP.
    //
    // IMPORTANTE (achado em 2026-11-20, confirmado pelo Info.plist real do
    // bundle): no iOS, o Unity IL2CPP NÃO gera um "GameAssembly.dylib"
    // separado como faz em Android/Windows/Mac. O código IL2CPP gerado é
    // compilado como lib estática e linkado DENTRO do executável principal
    // do app (aqui, o binário chamado "zombiegun3d" — CFBundleExecutable
    // confirmado no device). Por isso os dois dlopen por nome de arquivo
    // abaixo sempre falhavam: esse arquivo nunca existiu nesse bundle.
    //
    // Correção: pega um handle para a imagem principal do processo com
    // dlopen(NULL, ...) — isso sempre existe, não depende de nome de
    // arquivo nenhum — e usa RTLD_DEFAULT como fallback, que procura em
    // TODAS as imagens carregadas (inclui o executável principal).
    void* ga = dlopen(nullptr, RTLD_NOW);
    if (!ga) {
        PG3D_Log("[pg3d_tweak] ERRO: dlopen(NULL) falhou, usando RTLD_DEFAULT como fallback");
        ga = RTLD_DEFAULT;
    }

    // 2. Resolve API IL2CPP (handle da imagem principal, ou RTLD_DEFAULT)
    g_il2cpp.domain_get              = (t_il2cpp_domain_get)             dlsym(ga, "il2cpp_domain_get");
    g_il2cpp.domain_assembly_open    = (t_il2cpp_domain_assembly_open)   dlsym(ga, "il2cpp_domain_assembly_open");
    g_il2cpp.assembly_get_image      = (t_il2cpp_assembly_get_image)     dlsym(ga, "il2cpp_assembly_get_image");
    g_il2cpp.class_from_name         = (t_il2cpp_class_from_name)        dlsym(ga, "il2cpp_class_from_name");
    g_il2cpp.class_get_method_from_name = (t_il2cpp_class_get_method_from_name) dlsym(ga, "il2cpp_class_get_method_from_name");
    g_il2cpp.class_get_field_from_name  = (t_il2cpp_class_get_field_from_name)  dlsym(ga, "il2cpp_class_get_field_from_name");
    g_il2cpp.field_get_value         = (t_il2cpp_field_get_value)        dlsym(ga, "il2cpp_field_get_value");
    g_il2cpp.field_set_value         = (t_il2cpp_field_set_value)        dlsym(ga, "il2cpp_field_set_value");
    g_il2cpp.object_get_class        = (t_il2cpp_object_get_class)       dlsym(ga, "il2cpp_object_get_class");
    g_il2cpp.runtime_invoke          = (t_il2cpp_runtime_invoke)         dlsym(ga, "il2cpp_runtime_invoke");
    g_il2cpp.array_addr_with_size    = (t_il2cpp_array_addr_with_size)   dlsym(ga, "il2cpp_array_addr_with_size");
    g_il2cpp.array_length            = (t_il2cpp_array_length)           dlsym(ga, "il2cpp_array_length");
    g_il2cpp.string_new              = (t_il2cpp_string_new)             dlsym(ga, "il2cpp_string_new");
    g_il2cpp.resolve_icall           = (t_resolve_icall)                 dlsym(ga, "il2cpp_resolve_icall");

    // Se o handle da imagem principal não resolveu nada (os 3 símbolos
    // essenciais ainda nulos), tenta de novo com RTLD_DEFAULT antes de
    // desistir — cobre o caso de dlopen(NULL) ter devolvido um handle
    // "válido" mas que por algum motivo de symbol visibility não enxerga
    // os símbolos il2cpp_* (acontece se eles foram exportados só via
    // RTLD_DEFAULT e não pelo próprio handle da main image).
    if ((!g_il2cpp.domain_get || !g_il2cpp.class_from_name || !g_il2cpp.runtime_invoke)
        && ga != RTLD_DEFAULT) {
        PG3D_Log("[pg3d_tweak] handle da main image não resolveu il2cpp_*, tentando RTLD_DEFAULT");
        g_il2cpp.domain_get              = (t_il2cpp_domain_get)             dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
        g_il2cpp.domain_assembly_open    = (t_il2cpp_domain_assembly_open)   dlsym(RTLD_DEFAULT, "il2cpp_domain_assembly_open");
        g_il2cpp.assembly_get_image      = (t_il2cpp_assembly_get_image)     dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
        g_il2cpp.class_from_name         = (t_il2cpp_class_from_name)        dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
        g_il2cpp.class_get_method_from_name = (t_il2cpp_class_get_method_from_name) dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
        g_il2cpp.class_get_field_from_name  = (t_il2cpp_class_get_field_from_name)  dlsym(RTLD_DEFAULT, "il2cpp_class_get_field_from_name");
        g_il2cpp.field_get_value         = (t_il2cpp_field_get_value)        dlsym(RTLD_DEFAULT, "il2cpp_field_get_value");
        g_il2cpp.field_set_value         = (t_il2cpp_field_set_value)        dlsym(RTLD_DEFAULT, "il2cpp_field_set_value");
        g_il2cpp.object_get_class        = (t_il2cpp_object_get_class)       dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
        g_il2cpp.runtime_invoke          = (t_il2cpp_runtime_invoke)         dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
        g_il2cpp.array_addr_with_size    = (t_il2cpp_array_addr_with_size)   dlsym(RTLD_DEFAULT, "il2cpp_array_addr_with_size");
        g_il2cpp.array_length            = (t_il2cpp_array_length)           dlsym(RTLD_DEFAULT, "il2cpp_array_length");
        g_il2cpp.string_new              = (t_il2cpp_string_new)             dlsym(RTLD_DEFAULT, "il2cpp_string_new");
        g_il2cpp.resolve_icall           = (t_resolve_icall)                 dlsym(RTLD_DEFAULT, "il2cpp_resolve_icall");
    }

    // API de introspecção (opcional): overload por assinatura e lista de campos.
    // Se faltar, só os recursos que dependem dela ficam indisponíveis (logado abaixo).
    g_il2cpp.class_get_methods      = (t_il2cpp_class_get_methods)      dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
    g_il2cpp.method_get_name        = (t_il2cpp_method_get_name)        dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
    g_il2cpp.method_get_param_count = (t_il2cpp_method_get_param_count) dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
    g_il2cpp.method_get_param       = (t_il2cpp_method_get_param)       dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");
    g_il2cpp.type_get_name          = (t_il2cpp_type_get_name)          dlsym(RTLD_DEFAULT, "il2cpp_type_get_name");
    g_il2cpp.class_get_fields       = (t_il2cpp_class_get_fields)       dlsym(RTLD_DEFAULT, "il2cpp_class_get_fields");
    g_il2cpp.field_get_name         = (t_il2cpp_field_get_name)         dlsym(RTLD_DEFAULT, "il2cpp_field_get_name");
    g_il2cpp.field_get_offset       = (t_il2cpp_field_get_offset)       dlsym(RTLD_DEFAULT, "il2cpp_field_get_offset");
    g_il2cpp.field_get_type         = (t_il2cpp_field_get_type)         dlsym(RTLD_DEFAULT, "il2cpp_field_get_type");
    g_il2cpp.class_get_parent       = (t_il2cpp_class_get_parent)       dlsym(RTLD_DEFAULT, "il2cpp_class_get_parent");
    g_il2cpp.field_get_flags        = (t_il2cpp_field_get_flags)        dlsym(RTLD_DEFAULT, "il2cpp_field_get_flags");
    g_il2cpp.class_from_type        = (t_il2cpp_class_from_type)        dlsym(RTLD_DEFAULT, "il2cpp_class_from_type");
    g_il2cpp.class_is_valuetype     = (t_il2cpp_class_is_valuetype)     dlsym(RTLD_DEFAULT, "il2cpp_class_is_valuetype");
    PG3D_Log("[pg3d_tweak] INTROSPECCAO: field_get_flags=%p class_from_type=%p class_is_valuetype=%p",
             (void*)g_il2cpp.field_get_flags, (void*)g_il2cpp.class_from_type,
             (void*)g_il2cpp.class_is_valuetype);
    PG3D_Log("[pg3d_tweak] INTROSPECCAO: class_get_methods=%p method_get_param=%p type_get_name=%p class_get_fields=%p field_get_offset=%p class_get_parent=%p",
             (void*)g_il2cpp.class_get_methods, (void*)g_il2cpp.method_get_param,
             (void*)g_il2cpp.type_get_name, (void*)g_il2cpp.class_get_fields,
             (void*)g_il2cpp.field_get_offset, (void*)g_il2cpp.class_get_parent);

    if (!g_il2cpp.domain_get || !g_il2cpp.class_from_name || !g_il2cpp.runtime_invoke) {
        PG3D_Log("[pg3d_tweak] ERRO: API IL2CPP incompleta (domain_get=%p class_from_name=%p runtime_invoke=%p)",
                 (void*)g_il2cpp.domain_get, (void*)g_il2cpp.class_from_name, (void*)g_il2cpp.runtime_invoke);
        return nullptr;
    }

    PG3D_Log("[pg3d_tweak] API: assembly_get_image=%p get_method=%p get_field=%p array_len=%p array_addr=%p string_new=%p resolve_icall=%p",
             (void*)g_il2cpp.assembly_get_image, (void*)g_il2cpp.class_get_method_from_name,
             (void*)g_il2cpp.class_get_field_from_name, (void*)g_il2cpp.array_length,
             (void*)g_il2cpp.array_addr_with_size, (void*)g_il2cpp.string_new,
             (void*)g_il2cpp.resolve_icall);

    // 3. Obtém a imagem Assembly-CSharp.dll
    Il2CppDomain*   domain = g_il2cpp.domain_get();
    Il2CppAssembly* asm_csharp = g_il2cpp.domain_assembly_open(domain, "Assembly-CSharp");
    if (!asm_csharp) {
        PG3D_Log("[pg3d_tweak] ERRO: Assembly-CSharp não encontrada");
        return nullptr;
    }
    Il2CppImage* img = g_il2cpp.assembly_get_image(asm_csharp);

    // 4. Encontra classes
    // Player_move_c está no namespace "" (global)
    cls_PlayerMove  = g_il2cpp.class_from_name(img, "",  "Player_move_c");
    cls_ClickerDet  = g_il2cpp.class_from_name(img, "",  "ClickerDetector");
    cls_CheatBanner = g_il2cpp.class_from_name(img, "",  "CheatDetectedBanner");

    // Camera e Transform vêm do UnityEngine
    Il2CppAssembly* asm_ue = g_il2cpp.domain_assembly_open(domain, "UnityEngine.CoreModule");
    Il2CppImage*    img_ue = asm_ue ? g_il2cpp.assembly_get_image(asm_ue) : nullptr;
    if (img_ue) {
        cls_Camera    = g_il2cpp.class_from_name(img_ue, "UnityEngine", "Camera");
        cls_Transform = g_il2cpp.class_from_name(img_ue, "UnityEngine", "Transform");
        cls_Object    = g_il2cpp.class_from_name(img_ue, "UnityEngine", "Object");
    }

    if (img_ue) {
        cls_Behaviour = g_il2cpp.class_from_name(img_ue, "UnityEngine", "Behaviour");
        if (cls_Behaviour) s_mGetEnabled = g_il2cpp.class_get_method_from_name(cls_Behaviour, "get_enabled", 0);
    }
    PG3D_Log("[pg3d_tweak] CLASSES: Player_move_c=%p ClickerDetector=%p CheatDetectedBanner=%p | UnityEngine.CoreModule=%p Camera=%p Transform=%p Object=%p Behaviour=%p get_enabled=%p",
             (void*)cls_PlayerMove, (void*)cls_ClickerDet, (void*)cls_CheatBanner,
             (void*)asm_ue, (void*)cls_Camera, (void*)cls_Transform, (void*)cls_Object,
             (void*)cls_Behaviour, (void*)s_mGetEnabled);

    // UnityEngine.Physics mora em UnityEngine.PhysicsModule, não no CoreModule.
    {
        Il2CppAssembly* asm_phys = g_il2cpp.domain_assembly_open(domain, "UnityEngine.PhysicsModule");
        Il2CppImage*    img_phys = asm_phys ? g_il2cpp.assembly_get_image(asm_phys) : nullptr;
        if (img_phys) {
            cls_Physics = g_il2cpp.class_from_name(img_phys, "UnityEngine", "Physics");
            if (cls_Physics) s_mRaycast = g_il2cpp.class_get_method_from_name(cls_Physics, "Raycast", 3);
        }
        PG3D_Log("[pg3d_tweak] PHYSICS: UnityEngine.PhysicsModule=%p Physics=%p Raycast(3 args, NAO CONFIRMADO)=%p",
                 (void*)asm_phys, (void*)cls_Physics, (void*)s_mRaycast);
        if (cls_Physics) {
            // Assinatura exata (tipos dos parâmetros), não contagem de argumentos.
            static const char* const kLinecastSig[2] = { "UnityEngine.Vector3", "UnityEngine.Vector3" };
            s_mLinecast = FindMethodBySig(cls_Physics, "Linecast", kLinecastSig, 2);
            LogOverloads(cls_Physics, "Linecast");
            LogOverloads(cls_Physics, "Raycast");
        }
        PG3D_Log("[pg3d_tweak] PHYSICS: Linecast(Vector3,Vector3) por assinatura exata=%p", (void*)s_mLinecast);
    }

    if (!cls_PlayerMove) {
        PG3D_Log("[pg3d_tweak] ERRO: Player_move_c não encontrada");
        return nullptr;
    }

    // 5. Resolve icalls Unity
    // Nomes de icall no formato "UnityEngine.Transform::get_position_Injected"
    icall_Transform_get_position = (fn_Transform_GetPos) ResolveIcall(
        "UnityEngine.Transform::get_position_Injected");
    icall_Camera_WorldToScreen = (fn_Camera_W2S) ResolveIcall(
        "UnityEngine.Camera::WorldToScreenPoint_Injected");
    icall_Camera_GetFov = (fn_Camera_GetFov) ResolveIcall(
        "UnityEngine.Camera::get_fieldOfView");
    icall_Camera_SetFov = (fn_Camera_SetFov) ResolveIcall(
        "UnityEngine.Camera::set_fieldOfView");

    // FindObjectsOfType<T> via icall
    icall_FindObjectsAll = (fn_FindObjectsOfTypeAll) ResolveIcall(
        "UnityEngine.Object::FindObjectsOfType_internal");
    icall_GetType = (fn_GetType) ResolveIcall(
        "UnityEngine.RuntimeTypeHandle::GetRuntimeTypeFromHandle");

    PG3D_Log("[pg3d_tweak] ICALLS: Transform.get_position_Injected=%p Camera.WorldToScreenPoint_Injected=%p Camera.get_fieldOfView=%p Camera.set_fieldOfView=%p Object.FindObjectsOfType_internal=%p RuntimeTypeHandle.GetRuntimeTypeFromHandle=%p",
             (void*)icall_Transform_get_position, (void*)icall_Camera_WorldToScreen,
             (void*)icall_Camera_GetFov, (void*)icall_Camera_SetFov,
             (void*)icall_FindObjectsAll, (void*)icall_GetType);

    // 6. Encontra e hooka métodos
    // Player_move_c.Update (sem parâmetros → param_count = 0)
    meth_PlayerUpdate = g_il2cpp.class_get_method_from_name(cls_PlayerMove, "Update", 0);
    HookMethod(meth_PlayerUpdate, (void*)hook_PlayerUpdate, (void**)&orig_PlayerUpdate, "Player_move_c.Update");

    // isMine getter no PhotonView
    // PhotonView está em Photon.MonoBehaviour derivado – buscamos a imagem certa
    // PhotonView: a assembly depende da versao do PUN; sonda candidatas e loga
    // o resultado de cada uma (nenhuma e assumida como correta).
    {
        static const char* kPhotonAsms[]  = { "Assembly-CSharp-firstpass", "Photon3Unity3D", "Assembly-CSharp" };
        static const char* kIsMineNames[] = { "get_isMine", "get_IsMine" };
        for (const char* an : kPhotonAsms) {
            Il2CppAssembly* a = g_il2cpp.domain_assembly_open(domain, an);
            Il2CppImage* im = a ? g_il2cpp.assembly_get_image(a) : nullptr;
            Il2CppClass* cpv = im ? g_il2cpp.class_from_name(im, "", "PhotonView") : nullptr;
            PG3D_Log("[pg3d_tweak] PHOTON: assembly=%s asm=%p PhotonView=%p", an, (void*)a, (void*)cpv);
            if (!cpv) continue;
            for (const char* mn : kIsMineNames) {
                MethodInfo* m = g_il2cpp.class_get_method_from_name(cpv, mn, 0);
                PG3D_Log("[pg3d_tweak] PHOTON:   %s = %p", mn, (void*)m);
                if (m && !meth_isMine) meth_isMine = m;
            }
        }
        PG3D_Log("[pg3d_tweak] PHOTON: meth_isMine final=%p", (void*)meth_isMine);
    }

    // ClickerDetector hooks
    if (cls_ClickerDet) {
        MethodInfo* m_cu = g_il2cpp.class_get_method_from_name(cls_ClickerDet, "Update", 0);
        HookMethod(m_cu, (void*)hook_ClickerUpdate, (void**)&orig_ClickerUpdate, "ClickerDetector.Update");

        MethodInfo* m_ca = g_il2cpp.class_get_method_from_name(cls_ClickerDet, "Awake", 0);
        HookMethod(m_ca, (void*)hook_ClickerAwake, (void**)&orig_ClickerAwake, "ClickerDetector.Awake");
    }

    // CheatDetectedBanner hooks
    if (cls_CheatBanner) {
        MethodInfo* m_ba = g_il2cpp.class_get_method_from_name(cls_CheatBanner, "Awake", 0);
        HookMethod(m_ba, (void*)hook_BannerAwake, (void**)&orig_BannerAwake, "CheatDetectedBanner.Awake");

        MethodInfo* m_bu = g_il2cpp.class_get_method_from_name(cls_CheatBanner, "Update", 0);
        HookMethod(m_bu, (void*)hook_BannerUpdate, (void**)&orig_BannerUpdate, "CheatDetectedBanner.Update");
    }

    // Transform.LookAt(Transform target) → param_count = 1
    if (cls_Transform) {
        meth_Transform_LookAt = g_il2cpp.class_get_method_from_name(cls_Transform, "LookAt", 1);
    }

    g_il2cpp.ready   = true;
    g_cheat.initialized = true;
    PG3D_Log("[pg3d_tweak] Iniciado com sucesso (log em: %s)", PG3D_LogPath());
    return nullptr;
}

// ============================================================
//  API pública
// ============================================================
void HookManager_Init(void) {
    pthread_t t;
    pthread_create(&t, nullptr, InitThread, nullptr);
    pthread_detach(t);
}

bool HookManager_IsReady(void) {
    return g_cheat.initialized;
}

// ============================================================
//  Helpers exportados para o Menu (ESP drawing)
// ============================================================

// Copia snapshot dos players para o caller (thread-safe)
extern "C" void Players_GetSnapshot(Il2CppObject** buf, int* count, int maxBuf) {
    // Só players vistos recentemente (ver PlayerEntry): sem "fantasmas" no ESP.
    std::vector<Il2CppObject*> live;
    LivePlayers(live);
    int n = (int)std::min((size_t)maxBuf, live.size());
    for (int i = 0; i < n; i++) buf[i] = live[i];
    *count = n;
}

extern "C" Il2CppObject* Player_GetLocalPlayer(void) {
    return s_localPlayer;
}

extern "C" Il2CppObject* Camera_GetMain(void) {
    return GetMainCamera();
}

extern "C" bool Camera_WorldToScreen_ext(Il2CppObject* cam, Vector3 world, Vector3* out) {
    return WorldToScreen(cam, world, *out);
}

extern "C" Vector3 Transform_GetPos_ext(Il2CppObject* tr) {
    return GetTransformPosition(tr);
}

// Lê nickname via TextMesh.text icall
static MethodInfo* meth_TextMesh_getText = nullptr;
// Linkage C++ normal (não extern "C"): std::string não é ABI-compatível com C
// no retorno por valor. A declaração em Menu.mm já está fora do bloco extern "C".
std::string Player_GetNickname(Il2CppObject* player) {
    if (!player) return "";
    // nickLabel @ PlayerMove::nickLabel é um UnityEngine.TextMesh
    Il2CppObject* lbl = Field<Il2CppObject*>(player, PlayerMove::nickLabel);
    if (!lbl) return "";
    if (!meth_TextMesh_getText) {
        // Busca lazy na classe TextMesh
        if (!g_il2cpp.ready) return "";
        Il2CppDomain*   dom = g_il2cpp.domain_get();
        Il2CppAssembly* asm_ue = g_il2cpp.domain_assembly_open(dom, "UnityEngine.TextRenderingModule");
        if (!asm_ue) return "";
        Il2CppImage* img = g_il2cpp.assembly_get_image(asm_ue);
        Il2CppClass* cls = g_il2cpp.class_from_name(img, "UnityEngine", "TextMesh");
        if (cls) meth_TextMesh_getText = g_il2cpp.class_get_method_from_name(cls, "get_text", 0);
    }
    if (!meth_TextMesh_getText) return "";
    void* ex = nullptr;
    Il2CppObject* ret = g_il2cpp.runtime_invoke(meth_TextMesh_getText, lbl, nullptr, &ex);
    if (!ret) return "";
    return Il2CppStringToStd(reinterpret_cast<Il2CppString*>(ret));
}

// Lê health do player via PlayerDamageable (campo a 0x778 em Player_move_c)
// PlayerDamageable herda de MonoBehaviour; seu campo health está em BaseDummy @ 0x20
// ou em PlayerDamageable diretamente – usamos o BaseDummy offset.
extern "C" float Player_GetHealth(Il2CppObject* player) {
    if (!player) return 0.0f;
    Il2CppObject* damageable = Field<Il2CppObject*>(player, 0x778); // PlayerDamageable
    if (!damageable) return 0.0f;
    return Field<float>(damageable, BaseDummyOff::health);
}

extern "C" bool Player_IsLocal(Il2CppObject* player) {
    return player == s_localPlayer;
}
