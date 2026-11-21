// Menu.mm
// Overlay UIKit:
//   • Janela transparente no topo (windowLevel UIWindowLevelAlert+1)
//   • Botão flutuante (drag) para abrir/fechar o menu
//   • Menu com toggles: Aimbot, AimLock, FOV, ESP, AC Bypass
//   • CADisplayLink para redesenhar o ESP a cada frame
//
// O ESP é desenhado diretamente em drawRect: de um UIView sobreposto.

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include "HookManager.h"
#include "il2cpp_api.h"
#include "offsets.h"
#include <string>
#include <vector>

// ---- Declarações externas do HookManager ----
extern "C" {
    void     Players_GetSnapshot(Il2CppObject** buf, int* count, int maxBuf);
    Il2CppObject* Player_GetLocalPlayer(void);
    Il2CppObject* Camera_GetMain(void);
    bool     Camera_WorldToScreen_ext(Il2CppObject* cam, Vector3 world, Vector3* out);
    Vector3  Transform_GetPos_ext(Il2CppObject* tr);
    float    Player_GetHealth(Il2CppObject* player);
    bool     Player_IsLocal(Il2CppObject* player);
}

// Fora do extern "C", com linkage C++ normal
std::string Player_GetNickname(Il2CppObject* player);

// ============================================================
//  ESPView – redesenha sobre o jogo
// ============================================================
@interface ESPView : UIView
@end

@implementation ESPView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor   = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        // Acompanha o tamanho da janela (rotação) e redesenha quando muda.
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

// Informa ao HookManager o retângulo real do overlay: projeção, centro de mira e
// círculo de FOV passam a usar exatamente o mesmo espaço de coordenadas.
- (void)layoutSubviews {
    [super layoutSubviews];
    Overlay_SetSize((float)self.bounds.size.width, (float)self.bounds.size.height);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    // Círculo de FOV da mira (independe do ESP). Verde enquanto há alvo travado.
    if (g_cheat.showFov && (g_cheat.aimbot || g_cheat.aimLock || g_cheat.lockButton)) {
        CGFloat r  = (CGFloat)Aim_FovRadiusPoints();
        CGPoint c  = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        UIColor* col = g_cheat.aimLock ? [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.9]
                                       : [UIColor colorWithWhite:1.0 alpha:0.8];
        CGContextSetStrokeColorWithColor(ctx, col.CGColor);
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, r * 2.0, r * 2.0));
    }

    if (!g_cheat.esp || !HookManager_IsReady()) return;

    Il2CppObject* camera = Camera_GetMain();
    if (!camera) return;

    Il2CppObject* buf[256];
    int count = 0;
    Players_GetSnapshot(buf, &count, 256);

    Il2CppObject* local = Player_GetLocalPlayer();

    for (int i = 0; i < count; i++) {
        Il2CppObject* p = buf[i];
        if (!p || p == local) continue;
        if (!Player_PassesFilters(p)) continue; // teamcheck / minRange / wallcheck (mesma lógica do aimbot)

        // Posição da cabeça e dos pés
        Il2CppObject* headTr = Field<Il2CppObject*>(p, PlayerMove::headTransform);
        Il2CppObject* bodyTr = Field<Il2CppObject*>(p, PlayerMove::myPlayerTransform);
        if (!headTr || !bodyTr) continue;

        Vector3 headWS = Transform_GetPos_ext(headTr);
        Vector3 feetWS = Transform_GetPos_ext(bodyTr);
        // Estima posição dos pés (ligeiramente abaixo do Transform)
        feetWS.y -= 0.1f;

        Vector3 headSS, feetSS;
        if (!Camera_WorldToScreen_ext(camera, headWS, &headSS)) continue;
        if (!Camera_WorldToScreen_ext(camera, feetWS, &feetSS)) continue;

        // Coordenadas de tela (hx/hy = cabeça, fx/fy = pés)
        CGFloat hx = headSS.x, hy = headSS.y;
        CGFloat fx = feetSS.x, fy = feetSS.y;
        (void)fx; // só fy é usado na box/ancora de distância; fx mantido por simetria/depuração

        // Altura da box em pixels
        CGFloat boxH = fabs(fy - hy);
        if (boxH < 5.0f) continue;
        CGFloat boxW = boxH * 0.5f;

        CGFloat bx = hx - boxW * 0.5f;
        CGFloat by = hy;

        // Cor: vermelho para inimigos
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.1 blue:0.1 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextStrokeRect(ctx, CGRectMake(bx, by, boxW, boxH));

        // Barra de health
        float hp = Player_GetHealth(p);
        if (hp > 0.0f) {
            float maxHp = 100.0f; // assumimos 100 max; confirmar via dump
            float ratio = fminf(hp / maxHp, 1.0f);
            // fundo cinza
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.2 alpha:0.7].CGColor);
            CGContextFillRect(ctx, CGRectMake(bx - 6, by, 4, boxH));
            // barra verde→vermelho
            UIColor* barCol = (ratio > 0.6f) ? [UIColor colorWithRed:0.1 green:0.9 blue:0.1 alpha:0.9]
                            : (ratio > 0.3f) ? [UIColor colorWithRed:1.0 green:0.7 blue:0.0 alpha:0.9]
                            :                  [UIColor colorWithRed:1.0 green:0.1 blue:0.1 alpha:0.9];
            CGContextSetFillColorWithColor(ctx, barCol.CGColor);
            CGContextFillRect(ctx, CGRectMake(bx - 6, by + boxH*(1.0f-ratio), 4, boxH*ratio));
        }

        // Nome
        std::string nick = Player_GetNickname(p);
        if (!nick.empty()) {
            NSString* ns = [NSString stringWithUTF8String:nick.c_str()];
            NSDictionary* attrs = @{
                NSFontAttributeName:            [UIFont boldSystemFontOfSize:9],
                NSForegroundColorAttributeName: [UIColor whiteColor]
            };
            CGSize sz = [ns sizeWithAttributes:attrs];
            [ns drawAtPoint:CGPointMake(hx - sz.width*0.5f, hy - sz.height - 2)
             withAttributes:attrs];
        }

        // Distância (posição do local player)
        Il2CppObject* localP  = Player_GetLocalPlayer();
        if (localP) {
            Il2CppObject* myTr = Field<Il2CppObject*>(localP, PlayerMove::myPlayerTransform);
            if (myTr) {
                Vector3 myPos = Transform_GetPos_ext(myTr);
                float dx = headWS.x - myPos.x;
                float dy = headWS.y - myPos.y;
                float dz = headWS.z - myPos.z;
                float dist = sqrtf(dx*dx + dy*dy + dz*dz);
                NSString* distStr = [NSString stringWithFormat:@"%.0fm", dist];
                NSDictionary* da = @{
                    NSFontAttributeName:            [UIFont systemFontOfSize:8],
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:0.9]
                };
                CGSize sz2 = [distStr sizeWithAttributes:da];
                [distStr drawAtPoint:CGPointMake(bx + boxW*0.5f - sz2.width*0.5f, fy + 2)
                      withAttributes:da];
            }
        }
    }
}

@end

// ============================================================
//  MenuWindow
// ============================================================
@interface MenuWindow : UIWindow
@end
@implementation MenuWindow
// Passa toque para o jogo quando o menu está fechado
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    // ESPView tem userInteractionEnabled=NO, então o hit-test nunca a devolve:
    // em área vazia ele devolve a view raiz do rootViewController (ou a própria
    // janela). Essas áreas têm que repassar o toque para a janela do jogo; só o
    // botão ☰ e o painel (subviews reais) devem capturar.
    if (!v || v == self || v == self.rootViewController.view ||
        [v isKindOfClass:[ESPView class]]) return nil;
    return v;
}
@end

// ============================================================
//  PG3DMenuController
// ============================================================
@interface PG3DMenuController : NSObject
@property (nonatomic, strong) MenuWindow*   window;
@property (nonatomic, strong) UIView*       panel;
@property (nonatomic, strong) UIButton*     toggleBtn;
// Botão flutuante independente do painel/menu: alterna g_cheat.aimLock
// (trava a mira em quem estiver dentro da FOV) sem precisar abrir o menu.
// Fica sempre visível e pode ser arrastado como o botão ☰.
@property (nonatomic, strong) UIButton*     lockBtn;
@property (nonatomic, strong) ESPView*      espView;
@property (nonatomic, strong) CADisplayLink* displayLink;
@property (nonatomic, assign) BOOL          panelVisible;
@property (nonatomic, assign) CGPoint       dragOffset;
@property (nonatomic, assign) NSInteger     setupAttempts;
@property (nonatomic, assign) BOOL          wasDrawing;   // houve desenho no último tick (para limpar ao desligar)
@property (nonatomic, assign) BOOL          lockShownOn;  // último estado de aimLock refletido no botão/switch
+ (instancetype)shared;
- (void)setup;
@end

@implementation PG3DMenuController

+ (instancetype)shared {
    static PG3DMenuController* s = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ s = [PG3DMenuController new]; });
    return s;
}

// O jogo declara UIApplicationSceneManifest: no iOS 13+ uma UIWindow criada
// sem UIWindowScene pode nunca ser exibida. Procura a cena ativa.
- (UIWindowScene*)activeWindowScene {
    UIWindowScene* fallback = nil;
    for (UIScene* sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive)
            return (UIWindowScene*)sc;
        if (!fallback) fallback = (UIWindowScene*)sc;
    }
    return fallback;
}

- (void)setup {
    if (self.window) return; // já criada
    PG3D_Log("[pg3d_tweak] -[PG3DMenuController setup] entrou (tentativa %ld)", (long)self.setupAttempts);

    UIWindowScene* scene = [self activeWindowScene];
    if (!scene && self.setupAttempts < 15) {
        // Cena ainda não conectada: tenta de novo em 1s (até 15x).
        self.setupAttempts++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self setup]; });
        return;
    }
    PG3D_Log("[pg3d_tweak] windowScene=%p state=%ld", (__bridge void*)scene,
             scene ? (long)scene.activationState : -1L);

    CGRect screen = scene ? scene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;

    // Janela overlay (ligada à cena quando existe; sem cena só como último recurso)
    self.window = scene ? [[MenuWindow alloc] initWithWindowScene:scene]
                        : [[MenuWindow alloc] initWithFrame:screen];
    self.window.frame = screen;
    self.window.windowLevel       = UIWindowLevelAlert + 1;
    self.window.backgroundColor   = [UIColor clearColor];
    self.window.userInteractionEnabled = YES;
    self.window.hidden = NO;

    UIViewController* vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = vc;

    // ESPView ocupa a tela toda
    self.espView = [[ESPView alloc] initWithFrame:screen];
    [vc.view addSubview:self.espView];
    // Mesma regra do init do ESPView: segue o tamanho da view raiz.
    self.espView.frame = vc.view.bounds;

    // Botão flutuante para abrir menu
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleBtn.frame = CGRectMake(10, 80, 44, 44);
    self.toggleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.75];
    self.toggleBtn.layer.cornerRadius = 22;
    self.toggleBtn.layer.borderColor  = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1].CGColor;
    self.toggleBtn.layer.borderWidth  = 2;
    [self.toggleBtn setTitle:@"☰" forState:UIControlStateNormal];
    self.toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.toggleBtn addTarget:self action:@selector(togglePanel)
             forControlEvents:UIControlEventTouchUpInside];
    // Drag
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDrag:)];
    [self.toggleBtn addGestureRecognizer:pan];
    [vc.view addSubview:self.toggleBtn];

    // Botão flutuante de AimLock (fora do menu, sempre visível e arrastável).
    // Toca para ligar/desligar; a borda fica verde quando ativo.
    self.lockBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.lockBtn.frame = CGRectMake(10, 134, 44, 44); // logo abaixo do ☰ (80+44+10)
    self.lockBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.75];
    self.lockBtn.layer.cornerRadius = 22;
    self.lockBtn.layer.borderWidth  = 2;
    [self.lockBtn setTitle:@"🎯" forState:UIControlStateNormal];
    self.lockBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.lockBtn addTarget:self action:@selector(toggleLockButton)
           forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer* panLock = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDrag:)];
    [self.lockBtn addGestureRecognizer:panLock];
    [vc.view addSubview:self.lockBtn];
    self.lockBtn.hidden = !g_cheat.lockButton;
    [self refreshLockButtonAppearance];

    // Painel de menu
    // Painel com rolagem interna: cabe em tela landscape mesmo com todas as opções.
    CGFloat pw = 220;
    CGFloat ph = MIN(330.0, MAX(200.0, MIN(screen.size.width, screen.size.height) - 70.0));
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(60, 60, pw, ph)];
    self.panel.backgroundColor   = [UIColor colorWithRed:0.05 green:0.05 blue:0.1 alpha:0.88];
    self.panel.layer.cornerRadius = 12;
    self.panel.layer.borderColor  = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:0.9].CGColor;
    self.panel.layer.borderWidth  = 1.5;
    self.panel.hidden = YES;
    [vc.view addSubview:self.panel];

    [self buildMenuItems];

    // DisplayLink para ESP
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                   selector:@selector(refreshESP)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                           forMode:NSRunLoopCommonModes];

    PG3D_Log("[pg3d_tweak] -[PG3DMenuController setup] terminou, window.hidden=%d windowLevel=%.0f",
             self.window.hidden, (float)self.window.windowLevel);
}

- (void)buildMenuItems {
    CGFloat pw = self.panel.bounds.size.width;
    CGFloat ph = self.panel.bounds.size.height;

    // Título (fixo no topo)
    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, pw, 28)];
    title.text = @"PG3D Cheat ◈";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self.panel addSubview:title];

    // Conteúdo rolável
    UIScrollView* sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 38, pw, ph - 42)];
    sv.showsVerticalScrollIndicator = YES;
    sv.alwaysBounceVertical = YES;
    sv.delaysContentTouches = NO;
    [self.panel addSubview:sv];
    CGFloat y = 4;

    // Helper para criar toggle. tag: 101 = switch de AimLock (sincronizado com o
    // botão flutuante); 1/2/4/8 = bits de parte do corpo (AimPartBit); 0 = sem tag.
    auto makeToggle = [&](NSString* label, BOOL initVal, SEL sel, NSInteger tag) {
        UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 55, y, 51, 31)];
        sw.on = initVal;
        sw.onTintColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
        sw.transform = CGAffineTransformMakeScale(0.75, 0.75);
        sw.tag = tag;
        [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
        [sv addSubview:sw];

        UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, pw - 70, 31)];
        lbl.text = label;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:12];
        [sv addSubview:lbl];
        y += 34;
    };
    auto makeSection = [&](NSString* text) {
        UILabel* l = [[UILabel alloc] initWithFrame:CGRectMake(10, y + 2, pw - 20, 16)];
        l.text = text;
        l.textColor = [UIColor colorWithRed:1 green:0.6 blue:0.6 alpha:1];
        l.font = [UIFont boldSystemFontOfSize:10];
        [sv addSubview:l];
        y += 20;
    };

    makeSection(@"MIRA");
    makeToggle(@"Aimbot",     g_cheat.aimbot,     @selector(toggleAimbot:),    0);
    makeToggle(@"AimLock",    g_cheat.aimLock,    @selector(toggleAimLock:),   101);
    makeToggle(@"Botão Lock", g_cheat.lockButton, @selector(toggleLockBtn:),   0);
    makeToggle(@"Aim gira o corpo", g_cheat.aimBodyYaw, @selector(toggleAimBody:), 0);
    makeToggle(@"Mostrar FOV", g_cheat.showFov,   @selector(toggleShowFov:),   0);

    makeSection(@"PARTE DO CORPO (multi-seleção)");
    makeToggle(@"Cabeça",  (g_cheat.aimParts & AIM_PART_HEAD)    != 0, @selector(togglePart:), AIM_PART_HEAD);
    makeToggle(@"Peito",   (g_cheat.aimParts & AIM_PART_CHEST)   != 0, @selector(togglePart:), AIM_PART_CHEST);
    makeToggle(@"Abdômen", (g_cheat.aimParts & AIM_PART_STOMACH) != 0, @selector(togglePart:), AIM_PART_STOMACH);
    makeToggle(@"Pernas",  (g_cheat.aimParts & AIM_PART_LEGS)    != 0, @selector(togglePart:), AIM_PART_LEGS);

    makeSection(@"FILTROS / VISUAL");
    makeToggle(@"ESP",        g_cheat.esp,        @selector(toggleESP:),       0);
    makeToggle(@"Team Check", g_cheat.teamCheck,  @selector(toggleTeamCheck:), 0);
    makeToggle(@"Wall Check", g_cheat.wallCheck,  @selector(toggleWallCheck:), 0);
    // Aviso (só aparece com Wall Check ligado e Physics.Linecast não resolvido)
    UILabel* wallNote = [[UILabel alloc] initWithFrame:CGRectMake(10, y - 4, pw - 20, 14)];
    wallNote.textColor = [UIColor colorWithRed:1 green:0.7 blue:0.2 alpha:1];
    wallNote.font = [UIFont systemFontOfSize:9];
    wallNote.text = @"Wall Check indisponível neste build";
    wallNote.tag = 103;
    wallNote.hidden = YES;
    [sv addSubview:wallNote];
    y += 14;
    makeToggle(@"AC Bypass",  g_cheat.acBypass,   @selector(toggleAC:),        0);

    // Coleta de dados para o Team Check (grava no log; não altera o jogo)
    UIButton* dumpBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    dumpBtn.frame = CGRectMake(10, y, pw - 20, 26);
    [dumpBtn setTitle:@"Dump de times (log)" forState:UIControlStateNormal];
    dumpBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    dumpBtn.tintColor = [UIColor colorWithRed:1 green:0.7 blue:0.4 alpha:1];
    [dumpBtn addTarget:self action:@selector(dumpTeams)
      forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:dumpBtn];
    y += 30;

    // FOV slider
    UILabel* fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, pw-20, 18)];
    fovLbl.textColor = [UIColor lightGrayColor];
    fovLbl.font = [UIFont systemFontOfSize:11];
    fovLbl.text = [NSString stringWithFormat:@"Aim FOV: %.0f°", g_cheat.aimbotFov];
    fovLbl.tag = 100;
    [sv addSubview:fovLbl];
    y += 20;

    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(10, y, pw-20, 28)];
    sl.minimumValue = 1.0f;
    sl.maximumValue = 90.0f;
    sl.value = g_cheat.aimbotFov;
    sl.minimumTrackTintColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    [sl addTarget:self action:@selector(fovChanged:)
 forControlEvents:UIControlEventValueChanged];
    [sv addSubview:sl];
    y += 32;

    // Minimum range slider (metros; 0 = desabilitado)
    UILabel* rangeLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, pw-20, 18)];
    rangeLbl.textColor = [UIColor lightGrayColor];
    rangeLbl.font = [UIFont systemFontOfSize:11];
    rangeLbl.text = (g_cheat.minRange > 0.0f)
        ? [NSString stringWithFormat:@"Min Range: %.0fm", g_cheat.minRange]
        : @"Min Range: off";
    rangeLbl.tag = 102;
    [sv addSubview:rangeLbl];
    y += 20;

    UISlider* rangeSl = [[UISlider alloc] initWithFrame:CGRectMake(10, y, pw-20, 28)];
    rangeSl.minimumValue = 0.0f;
    rangeSl.maximumValue = 50.0f;
    rangeSl.value = g_cheat.minRange;
    rangeSl.minimumTrackTintColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    [rangeSl addTarget:self action:@selector(rangeChanged:)
      forControlEvents:UIControlEventValueChanged];
    [sv addSubview:rangeSl];
    y += 32;

    // Fechar
    UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(pw/2 - 40, y, 80, 28);
    [closeBtn setTitle:@"Fechar" forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor colorWithWhite:0.7 alpha:1];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [closeBtn addTarget:self action:@selector(togglePanel)
       forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:closeBtn];
    y += 36;

    sv.contentSize = CGSizeMake(pw, y);
}

// ---- Toggle actions ----
- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panel.hidden = !self.panelVisible;
}

- (void)toggleAimbot:(UISwitch*)sw { g_cheat.aimbot  = sw.on; }
// AimLock = trava (sticky) no jogador que está dentro do círculo de FOV agora.
// Sem alvo dentro do círculo, o switch volta para desligado.
- (void)toggleAimLock:(UISwitch*)sw {
    if (sw.on) {
        if (!Aim_LockAcquire()) [sw setOn:NO animated:YES];
    } else {
        Aim_LockRelease();
    }
    [self refreshLockButtonAppearance];
}

// Multi-seleção de partes do corpo (tag = bit). Sempre fica pelo menos uma marcada.
- (void)togglePart:(UISwitch*)sw {
    unsigned char bit  = (unsigned char)sw.tag;
    unsigned char mask = g_cheat.aimParts;
    if (sw.on) mask = (unsigned char)(mask | bit);
    else       mask = (unsigned char)(mask & (unsigned char)~bit);
    if (mask == 0) { [sw setOn:YES animated:YES]; return; }
    g_cheat.aimParts = mask;
}

- (void)toggleShowFov:(UISwitch*)sw { g_cheat.showFov = sw.on; }

- (void)dumpTeams { Diag_RequestTeamDump(); }

// Mira gira o corpo (yaw) + câmera (pitch). Desligue para comparar com o modo antigo
// (só o container da câmera) se o joystick se comportar diferente.
- (void)toggleAimBody:(UISwitch*)sw { g_cheat.aimBodyYaw = sw.on; }

// Mostra/esconde o botão flutuante de lock (fora do menu).
- (void)toggleLockBtn:(UISwitch*)sw {
    g_cheat.lockButton = sw.on;
    self.lockBtn.hidden = !sw.on;
    if (!sw.on && g_cheat.aimLock) {
        Aim_LockRelease();
        [self syncAimLockSwitch];
        [self refreshLockButtonAppearance];
    }
}
- (void)toggleESP:(UISwitch*)sw    { g_cheat.esp      = sw.on; }
- (void)toggleAC:(UISwitch*)sw     { g_cheat.acBypass = sw.on; }
- (void)toggleTeamCheck:(UISwitch*)sw {
    g_cheat.teamCheck = sw.on;
    Diag_LogFilterStatus("toggleTeamCheck");
}
- (void)toggleWallCheck:(UISwitch*)sw {
    g_cheat.wallCheck = sw.on;
    Diag_LogFilterStatus("toggleWallCheck");
    UILabel* note = (UILabel*)[self.panel viewWithTag:103];
    if ([note isKindOfClass:[UILabel class]])
        note.hidden = !(sw.on && HookManager_IsReady() && !Aim_WallCheckAvailable());
}

- (void)fovChanged:(UISlider*)sl {
    g_cheat.aimbotFov = sl.value;
    UILabel* lbl = (UILabel*)[self.panel viewWithTag:100];
    if (lbl) lbl.text = [NSString stringWithFormat:@"Aim FOV: %.0f°", g_cheat.aimbotFov];
}

- (void)rangeChanged:(UISlider*)sl {
    g_cheat.minRange = sl.value;
    UILabel* lbl = (UILabel*)[self.panel viewWithTag:102];
    if (lbl) lbl.text = (g_cheat.minRange > 0.0f)
        ? [NSString stringWithFormat:@"Min Range: %.0fm", g_cheat.minRange]
        : @"Min Range: off";
}

// ---- Botão flutuante de lock (fora do menu) ----
// Toque: trava a mira no jogador que está dentro do círculo de FOV; toque de novo
// solta. Sem ninguém no círculo, mostra "∅" por um instante e não trava.
- (void)toggleLockButton {
    if (g_cheat.aimLock) {
        Aim_LockRelease();
    } else if (!Aim_LockAcquire()) {
        [self.lockBtn setTitle:@"∅" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self refreshLockButtonAppearance]; });
        return;
    }
    [self syncAimLockSwitch];
    [self refreshLockButtonAppearance];
}

// Mantém o switch "AimLock" do painel igual a g_cheat.aimLock.
- (void)syncAimLockSwitch {
    UISwitch* sw = (UISwitch*)[self.panel viewWithTag:101];
    if ([sw isKindOfClass:[UISwitch class]] && sw.on != g_cheat.aimLock)
        [sw setOn:g_cheat.aimLock animated:YES];
}

- (void)refreshLockButtonAppearance {
    if (!self.lockBtn) return;
    UIColor* active   = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:1];
    UIColor* inactive = [UIColor colorWithRed:1   green:0.3 blue:0.3 alpha:1];
    self.lockBtn.layer.borderColor = (g_cheat.aimLock ? active : inactive).CGColor;
    [self.lockBtn setTitle:(g_cheat.aimLock ? @"🔒" : @"🎯") forState:UIControlStateNormal];
    self.lockShownOn = g_cheat.aimLock;
}

// ---- Drag do botão ----
- (void)handleDrag:(UIPanGestureRecognizer*)gr {
    UIView* v = gr.view;
    CGPoint trans = [gr translationInView:v.superview];
    CGPoint center = v.center;
    v.center = CGPointMake(center.x + trans.x, center.y + trans.y);
    [gr setTranslation:CGPointZero inView:v.superview];
}

// ---- Refresh ESP ----
- (void)refreshESP {
    // Redesenha enquanto há algo a mostrar (ESP ou círculo de FOV) e UMA vez a mais
    // ao desligar, para apagar o último quadro (senão ele ficava congelado na tela).
    BOOL fovVisible = g_cheat.showFov && (g_cheat.aimbot || g_cheat.aimLock || g_cheat.lockButton);
    BOOL want = (g_cheat.esp && HookManager_IsReady()) || fovVisible;
    if (want || self.wasDrawing) [self.espView setNeedsDisplay];
    self.wasDrawing = want;

    // O lock pode soltar sozinho (alvo saiu da partida): reflete no botão e no switch.
    if (self.lockShownOn != g_cheat.aimLock) {
        [self syncAimLockSwitch];
        [self refreshLockButtonAppearance];
    }
}

@end

// ============================================================
//  API pública
// ============================================================
extern "C" void Menu_Setup(void) {
    PG3D_Log("[pg3d_tweak] Menu_Setup() chamado");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PG3DMenuController shared] setup];
    });
}
