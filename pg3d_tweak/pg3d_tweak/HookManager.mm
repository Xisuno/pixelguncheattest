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

// ============================================================
//  Globals
// ============================================================
Il2CppAPI    g_il2cpp      = {};
CheatState   g_cheat       = { false, false, 15.0f, false, false, true, false };

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
static Vector3 GetTransformPosition(Il2CppObject* transform) {
    Vector3 pos = {0,0,0};
    if (transform && icall_Transform_get_position)
        icall_Transform_get_position(transform, &pos);
    return pos;
}

static bool WorldToScreen(Il2CppObject* camera, Vector3 world, Vector3& out) {
    if (!camera || !icall_Camera_WorldToScreen) return false;
    icall_Camera_WorldToScreen(camera, &world, &out);
    // se z < 0 está atrás da câmera
    return out.z > 0.0f;
}

// Cache da câmera principal: busca a cada N frames
static Il2CppObject* s_mainCam      = nullptr;
static int           s_camFrameCnt  = 0;

static Il2CppObject* GetMainCamera() {
    if (s_camFrameCnt++ < 30 && s_mainCam) return s_mainCam;
    s_camFrameCnt = 0;

    if (!icall_FindObjectsAll || !cls_Camera || !icall_GetType) {
        static bool s_camLogged = false;
        if (!s_camLogged) {
            s_camLogged = true;
            PG3D_Log("[pg3d_tweak] CAMERA: impossivel buscar (FindObjectsAll=%p cls_Camera=%p GetType=%p)",
                     (void*)icall_FindObjectsAll, (void*)cls_Camera, (void*)icall_GetType);
        }
        return s_mainCam;
    }

    void* camType = icall_GetType(cls_Camera);
    if (!camType) return s_mainCam;

    Il2CppArray* arr = icall_FindObjectsAll(camType, nullptr);
    if (!arr) return s_mainCam;

    uintptr_t len = g_il2cpp.array_length(arr);
    for (uintptr_t i = 0; i < len; i++) {
        Il2CppObject** elem = reinterpret_cast<Il2CppObject**>(
            g_il2cpp.array_addr_with_size(arr, sizeof(void*), i));
        if (!elem || !*elem) continue;
        // Pega a primeira câmera encontrada (Camera.main não tem icall simples)
        s_mainCam = *elem;
        break;
    }
    return s_mainCam;
}

// ============================================================
//  Lista de players (atualizada no hook de PlayerUpdate)
// ============================================================
static std::vector<Il2CppObject*> s_players;
static pthread_mutex_t            s_playerMtx = PTHREAD_MUTEX_INITIALIZER;

static void AddPlayer(Il2CppObject* p) {
    pthread_mutex_lock(&s_playerMtx);
    for (auto& x : s_players) if (x == p) { pthread_mutex_unlock(&s_playerMtx); return; }
    s_players.push_back(p);
    pthread_mutex_unlock(&s_playerMtx);
}

static void RemoveDeadPlayers() {
    // chamado periodicamente no Update do local player
    // limpa ponteiros que não estão mais vivos (heurística: transform null)
    pthread_mutex_lock(&s_playerMtx);
    s_players.erase(
        std::remove_if(s_players.begin(), s_players.end(), [](Il2CppObject* p) {
            if (!p) return true;
            Il2CppObject* tr = Field<Il2CppObject*>(p, PlayerMove::myPlayerTransform);
            return tr == nullptr;
        }),
        s_players.end());
    pthread_mutex_unlock(&s_playerMtx);
}

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

struct AimTarget {
    Il2CppObject* player;
    Vector3       screenPos;
    float         distFromCenter;
};

static AimTarget SelectAimTarget(Il2CppObject* camera) {
    AimTarget best = { nullptr, {}, 1e9f };
    if (!camera) return best;

    // Centro da tela
    // UIScreen.mainScreen.bounds – usamos 1920/2 e 1080/2 como fallback
    // (o overlay corrige antes de desenhar)
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    float cx = (float)(screen.size.width  * scale) * 0.5f;
    float cy = (float)(screen.size.height * scale) * 0.5f;

    float fovRad = g_cheat.aimbotFov * (M_PI / 180.0f);
    // Comparação é feita abaixo via sinf(fovRad/2) contra a proporção
    // dist/screenLen (ver loop); não usamos cosFov aqui.

    pthread_mutex_lock(&s_playerMtx);
    std::vector<Il2CppObject*> copy = s_players;
    pthread_mutex_unlock(&s_playerMtx);

    for (Il2CppObject* p : copy) {
        if (!p || p == s_localPlayer) continue;

        Il2CppObject* headTr = Field<Il2CppObject*>(p, PlayerMove::headTransform);
        if (!headTr) continue;

        Vector3 headWS = GetTransformPosition(headTr);
        Vector3 ss;
        if (!WorldToScreen(camera, headWS, ss)) continue;

        float dx = ss.x - cx;
        float dy = ss.y - cy;
        float dist = sqrtf(dx*dx + dy*dy);

        // Checa se está dentro do FOV (em pixels)
        // alternativa: comparar cos do ângulo na tela
        float screenLen = sqrtf(cx*cx + cy*cy);
        if (dist / screenLen > sinf(fovRad * 0.5f)) continue;

        if (dist < best.distFromCenter) {
            best.player        = p;
            best.screenPos     = ss;
            best.distFromCenter= dist;
        }
    }
    return best;
}

// Envia toque simulado de look via UIApplication (aproximação simples):
// No PG3D o look é controlado por input touchscreen, não por mouse.
// A forma mais limpa é rotacionar o myCameraContainer do local player.
// Usamos o Transform.set_rotation ou LookAt via icall.
static MethodInfo* meth_Transform_LookAt = nullptr;

static void AimAtTarget(Il2CppObject* localPlayer, Il2CppObject* targetHeadTransform) {
    if (!localPlayer || !targetHeadTransform) return;

    // Pega o container de câmera do player local
    Il2CppObject* camContainer = Field<Il2CppObject*>(localPlayer, 0x478); // myCameraContainer @ 0x478
    if (!camContainer || !meth_Transform_LookAt) return;

    // Transform.LookAt(Transform target) recebe o Transform diretamente via icall/
    // runtime_invoke; não precisamos da posição em Vector3 aqui.
    void* args[1] = { targetHeadTransform };
    void* ex = nullptr;
    g_il2cpp.runtime_invoke(meth_Transform_LookAt, camContainer, args, &ex);
}

// ============================================================
//  Hook: Player_move_c.Update
// ============================================================
static void hook_PlayerUpdate(Il2CppObject* self, void* /*unused*/) {
    {
        static int s_updCnt = 0;
        if (s_updCnt++ % 600 == 0) {
            pthread_mutex_lock(&s_playerMtx);
            size_t np = s_players.size();
            pthread_mutex_unlock(&s_playerMtx);
            PG3D_Log("[pg3d_tweak] UPDATE #%d self=%p local=%p isMineMeth=%p cam=%p players=%zu aimbot=%d esp=%d",
                     s_updCnt, (void*)self, (void*)s_localPlayer, (void*)meth_isMine,
                     (void*)s_mainCam, np, (int)g_cheat.aimbot, (int)g_cheat.esp);
        }
    }
    // Registra este player na lista global
    AddPlayer(self);

    // Detecta o local player: aquele cujo PhotonView.isMine == true
    if (IsLocalPlayer(self)) {
        s_localPlayer = self;
    }

    // Chama o original
    if (orig_PlayerUpdate) orig_PlayerUpdate(self, nullptr);

    // ---- Lógica do cheat (roda somente para o local player) ----
    if (self != s_localPlayer || !s_localPlayer) return;

    // Limpeza periódica de players mortos
    static int cleanCnt = 0;
    if (++cleanCnt >= 60) { cleanCnt = 0; RemoveDeadPlayers(); }

    Il2CppObject* camera = GetMainCamera();
    if (!camera) return;

    // ---- Aimbot / AimLock ----
    if (g_cheat.aimbot || g_cheat.aimLock) {
        AimTarget target = SelectAimTarget(camera);
        if (target.player) {
            Il2CppObject* headTr = Field<Il2CppObject*>(target.player, PlayerMove::headTransform);
            AimAtTarget(s_localPlayer, headTr);
        }
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

    PG3D_Log("[pg3d_tweak] CLASSES: Player_move_c=%p ClickerDetector=%p CheatDetectedBanner=%p | UnityEngine.CoreModule=%p Camera=%p Transform=%p Object=%p",
             (void*)cls_PlayerMove, (void*)cls_ClickerDet, (void*)cls_CheatBanner,
             (void*)asm_ue, (void*)cls_Camera, (void*)cls_Transform, (void*)cls_Object);

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
    pthread_mutex_lock(&s_playerMtx);
    int n = (int)std::min((size_t)maxBuf, s_players.size());
    for (int i = 0; i < n; i++) buf[i] = s_players[i];
    *count = n;
    pthread_mutex_unlock(&s_playerMtx);
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
