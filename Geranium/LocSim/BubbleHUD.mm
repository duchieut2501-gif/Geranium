// Floating bubble drawn over every app (needs TrollStore).
// System-window set-up based on TrollSpeed (MIT License, Lessica) — see BubbleHeaders/TROLLSPEED_LICENSE.

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <errno.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <crt_externs.h>

#import "BubbleHUD.h"
#import "LocSimPrivateHeaders.h"
#import "pac_helper.h"
#import "UIEventFetcher.h"
#import "UIEventDispatcher.h"
#import "UIApplication+Private.h"
#import "BackboardServices.h"
#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"

extern "C" {
#import "libproc.h"
#import "kern_memorystatus.h"
}

extern "C" char **environ;
extern "C" int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, Boolean suspended);

#define PID_PATH "/var/mobile/Library/Caches/com.locationsimulator.bubble.pid"
#define STATUS_PATH @"/var/mobile/Library/Caches/com.locationsimulator.bubble.json"
#define POS_PATH @"/var/mobile/Library/Caches/com.locationsimulator.bubble.pos"
#define NOTIFY_DISMISS "com.locationsimulator.bubble.dismiss"
#define NOTIFY_STATUS "com.locationsimulator.bubble.status"
#define NOTIFY_CMD "com.locationsimulator.bubble.cmd"

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

static const CGFloat kBubble = 54;
static const CGFloat kPanelW = 330, kPanelH = 132;

#pragma mark - Window (only as big as the bubble / panel, so the rest of the screen stays touchable)

@interface LSBubbleWindow : UIWindow
@end
@implementation LSBubbleWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
@end

static void SendCommand(int cmd) {
    int t = 0;
    notify_register_check(NOTIFY_CMD, &t);
    notify_set_state(t, (uint64_t)cmd);
    notify_post(NOTIFY_CMD);
}

@interface LSBubbleController : UIViewController
@property (nonatomic, weak) UIWindow *win;
@end

@implementation LSBubbleController {
    UIView *_bubble;
    UIView *_panel;
    UILabel *_title, *_sub;
    UIButton *_stopBtn, *_pauseBtn, *_minusBtn, *_plusBtn, *_openBtn;
    BOOL _expanded, _visible;
    NSDate *_lastSeen;
    CGPoint _bubbleOrigin;
}

static UIButton *RoundButton(NSString *symbol, UIColor *bg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = bg;
    b.layer.cornerRadius = 20;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:52].active = YES;
    [b.heightAnchor constraintEqualToConstant:40].active = YES;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    // Bubble
    _bubble = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kBubble, kBubble)];
    _bubble.backgroundColor = [UIColor colorWithRed:0.93 green:0.26 blue:0.24 alpha:0.95];
    _bubble.layer.cornerRadius = kBubble / 2;
    _bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    _bubble.layer.borderWidth = 2;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"location.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]]];
    icon.tintColor = UIColor.whiteColor;
    icon.center = CGPointMake(kBubble / 2, kBubble / 2);
    [_bubble addSubview:icon];
    [_bubble addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)]];
    [_bubble addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    [self.view addSubview:_bubble];

    // Panel
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPanelW, kPanelH)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.94];
    _panel.layer.cornerRadius = 18;
    _panel.hidden = YES;
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _title.textColor = UIColor.whiteColor;
    _sub = [UILabel new];
    _sub.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    _sub.textColor = [UIColor colorWithWhite:0.8 alpha:1];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"chevron.down.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = [UIColor colorWithWhite:0.6 alpha:1];
    [close addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;

    _stopBtn = RoundButton(@"stop.fill", [UIColor colorWithRed:0.93 green:0.26 blue:0.24 alpha:1]);
    _pauseBtn = RoundButton(@"pause.fill", [UIColor colorWithWhite:0.25 alpha:1]);
    _minusBtn = RoundButton(@"minus", [UIColor colorWithWhite:0.25 alpha:1]);
    _plusBtn = RoundButton(@"plus", [UIColor colorWithWhite:0.25 alpha:1]);
    _openBtn = RoundButton(@"arrow.up.forward.app", [UIColor colorWithRed:0.20 green:0.47 blue:0.96 alpha:1]);
    [_openBtn addTarget:self action:@selector(openTap) forControlEvents:UIControlEventTouchUpInside];
    [_stopBtn addTarget:self action:@selector(stopTap) forControlEvents:UIControlEventTouchUpInside];
    [_pauseBtn addTarget:self action:@selector(pauseTap) forControlEvents:UIControlEventTouchUpInside];
    [_minusBtn addTarget:self action:@selector(minusTap) forControlEvents:UIControlEventTouchUpInside];
    [_plusBtn addTarget:self action:@selector(plusTap) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _sub]];
    texts.axis = UILayoutConstraintAxisVertical; texts.spacing = 2;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[texts, close]];
    top.alignment = UIStackViewAlignmentTop; top.spacing = 8;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_openBtn, _stopBtn, _pauseBtn, _minusBtn, _plusBtn]];
    row.distribution = UIStackViewDistributionEqualSpacing;
    UIStackView *all = [[UIStackView alloc] initWithArrangedSubviews:@[top, row]];
    all.axis = UILayoutConstraintAxisVertical; all.spacing = 12;
    all.translatesAutoresizingMaskIntoConstraints = NO;
    [_panel addSubview:all];
    [NSLayoutConstraint activateConstraints:@[
        [all.leadingAnchor constraintEqualToAnchor:_panel.leadingAnchor constant:14],
        [all.trailingAnchor constraintEqualToAnchor:_panel.trailingAnchor constant:-14],
        [all.topAnchor constraintEqualToAnchor:_panel.topAnchor constant:12],
        [close.widthAnchor constraintEqualToConstant:28], [close.heightAnchor constraintEqualToConstant:28],
    ]];
    [self.view addSubview:_panel];

    NSString *pos = [NSString stringWithContentsOfFile:POS_PATH encoding:NSUTF8StringEncoding error:nil];
    CGSize scr = UIScreen.mainScreen.bounds.size;
    _bubbleOrigin = pos ? CGPointFromString(pos) : CGPointMake(scr.width - kBubble - 6, scr.height * 0.42);

    __weak typeof(self) ws = self;
    int tok;
    notify_register_dispatch(NOTIFY_STATUS, &tok, dispatch_get_main_queue(), ^(int t) { [ws poll:YES]; });
    [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:YES block:^(NSTimer *t) { [ws poll:NO]; }];
    [self poll:YES];
}

- (void)place {
    CGSize scr = UIScreen.mainScreen.bounds.size;
    if (!_visible) { self.win.hidden = YES; return; }
    self.win.hidden = NO;
    if (_expanded) {
        CGFloat x = MIN(MAX(_bubbleOrigin.x + kBubble / 2 - kPanelW / 2, 8), scr.width - kPanelW - 8);
        CGFloat y = MIN(MAX(_bubbleOrigin.y, 50), scr.height - kPanelH - 30);
        self.win.frame = CGRectMake(x, y, kPanelW, kPanelH);
        _panel.frame = CGRectMake(0, 0, kPanelW, kPanelH);
    } else {
        self.win.frame = CGRectMake(_bubbleOrigin.x, _bubbleOrigin.y, kBubble, kBubble);
        _bubble.frame = CGRectMake(0, 0, kBubble, kBubble);
    }
    _bubble.hidden = _expanded;
    _panel.hidden = !_expanded;
}

- (void)poll:(BOOL)force {
    NSDate *t = [[NSFileManager.defaultManager attributesOfItemAtPath:STATUS_PATH error:nil] fileModificationDate];
    if (!t) { if (_visible) { _visible = NO; [self place]; } return; }
    if (!force && _lastSeen && [t compare:_lastSeen] != NSOrderedDescending) {
        // the app went quiet for long (closed / killed): keep showing, it may still be simulating
        return;
    }
    _lastSeen = t;
    NSData *d = [NSData dataWithContentsOfFile:STATUS_PATH];
    NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) return;
    BOOL show = [j[@"show"] boolValue];
    _title.text = j[@"title"] ?: @"";
    _sub.text = j[@"sub"] ?: @"";
    BOOL canPause = [j[@"canPause"] boolValue], canSpeed = [j[@"canSpeed"] boolValue];
    _pauseBtn.hidden = !canPause;
    _minusBtn.hidden = !canSpeed;
    _plusBtn.hidden = !canSpeed;
    [_pauseBtn setImage:[UIImage systemImageNamed:[j[@"paused"] boolValue] ? @"play.fill" : @"pause.fill"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    if (show != _visible) { _visible = show; if (!show) _expanded = NO; [self place]; }
}

- (void)toggle { _expanded = !_expanded; [self place]; }

- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:nil];
    [g setTranslation:CGPointZero inView:nil];
    CGSize scr = UIScreen.mainScreen.bounds.size;
    _bubbleOrigin.x = MIN(MAX(_bubbleOrigin.x + d.x, 0), scr.width - kBubble);
    _bubbleOrigin.y = MIN(MAX(_bubbleOrigin.y + d.y, 40), scr.height - kBubble - 20);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _bubbleOrigin.x = (_bubbleOrigin.x + kBubble / 2 < scr.width / 2) ? 6 : scr.width - kBubble - 6;   // stick to the edge
        [NSStringFromCGPoint(_bubbleOrigin) writeToFile:POS_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [UIView animateWithDuration:0.2 animations:^{ [self place]; }];
    } else {
        [self place];
    }
}

- (void)stopTap {
    // Stop right here (works even if the app is asleep), then tell the app.
    CLSimulationManager *m = [objc_getClass("CLSimulationManager") new];
    [m stopLocationSimulation];
    [m clearSimulatedLocations];
    [m flush];
    CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("AutomaticTimeZoneUpdateNeeded"), NULL, NULL, kCFNotificationDeliverImmediately);
    SendCommand(1);
    _expanded = NO; _visible = NO;
    [self place];
}
- (void)openTap {
    _expanded = NO;
    [self place];
    NSString *bid = NSBundle.mainBundle.bundleIdentifier ?: @"com.locationsimulator.app";
    if (SBSLaunchApplicationWithIdentifier((__bridge CFStringRef)bid, false) != 0) {
        id ws = [objc_getClass("LSApplicationWorkspace") performSelector:@selector(defaultWorkspace)];
        if ([ws respondsToSelector:@selector(openApplicationWithBundleID:)])
            [ws performSelector:@selector(openApplicationWithBundleID:) withObject:bid];
    }
}
- (void)pauseTap { SendCommand(2); }
- (void)minusTap { SendCommand(3); }
- (void)plusTap { SendCommand(4); }
@end

#pragma mark - HUD application (TrollSpeed frame)

@interface LSBubbleApplication : UIApplication
@end
@implementation LSBubbleApplication
- (instancetype)init {
    if (self = [super init]) {
        int outToken;
        notify_register_dispatch(NOTIFY_DISMISS, &outToken, dispatch_get_main_queue(), ^(int token) {
            notify_cancel(token);
            [self terminateWithSuccess];
        });
        do {
            UIEventDispatcher *dispatcher = (UIEventDispatcher *)[self valueForKey:@"eventDispatcher"];
            if (!dispatcher) break;
            if ([dispatcher respondsToSelector:@selector(_installEventRunLoopSources:)]) {
                [dispatcher _installEventRunLoopSources:CFRunLoopGetMain()];
            } else {
                IMP runIMP = class_getMethodImplementation([self class], @selector(_run));
                if (!runIMP) break;
                uint32_t *p = (uint32_t *)make_sym_readable((void *)runIMP);
                void (*install)(id, SEL, CFRunLoopRef) = NULL;
                for (int i = 0; i < 0x140; i++) {
                    if (p[i] != 0xaa0003e2 || (p[i + 1] & 0xff000000) != 0xaa000000) continue;
                    uint32_t bl = p[i + 2];
                    if ((bl & 0xfc000000) != 0x94000000) continue;
                    int32_t off = bl & 0x03ffffff;
                    if (off & 0x02000000) off |= 0xfc000000;
                    off <<= 2;
                    uint64_t addr = (uint64_t)&p[i + 2] + off;
                    if (((*(uint32_t *)make_sym_readable((void *)addr)) & 0xff000000) != 0xb4000000) continue;
                    install = (void (*)(id, SEL, CFRunLoopRef))make_sym_callable((void *)addr);
                }
                if (!install) break;
                install(dispatcher, @selector(_installEventRunLoopSources:), CFRunLoopGetMain());
            }
            UIEventFetcher *fetcher = [[objc_getClass("UIEventFetcher") alloc] init];
            [dispatcher setValue:fetcher forKey:@"eventFetcher"];
            if ([fetcher respondsToSelector:@selector(setEventFetcherSink:)]) [fetcher setEventFetcherSink:dispatcher];
            else [fetcher setValue:dispatcher forKey:@"eventFetcherSink"];
            [self setValue:fetcher forKey:@"eventFetcher"];
        } while (NO);
    }
    return self;
}
@end

@interface LSBubbleDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation LSBubbleDelegate {
    SBSAccessibilityWindowHostingController *_hosting;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    LSBubbleController *vc = [LSBubbleController new];
    self.window = [[LSBubbleWindow alloc] initWithFrame:CGRectMake(0, 0, kBubble, kBubble)];
    vc.win = self.window;
    self.window.rootViewController = vc;
    [self.window setWindowLevel:10000010.0];
    [self.window setHidden:NO];
    [self.window makeKeyAndVisible];

    _hosting = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init];
    unsigned int ctx = [self.window _contextId];
    double level = [self.window windowLevel];
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:"v@:Id"];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:_hosting];
    [inv setSelector:NSSelectorFromString(@"registerWindowWithContextID:atLevel:")];
    [inv setArgument:&ctx atIndex:2];
    [inv setArgument:&level atIndex:3];
    [inv invoke];
    [vc place];
    return YES;
}
@end

#pragma mark - Entry points

static void KeepAlive(pid_t me) {
    memorystatus_priority_properties_t props = { JETSAM_PRIORITY_CRITICAL, 0 };
    memorystatus_control(MEMORYSTATUS_CMD_SET_PRIORITY_PROPERTIES, me, 0, &props, sizeof(props));
    memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK, me, -1, NULL, 0);
    memorystatus_control(MEMORYSTATUS_CMD_SET_PROCESS_IS_MANAGED, me, 0, NULL, 0);
    proc_track_dirty(me, 0);
}

static int RunBubbleHUD(void) {
    pid_t pid = getpid();
    [[NSString stringWithFormat:@"%d", pid] writeToFile:@PID_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    KeepAlive(pid);

    [UIScreen initialize];
    CFRunLoopGetCurrent();
    GSInitialize();
    BKSDisplayServicesStart();
    UIApplicationInitialize();
    UIApplicationInstantiateSingleton(objc_getClass("LSBubbleApplication"));
    static id<UIApplicationDelegate> delegate = [[LSBubbleDelegate alloc] init];
    [UIApplication.sharedApplication setDelegate:delegate];
    [UIApplication.sharedApplication _accessibilityInit];
    [NSRunLoop currentRunLoop];
    if (@available(iOS 15.0, *)) {
        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
    }
    [UIApplication.sharedApplication __completeAndRunAsPlugin];

    static int sbToken;   // respring -> start again
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &sbToken, dispatch_get_main_queue(), ^(int token) {
        notify_cancel(token);
        BubbleSetEnabled(YES);
        kill(pid, SIGKILL);
    });
    CFRunLoopRun();
    return 0;
}

static pid_t ReadPid(void) {
    NSString *s = [NSString stringWithContentsOfFile:@PID_PATH encoding:NSUTF8StringEncoding error:nil];
    return s ? (pid_t)s.intValue : 0;
}

static int ExitBubbleHUD(void) {
    pid_t p = ReadPid();
    if (p > 0) kill(p, SIGKILL);
    unlink(PID_PATH);
    return 0;
}

BOOL BubbleIsRunning(void) {
    pid_t p = ReadPid();
    return (p > 0 && (kill(p, 0) == 0 || errno == EPERM)) ? YES : NO;
}

BOOL BubbleHandleLaunchArguments(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "-bubble-hud") == 0) { exit(RunBubbleHUD()); }
    if (argc > 1 && strcmp(argv[1], "-bubble-exit") == 0) { exit(ExitBubbleHUD()); }
    return NO;
}

// Runs this same app file with an argument, as root (TrollStore allows it).
static int SpawnSelf(const char *arg, BOOL wait) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *path = (char *)calloc(1, size);
    _NSGetExecutablePath(path, &size);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);
    if (!wait) {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    }
    pid_t child;
    const char *args[] = { path, arg, NULL };
    int rc = posix_spawn(&child, path, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    free(path);
    if (rc != 0) return -1;
    int status = 0;
    if (!wait) { waitpid(child, &status, WNOHANG); return 0; }
    while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void BubbleSetEnabled(BOOL on) {
    notify_post(NOTIFY_DISMISS);
    SpawnSelf("-bubble-exit", YES);
    if (on) SpawnSelf("-bubble-hud", NO);
}

void BubbleWriteStatus(NSString *json) {
    [json writeToFile:STATUS_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    notify_post(NOTIFY_STATUS);
}

void BubbleOnCommand(void (^handler)(int cmd)) {
    static int tok = 0;
    if (tok) notify_cancel(tok);
    notify_register_dispatch(NOTIFY_CMD, &tok, dispatch_get_main_queue(), ^(int t) {
        uint64_t v = 0;
        notify_get_state(t, &v);
        handler((int)v);
    });
}
