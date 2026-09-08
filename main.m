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

@interface DocumentWindow : NSObject <WKNavigationDelegate, NSWindowDelegate, NSTextViewDelegate>
@property (nonatomic, strong) NSURL *fileURL;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, weak) id<DocumentWindowHost> host;
@property (nonatomic, strong) dispatch_source_t fileMonitor;
@property (nonatomic, assign) double pendingScrollY;
@property (nonatomic, assign) BOOL reloadPending;
@property (nonatomic, strong) NSTextView *editor;
@property (nonatomic, strong) NSScrollView *editorScroll;
@property (nonatomic, strong) NSSplitView *splitView;
@property (nonatomic, strong) NSButton *editButton;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSButton *previewButton;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSData *diskSnapshot;
@property (nonatomic, copy) NSString *savedText;
@property (nonatomic, assign) NSStringEncoding fileEncoding;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) BOOL closed;
@property (nonatomic, assign) BOOL dirty;
@property (nonatomic, strong) NSTimer *previewTimer;
- (BOOL)confirmUnsavedChanges;
- (BOOL)saveChanges;

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
    _window.minSize = NSMakeSize(640, 400);
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 920, 800)];
    _window.contentView = content;
    NSStackView *bar = [[NSStackView alloc] init];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 12;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    _editButton = [NSButton buttonWithTitle:@"Edit" target:self action:@selector(toggleEditing:)];
    _saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(saveAction:)];
    _saveButton.enabled = NO;
    _previewButton = [NSButton checkboxWithTitle:@"Preview" target:self action:@selector(togglePreview:)];
    _previewButton.state = NSControlStateValueOn;
    _previewButton.hidden = YES;
    _statusLabel = [NSTextField labelWithString:@"Reading"];
    _statusLabel.textColor = NSColor.secondaryLabelColor;
    [_statusLabel setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [bar addArrangedSubview:_editButton];
    [bar addArrangedSubview:_saveButton];
    [bar addArrangedSubview:_previewButton];
    [bar addArrangedSubview:_statusLabel];
    [content addSubview:bar];
    _splitView = [[NSSplitView alloc] init];
    _splitView.vertical = YES;
    _splitView.dividerStyle = NSSplitViewDividerStyleThin;
    _splitView.translatesAutoresizingMaskIntoConstraints = NO;
    _editorScroll = [[NSScrollView alloc] init];
    _editorScroll.hasVerticalScroller = YES;
    _editor = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 450, 700)];
    _editor.richText = NO;
    _editor.importsGraphics = NO;
    _editor.allowsUndo = YES;
    _editor.usesFindBar = YES;
    _editor.incrementalSearchingEnabled = YES;
    _editor.automaticQuoteSubstitutionEnabled = NO;
    _editor.automaticDashSubstitutionEnabled = NO;
    _editor.automaticTextReplacementEnabled = NO;
    _editor.automaticSpellingCorrectionEnabled = NO;
    _editor.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
    _editor.textContainerInset = NSMakeSize(18, 18);
    _editor.minSize = NSMakeSize(0, 0);
    _editor.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _editor.verticallyResizable = YES;
    _editor.horizontallyResizable = NO;
    _editor.autoresizingMask = NSViewWidthSizable;
    _editor.textContainer.containerSize = NSMakeSize(450, CGFLOAT_MAX);
    _editor.textContainer.widthTracksTextView = YES;
    _editor.delegate = self;
    _editorScroll.documentView = _editor;
    [_splitView addArrangedSubview:_editorScroll];
    [_splitView addArrangedSubview:_webView];
    _editorScroll.hidden = YES;
    [content addSubview:_splitView];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [bar.topAnchor constraintEqualToAnchor:content.topAnchor constant:10],
        [bar.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-16],
        [_splitView.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:10],
        [_splitView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [_splitView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [_splitView.bottomAnchor constraintEqualToAnchor:content.bottomAnchor]
    ]];
    [_window center];
    [_window setFrameAutosaveName:@"MDViewerWindow"];
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(undoStateChanged:) name:NSUndoManagerDidUndoChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(undoStateChanged:) name:NSUndoManagerDidRedoChangeNotification object:nil];

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

    NSString *markdown = self.editing ? self.editor.string : [self readDiskText];
    if (!markdown) markdown = @"*Could not read file.*";

    // JSON-encode the markdown into a JS string literal
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@[markdown] options:0 error:NULL];
    NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[\"\"]";
    json = [json substringWithRange:NSMakeRange(1, json.length - 2)];
    json = [json stringByReplacingOccurrencesOfString:@"<" withString:@"\\u003c"]; // unwrap [ ... ]

    NSString *html = template;
    html = [html stringByReplacingOccurrencesOfString:@"__MARKED_JS__" withString:markedJS];
    html = [html stringByReplacingOccurrencesOfString:@"__HLJS_JS__" withString:hljsJS];
    html = [html stringByReplacingOccurrencesOfString:@"__MD_JSON__" withString:json];

    NSURLComponents *base = [[NSURLComponents alloc] init];
    base.scheme = @"mdfile";
    base.path = [self.fileURL.URLByDeletingLastPathComponent.path stringByAppendingString:@"/"];
    [self.webView loadHTMLString:html baseURL:base.URL];
}


#pragma mark Editing

- (NSString *)readDiskText {
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL];
    if (!data) return nil;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Could not save document";
    alert.informativeText = message;
    [alert runModal];
}

- (BOOL)loadEditorFromDisk {
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL];
    if (!data) return NO;
    self.fileEncoding = NSUTF8StringEncoding;
    NSString *text = [[NSString alloc] initWithData:data encoding:self.fileEncoding];
    if (!text) {
        self.fileEncoding = NSISOLatin1StringEncoding;
        text = [[NSString alloc] initWithData:data encoding:self.fileEncoding];
    }
    if (!text) return NO;
    self.diskSnapshot = data;
    self.savedText = text;
    self.editor.string = text;
    [self.editor.undoManager removeAllActions];
    [self updateDirtyState];
    return YES;
}

- (void)updateDirtyState {
    self.dirty = ![self.editor.string isEqualToString:self.savedText];
    self.window.documentEdited = self.dirty;
    self.saveButton.enabled = self.editing && self.dirty;
    self.statusLabel.stringValue = self.dirty ? @"Unsaved changes" : (self.editing ? @"Saved" : @"Reading");
}

- (void)toggleEditing:(id)sender {
    if (self.editing) {
        if (![self confirmUnsavedChanges]) return;
        self.editing = NO;
        self.dirty = NO;
        self.window.documentEdited = NO;
        self.editorScroll.hidden = YES;
        self.webView.hidden = NO;
        self.editButton.title = @"Edit";
        self.previewButton.hidden = YES;
        self.saveButton.enabled = NO;
        self.statusLabel.stringValue = @"Reading";
        [self.previewTimer invalidate];
    } else {
        if (![self loadEditorFromDisk]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Could not open this file for editing";
            alert.informativeText = @"Check that the file still exists and is readable.";
            [alert runModal];
            return;
        }
        self.editing = YES;
        self.editorScroll.hidden = NO;
        self.previewButton.hidden = NO;
        self.webView.hidden = self.previewButton.state != NSControlStateValueOn;
        self.editButton.title = @"Done";
        self.statusLabel.stringValue = @"Saved";
        [self.window.contentView layoutSubtreeIfNeeded];
        [self.splitView adjustSubviews];
        if (!self.webView.hidden) [self.splitView setPosition:self.splitView.bounds.size.width / 2 ofDividerAtIndex:0];
        [self.window makeFirstResponder:self.editor];
    }
    [self.splitView adjustSubviews];
    [self render];
}

- (void)togglePreview:(id)sender {
    self.webView.hidden = self.previewButton.state != NSControlStateValueOn;
    [self.splitView adjustSubviews];
    if (!self.webView.hidden) {
        [self.splitView setPosition:self.splitView.bounds.size.width / 2 ofDividerAtIndex:0];
        [self render];
    }
}

- (void)undoStateChanged:(NSNotification *)notification {
    if (self.editing && notification.object == self.editor.undoManager) [self textDidChange:notification];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)textDidChange:(NSNotification *)notification {
    [self updateDirtyState];
    [self.previewTimer invalidate];
    __weak DocumentWindow *weakSelf = self;
    self.previewTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) {
        DocumentWindow *doc = weakSelf;
        if (!doc || !doc.editing || doc.webView.hidden) return;
        [doc.webView evaluateJavaScript:@"window.scrollY" completionHandler:^(id value, NSError *error) {
            if (!doc.editing) return;
            doc.pendingScrollY = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
            [doc render];
        }];
    }];
}

- (BOOL)saveChanges {
    if (!self.editing || !self.dirty) return YES;
    NSData *output = [self.editor.string dataUsingEncoding:self.fileEncoding allowLossyConversion:NO];
    if (!output) {
        [self showError:@"This file’s original encoding cannot represent the new text. Copy your edits before converting the file to UTF-8 in another editor."];
        return NO;
    }
    // Coordinate the check and atomic replacement with other cooperating file writers.
    __block BOOL saved = NO;
    __block BOOL conflict = NO;
    __block NSError *writeError = nil;
    NSError *coordinationError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateWritingItemAtURL:self.fileURL options:0 error:&coordinationError byAccessor:^(NSURL *url) {
        NSData *latest = [NSData dataWithContentsOfURL:url];
        if (![latest isEqual:self.diskSnapshot]) { conflict = YES; return; }
        saved = [output writeToURL:url options:NSDataWritingAtomic error:&writeError];
    }];
    if (conflict) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"The original file changed";
        alert.informativeText = @"Your edits have been kept. Save a copy to preserve both versions, or cancel and continue editing.";
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Save a Copy…"];
        if ([alert runModal] == NSAlertSecondButtonReturn) [self saveCopy:nil];
        return NO;
    }
    if (!saved) {
        [self showError:(writeError ?: coordinationError).localizedDescription ?: @"The file could not be written. Your edits have been kept; you can use File → Save a Copy."];
        return NO;
    }
    self.diskSnapshot = output;
    self.savedText = self.editor.string;
    [self updateDirtyState];
    return YES;
}

- (void)saveAction:(id)sender { [self saveChanges]; }

- (void)saveCopy:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%@ copy.%@", self.fileURL.lastPathComponent.stringByDeletingPathExtension, self.fileURL.pathExtension];
    panel.directoryURL = self.fileURL.URLByDeletingLastPathComponent;
    if ([panel runModal] != NSModalResponseOK) return;
    if ([panel.URL.URLByStandardizingPath isEqual:self.fileURL.URLByStandardizingPath]) {
        [self showError:@"Choose a different filename to preserve the original document."];
        return;
    }
    NSError *error = nil;
    NSString *text = self.editing ? self.editor.string : [self readDiskText];
    if (!text || ![text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showError:error.localizedDescription ?: @"Could not read the document."];
        return;
    }
    self.statusLabel.stringValue = self.dirty ? @"Copy saved — original edits still unsaved" : @"Copy saved";
}

- (BOOL)confirmUnsavedChanges {
    if (!self.dirty) return YES;
    [self.window makeKeyAndOrderFront:nil];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Save changes to “%@”?", self.fileURL.lastPathComponent];
    alert.informativeText = @"Your changes will be lost if you discard them.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Discard"];
    [alert addButtonWithTitle:@"Cancel"];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) return [self saveChanges];
    if (response == NSAlertSecondButtonReturn) {
        return YES;
    }
    return NO;
}

- (BOOL)windowShouldClose:(NSWindow *)sender { return [self confirmUnsavedChanges]; }

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
        if (!self || self.closed) return;
        self.reloadPending = NO;
        if (self.fileMonitor) dispatch_source_cancel(self.fileMonitor);
        self.fileMonitor = nil;
        [self.webView evaluateJavaScript:@"window.scrollY" completionHandler:^(id value, NSError *err) {
            if (self.closed) return;
            self.pendingScrollY = [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
            if (self.editing) {
                NSData *latest = [NSData dataWithContentsOfURL:self.fileURL];
                if (![latest isEqual:self.diskSnapshot]) {
                    if (self.dirty) {
                        self.statusLabel.stringValue = @"File changed outside MD Viewer — save to review";
                    } else if (latest) {
                        [self loadEditorFromDisk];
                    } else {
                        self.statusLabel.stringValue = @"File unavailable — your text is still here";
                    }
                }
            }
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
    self.closed = YES;
    [self.previewTimer invalidate];
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
    url = url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
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

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    for (DocumentWindow *doc in [self.documents copy]) {
        if (![doc confirmUnsavedChanges]) return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)saveAction:(id)sender { [[self currentDocument] saveChanges]; }
- (void)saveCopyAction:(id)sender { [[self currentDocument] saveCopy:sender]; }
- (void)editAction:(id)sender { [[self currentDocument] toggleEditing:sender]; }
- (void)findAction:(id)sender {
    DocumentWindow *doc = [self currentDocument];
    if (!doc) return;
    if (!doc.editing) [doc toggleEditing:nil];
    if (!doc.editing) return;
    [doc.window makeFirstResponder:doc.editor];
    NSMenuItem *item = [[NSMenuItem alloc] init];
    item.tag = NSTextFinderActionShowFindInterface;
    [doc.editor performTextFinderAction:item];
}
- (void)openOtherEditor:(id)sender {
    DocumentWindow *doc = [self currentDocument];
    if (!doc) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose an editor";
    panel.directoryURL = [NSURL fileURLWithPath:@"/Applications"];
    panel.allowedContentTypes = @[[UTType typeWithIdentifier:@"com.apple.application-bundle"]];
    if ([panel runModal] != NSModalResponseOK) return;
    if ([panel.URL isEqual:NSBundle.mainBundle.bundleURL]) return;
    if (doc.editing) [doc toggleEditing:nil];
    if (doc.editing) return;
    [[NSWorkspace sharedWorkspace] openURLs:@[doc.fileURL] withApplicationAtURL:panel.URL configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:^(NSRunningApplication *app, NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp presentError:error]; });
    }];
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
    [fileMenu addItemWithTitle:@"Save" action:@selector(saveAction:) keyEquivalent:@"s"];
    [fileMenu addItemWithTitle:@"Save a Copy…" action:@selector(saveCopyAction:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Open in Other Editor…" action:@selector(openOtherEditor:) keyEquivalent:@""];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editItem.submenu = editMenu;
    [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Find…" action:@selector(findAction:) keyEquivalent:@"f"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    viewItem.submenu = viewMenu;
    [viewMenu addItemWithTitle:@"Edit / Done" action:@selector(editAction:) keyEquivalent:@"e"];
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
