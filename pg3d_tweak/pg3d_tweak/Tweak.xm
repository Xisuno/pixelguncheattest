// Tweak.xm
// Entry point do Theos tweak.
// Dispara tudo direto do %ctor, sem depender de hookar o AppDelegate.
//
// Correção (2026-11-19): a versão anterior usava `%hook UIApplication` com
// `application:didFinishLaunchingWithOptions:`. Esse método NUNCA é
// implementado pela própria UIApplication — é o delegate do app quem o
// implementa (em jogo Unity/IL2CPP isso costuma ser `UnityAppController`,
// não `UIApplication`). Como a UIApplication nunca recebe essa mensagem
// nela mesma, o hook nunca disparava: a dylib carregava (log do %ctor
// aparecia), mas HookManager_Init()/Menu_Setup() nunca eram chamados e o
// menu nunca aparecia. Removido o %hook; tudo roda a partir do %ctor, que
// dispara garantidamente quando o Substrate injeta a dylib no processo.

#import <UIKit/UIKit.h>
#include <unistd.h>
#include "HookManager.h"
#include "Menu.h"

// ---- Constructor ----
%ctor {
    // %ctor roda quando a dylib é injetada pelo Substrate, bem antes de
    // UIApplicationMain. O dispatch_after abaixo só é efetivamente drenado
    // quando o run loop principal começar a rodar (depois de
    // UIApplicationMain), então é seguro agendar aqui mesmo sem UIWindow
    // existir ainda.
    // Log de diagnóstico: primeira linha que deve existir se o %ctor rodou
    // de fato dentro do processo do jogo. Se isso não aparecer nem no NSLog
    // nem no arquivo, a injeção nunca chegou a executar código nosso —
    // problema é no ElleKit/filtro/anti-tamper do jogo, não neste arquivo.
    PG3D_Log("[pg3d_tweak] %%ctor executando, pid=%d", getpid());

    // Inicia o HookManager em background (resolve IL2CPP API).
    // HookManager_Init() já tem um sleep(2) interno esperando a
    // GameAssembly terminar de inicializar.
    HookManager_Init();

    // Inicia o menu na main thread depois de um delay
    // (garante que a janela do jogo já existe).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        PG3D_Log("[pg3d_tweak] dispatch_after disparou, chamando Menu_Setup()");
        Menu_Setup();
    });
}
