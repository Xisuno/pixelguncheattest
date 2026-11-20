#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Inicializa o overlay UIKit com o menu e o ESP.
// Deve ser chamado na main thread depois do HookManager_Init.
void Menu_Setup(void);

#ifdef __cplusplus
}
#endif
