// MD Viewer — a tiny local markdown viewer.
// Double-click a .md file and it renders with GitHub-style formatting.
// Everything happens locally: no network, no telemetry.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSSet<NSString *> *MarkdownExtensions(void) {
    static NSSet *exts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        exts = [NSSet setWithArray:@[@"md", @"markdown", @"mdown", @"mkd", @"mkdn", @"mdwn", @"mdtext"]];
    });
    return exts;
}

static NSString *MimeTypeForExtension(NSString *ext) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"png": @"image/png", @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg",
                 @"gif": @"image/gif", @"svg": @"image/svg+xml", @"webp": @"image/webp",
                 @"bmp": @"image/bmp", @"ico": @"image/x-icon", @"css": @"text/css",
                 @"js": @"text/javascript", @"html": @"text/html", @"htm": @"text/html",
                 @"pdf": @"application/pdf", @"mp4": @"video/mp4", @"mov": @"video/quicktime" };
    });
    return map[ext] ?: @"application/octet-stream";
}

#pragma mark - Local file scheme handler

// Serves images and other local files referenced by the markdown under a
// custom scheme, since WKWebView blocks file:// subresources from loadHTMLString.
@interface LocalFileSchemeHandler : NSObject <WKURLSchemeHandler>
@end

@implementation LocalFileSchemeHandler
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url = task.request.URL;
    if (!url) return;
    NSURL *fileURL = [NSURL fileURLWithPath:url.path];
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:fileURL options:0 error:&error];
    if (!data) {
        [task didFailWithError:error ?: [NSError errorWithDomain:NSCocoaErrorDomain
                                                            code:NSFileReadNoSuchFileError
                                                        userInfo:nil]];
        return;
    }
    NSURLResponse *response = [[NSURLResponse alloc]
        initWithURL:url
           MIMEType:MimeTypeForExtension(fileURL.pathExtension.lowercaseString)
        expectedContentLength:(NSInteger)data.length
        textEncodingName:nil];
    [task didReceiveResponse:response];
    [task didReceiveData:data];
    [task didFinish];
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {}
@end

#pragma mark - Document window

@class DocumentWindow;

@protocol DocumentWindowHost <NSObject>
- (void)openDocumentAtURL:(NSURL *)url;
- (void)documentWindowDidClose:(DocumentWindow *)doc;
@end

@interface DocumentWindow : NSObject <WKNavigationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, weak) id<DocumentWindowHost> host;
@property (nonatomic, strong) dispatch_source_t fileMonitor;
@property (nonatomic, assign) double pendingScrollY;
@property (nonatomic, assign) BOOL reloadPending;
@end

@implementation DocumentWindow

- (instancetype)initWithFileURL:(NSURL *)fileURL host:(id<DocumentWindowHost>)host {
    self = [super init];
    if (!self) return nil;
    _fileURL = fileURL;
    _host = host;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config setURLSchemeHandler:[[LocalFileSchemeHandler alloc] init] forURLScheme:@"mdfile"];
    _webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    _webView.allowsMagnification = YES;
    _webView.navigationDelegate = self;

    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 920, 800)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.title = fileURL.lastPathComponent;
    if (@available(macOS 11.0, *)) {
        _window.subtitle = [fileURL.URLByDeletingLastPathComponent.path
            stringByReplacingOccurrencesOfString:NSHomeDirectory() withString:@"~"];
    }
    _window.tabbingMode = NSWindowTabbingModePreferred;
    _window.contentView = _webView;
    [_window center];
    [_window setFrameAutosaveName:@"MDViewerWindow"];
    _window.releasedWhenClosed = NO;
    _window.delegate = self;

    [self render];
    [self startFileMonitor];
    return self;
}

- (void)show {
    [self.window makeKeyAndOrderFront:nil];
}

- (void)render {
    NSURL *resources = [NSBundle mainBundle].resourceURL;
    NSString *template = [NSString stringWithContentsOfURL:[resources URLByAppendingPathComponent:@"template.html"]
                                                  encoding:NSUTF8StringEncoding error:NULL];
    NSString *markedJS = [NSString stringWithContentsOfURL:[resources URLByAppendingPathComponent:@"marked.min.js"]
                                                  encoding:NSUTF8StringEncoding error:NULL];
    NSString *hljsJS = [NSString stringWithContentsOfURL:[resources URLByAppendingPathComponent:@"highlight.min.js"]
                                                encoding:NSUTF8StringEncoding error:NULL];
    if (!template || !markedJS || !hljsJS) {
        [self.webView loadHTMLString:@"<h2 style='font-family:sans-serif'>MD Viewer: bundle resources missing</h2>"
                             baseURL:nil];
        return;
    }

    NSString *markdown = [NSString stringWithContentsOfURL:self.fileURL
                                                  encoding:NSUTF8StringEncoding error:NULL];
    if (!markdown) {
        markdown = [NSString stringWithContentsOfURL:self.fileURL
                                            encoding:NSISOLatin1StringEncoding error:NULL];
    }
    if (!markdown) markdown = @"*Could not read file.*";
    markdown = [markdown stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];

    // JSON-encode the markdown into a JS string literal
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[markdown] options:0 error:NULL];
    NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[\"\"]";
    json = [json substringWithRange:NSMakeRange(1, json.length - 2)]; // unwrap [ ... ]

    NSString *html = template;
    html = [html stringByReplacingOccurrencesOfString:@"__MARKED_JS__" withString:markedJS];
    html = [html stringByReplacingOccurrencesOfString:@"__HLJS_JS__" withString:hljsJS];
    html = [html stringByReplacingOccurrencesOfString:@"__MD_JSON__" withString:json];

    NSURLComponents *base = [[NSURLComponents alloc] init];
    base.scheme = @"mdfile";
    base.path = [self.fileURL.URLByDeletingLastPathComponent.path stringByAppendingString:@"/"];
    [self.webView loadHTMLString:html baseURL:base.URL];
}

#pragma mark Live reload

- (void)startFileMonitor {
    int fd = open(self.fileURL.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) return;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_EXTEND,
        dispatch_get_main_queue());
    __weak DocumentWindow *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{ [weakSelf fileChanged]; });
    dispatch_source_set_cancel_handler(source, ^{ close(fd); });
    dispatch_resume(source);
    self.fileMonitor = source;
}

- (void)fileChanged {
    if (self.reloadPending) return;
    self.reloadPending = YES;
    // Debounce; editors often replace the file (rename), so re-arm the monitor too.
    __weak DocumentWindow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DocumentWindow *self = weakSelf;
        if (!self) return;
        self.reloadPending = NO;
        if (self.fileMonitor) dispatch_source_cancel(self.fileMonitor);
        self.fileMonitor = nil;
        [self.webView evaluateJavaScript:@"window.scrollY" completionHandler:^(id value, NSError *err) {
            self.pendingScrollY = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
            [self render];
            [self startFileMonitor];
        }];
    });
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (self.pendingScrollY > 0) {
        NSString *js = [NSString stringWithFormat:@"window.scrollTo(0, %f)", self.pendingScrollY];
        [webView evaluateJavaScript:js completionHandler:nil];
        self.pendingScrollY = 0;
    }
}

#pragma mark Link handling

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if (action.navigationType != WKNavigationTypeLinkActivated || !action.request.URL) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    NSURL *url = action.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] ||
        [scheme isEqualToString:@"mailto"]) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
    } else if ([scheme isEqualToString:@"mdfile"]) {
        NSURL *target = [NSURL fileURLWithPath:url.path];
        if ([MarkdownExtensions() containsObject:target.pathExtension.lowercaseString]) {
            [self.host openDocumentAtURL:target];
        } else {
            [[NSWorkspace sharedWorkspace] openURL:target];
        }
        decisionHandler(WKNavigationActionPolicyCancel);
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)windowWillClose:(NSNotification *)notification {
    if (self.fileMonitor) dispatch_source_cancel(self.fileMonitor);
    self.fileMonitor = nil;
    [self.host documentWindowDidClose:self];
}

@end

#pragma mark - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, DocumentWindowHost>
@property (nonatomic, strong) NSMutableArray<DocumentWindow *> *documents;
@end

@implementation AppDelegate

- (instancetype)init {
    self = [super init];
    _documents = [NSMutableArray array];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) [self openDocumentAtURL:url];
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    [self showOpenPanel];
    return YES;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)openDocumentAtURL:(NSURL *)url {
    url = url.URLByStandardizingPath;
    for (DocumentWindow *doc in self.documents) {
        if ([doc.fileURL isEqual:url]) { [doc show]; return; }
    }
    DocumentWindow *doc = [[DocumentWindow alloc] initWithFileURL:url host:self];
    [self.documents addObject:doc];
    [doc show];
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:url];
}

- (void)documentWindowDidClose:(DocumentWindow *)doc {
    [self.documents removeObject:doc];
}

- (void)openDocumentAction:(id)sender {
    [self showOpenPanel];
}

- (void)showOpenPanel {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = YES;
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    UTType *md = [UTType typeWithIdentifier:@"net.daringfireball.markdown"];
    if (md) [types addObject:md];
    for (NSString *ext in MarkdownExtensions()) {
        UTType *t = [UTType typeWithFilenameExtension:ext];
        if (t) [types addObject:t];
    }
    panel.allowedContentTypes = types;
    __weak AppDelegate *weakSelf = self;
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        for (NSURL *url in panel.URLs) [weakSelf openDocumentAtURL:url];
    }];
}

- (DocumentWindow *)currentDocument {
    NSWindow *key = NSApp.keyWindow;
    for (DocumentWindow *doc in self.documents) {
        if (doc.window == key) return doc;
    }
    return nil;
}

- (void)reloadAction:(id)sender {
    [[self currentDocument] render];
}

- (void)adjustZoomBy:(CGFloat)delta {
    WKWebView *webView = [self currentDocument].webView;
    if (!webView) return;
    webView.pageZoom = MAX(0.5, MIN(3.0, webView.pageZoom + delta));
}

- (void)zoomIn:(id)sender { [self adjustZoomBy:0.1]; }
- (void)zoomOut:(id)sender { [self adjustZoomBy:-0.1]; }
- (void)zoomReset:(id)sender { [self currentDocument].webView.pageZoom = 1.0; }

@end

#pragma mark - Menu

static NSMenu *BuildMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    appItem.submenu = appMenu;
    [appMenu addItemWithTitle:@"About MD Viewer"
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide MD Viewer" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit MD Viewer" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenuItem *fileItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    fileItem.submenu = fileMenu;
    [fileMenu addItemWithTitle:@"Open…" action:@selector(openDocumentAction:) keyEquivalent:@"o"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = viewMenu;
    [viewMenu addItemWithTitle:@"Reload" action:@selector(reloadAction:) keyEquivalent:@"r"];
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
    [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
    [viewMenu addItemWithTitle:@"Actual Size" action:@selector(zoomReset:) keyEquivalent:@"0"];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    windowItem.submenu = windowMenu;
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    NSApp.windowsMenu = windowMenu;

    return mainMenu;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        static AppDelegate *delegate;
        delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        app.mainMenu = BuildMenu();
        [app run];
    }
    return 0;
}
