// Windowed preview harness — hosts STStoolView in a normal resizable NSWindow so
// changes can be seen instantly without the System Settings / stale-host dance.
#import <Cocoa/Cocoa.h>
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>

@interface STStoolView : ScreenSaverView
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(0, 0, 1512, 982);
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = @"Stool Bounce Preview";
        [win center];

        STStoolView *view = [[STStoolView alloc] initWithFrame:frame isPreview:NO];
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        win.contentView = view;
        [view startAnimation];

        NSMenu *mainMenu = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [mainMenu addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        NSMenuItem *quitItem = [appMenu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];
        quitItem.target = app;
        appMenuItem.submenu = appMenu;
        app.mainMenu = mainMenu;

        // The real screensaver host drives animateOneFrame on a timer; do the same here.
        [NSTimer scheduledTimerWithTimeInterval:view.animationTimeInterval
                                         repeats:YES
                                           block:^(NSTimer *t) { [view animateOneFrame]; }];

        // ST_DUMP=<path>: render the live layer tree to a PNG after a moment, then quit.
        if (getenv("ST_DUMP")) {
            NSString *path = [NSString stringWithUTF8String:getenv("ST_DUMP")];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((getenv("ST_DUMP_T") ? atof(getenv("ST_DUMP_T")) : 1.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CALayer *root = view.layer;
                CGSize sz = root.bounds.size;
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                CGContextRef ctx = CGBitmapContextCreate(NULL, sz.width, sz.height, 8, 0, cs, kCGImageAlphaPremultipliedLast);
                CGColorSpaceRelease(cs);
                [root renderInContext:ctx];
                CGImageRef img = CGBitmapContextCreateImage(ctx);
                CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (CFStringRef)@"public.png", 1, NULL);
                CGImageDestinationAddImage(d, img, NULL);
                CGImageDestinationFinalize(d);
                CFRelease(d); CGImageRelease(img); CGContextRelease(ctx);
                [app terminate:nil];
            });
        }

        [win makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
