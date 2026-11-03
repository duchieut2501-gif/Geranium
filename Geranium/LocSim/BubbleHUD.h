// Floating bubble over every app (needs TrollStore). Window set-up based on TrollSpeed (MIT, Lessica).
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Runs the bubble process when the app was started with "-bubble-hud" / "-bubble-exit". Returns YES if it handled argv.
BOOL BubbleHandleLaunchArguments(int argc, char **argv);
/// Start / stop the bubble process (runs as root, separate from the app).
void BubbleSetEnabled(BOOL on);
BOOL BubbleIsRunning(void);
/// The app tells the bubble what to show (JSON), and gets the bubble's button presses:
/// 1 = stop simulating, 2 = pause / go on, 3 = slower, 4 = faster.
void BubbleWriteStatus(NSString *json);
void BubbleOnCommand(void (^handler)(int cmd));

#ifdef __cplusplus
}
#endif
