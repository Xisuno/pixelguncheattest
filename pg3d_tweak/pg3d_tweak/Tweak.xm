// Tweak.xm
// Entry point do Theos tweak.
// Hooks no nível ObjC para detectar quando o jogo inicializa,
// depois delega para HookManager (IL2CPP) e Menu (UIKit).

#import <UIKit/UIKit.h>
#include "HookManager.h"
#include "Menu.h"

// ---- Detecta o início do UIApplicationDelegate do jogo ----
// O Pixel Gun 3D usa um AppDelegate normal.
// Hookamos application:didFinishLaunchingWithOptions: para garantir
// que o UIWindow do jogo existe antes de criarmos o overlay.

%hook UIApplication

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)opts {

    BOOL result = %orig;

    // Inicia o HookManager em background (resolve IL2CPP API)
    HookManager_Init();

    // Inicia o menu na main thread depois de um pequeno delay
    // (garante que a janela do jogo já existe)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Menu_Setup();
    });

    return result;
}

%end

// ---- Constructor ----
%ctor {
    // %ctor roda quando a dylib é injetada pelo Substrate.
    // Nada precisa ser feito aqui; tudo acontece no hook acima.
    NSLog(@"[pg3d_tweak] dylib carregada");
}
