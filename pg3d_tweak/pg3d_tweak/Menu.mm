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
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!g_cheat.esp || !HookManager_IsReady()) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    Il2CppObject* camera = Camera_GetMain();
    if (!camera) return;

    Il2CppObject* buf[256];
    int count = 0;
    Players_GetSnapshot(buf, &count, 256);

    Il2CppObject* local = Player_GetLocalPlayer();

    for (int i = 0; i < count; i++) {
        Il2CppObject* p = buf[i];
        if (!p || p == local) continue;

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
    // Se o view que recebeu é a ESPView (userInteractionEnabled=NO) devolve nil
    // para o iOS repassar ao jogo
    if ([v isKindOfClass:[ESPView class]]) return nil;
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
@property (nonatomic, strong) ESPView*      espView;
@property (nonatomic, strong) CADisplayLink* displayLink;
@property (nonatomic, assign) BOOL          panelVisible;
@property (nonatomic, assign) CGPoint       dragOffset;
@property (nonatomic, assign) NSInteger     setupAttempts;
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
    PG3D_Log("[pg3d_tweak] windowScene=%p state=%ld", (void*)scene,
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

    // Painel de menu
    CGFloat pw = 200, ph = 290;
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
    CGFloat y = 10;
    CGFloat pw = self.panel.bounds.size.width;

    // Título
    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(0, y, pw, 28)];
    title.text = @"PG3D Cheat ◈";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor = [UIColor colorWithRed:1 green:0.4 blue:0.4 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:14];
    [self.panel addSubview:title];
    y += 32;

    // Helper para criar toggle
    auto makeToggle = [&](NSString* label, BOOL initVal, SEL sel) {
        UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 55, y, 51, 31)];
        sw.on = initVal;
        sw.onTintColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
        sw.transform = CGAffineTransformMakeScale(0.75, 0.75);
        [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
        [self.panel addSubview:sw];

        UILabel* lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, pw - 70, 31)];
        lbl.text = label;
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont systemFontOfSize:12];
        [self.panel addSubview:lbl];
        y += 36;
    };

    makeToggle(@"Aimbot",    g_cheat.aimbot,    @selector(toggleAimbot:));
    makeToggle(@"AimLock",   g_cheat.aimLock,   @selector(toggleAimLock:));
    makeToggle(@"ESP",       g_cheat.esp,        @selector(toggleESP:));
    makeToggle(@"AC Bypass", g_cheat.acBypass,  @selector(toggleAC:));

    // FOV slider
    UILabel* fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, y, pw-20, 18)];
    fovLbl.textColor = [UIColor lightGrayColor];
    fovLbl.font = [UIFont systemFontOfSize:11];
    fovLbl.text = [NSString stringWithFormat:@"Aim FOV: %.0f°", g_cheat.aimbotFov];
    fovLbl.tag = 100;
    [self.panel addSubview:fovLbl];
    y += 20;

    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(10, y, pw-20, 28)];
    sl.minimumValue = 1.0f;
    sl.maximumValue = 90.0f;
    sl.value = g_cheat.aimbotFov;
    sl.minimumTrackTintColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    [sl addTarget:self action:@selector(fovChanged:)
 forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:sl];
    y += 32;

    // Fechar
    UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(pw/2 - 40, y, 80, 28);
    [closeBtn setTitle:@"Fechar" forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor colorWithWhite:0.7 alpha:1];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [closeBtn addTarget:self action:@selector(togglePanel)
       forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:closeBtn];
}

// ---- Toggle actions ----
- (void)togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panel.hidden = !self.panelVisible;
}

- (void)toggleAimbot:(UISwitch*)sw { g_cheat.aimbot  = sw.on; }
- (void)toggleAimLock:(UISwitch*)sw{ g_cheat.aimLock  = sw.on; }
- (void)toggleESP:(UISwitch*)sw    { g_cheat.esp      = sw.on; }
- (void)toggleAC:(UISwitch*)sw     { g_cheat.acBypass = sw.on; }

- (void)fovChanged:(UISlider*)sl {
    g_cheat.aimbotFov = sl.value;
    UILabel* lbl = (UILabel*)[self.panel viewWithTag:100];
    if (lbl) lbl.text = [NSString stringWithFormat:@"Aim FOV: %.0f°", g_cheat.aimbotFov];
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
    if (g_cheat.esp && HookManager_IsReady()) {
        [self.espView setNeedsDisplay];
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
