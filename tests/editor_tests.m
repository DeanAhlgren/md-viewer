#define main MDViewerApplicationMain
#import "../main.m"
#import <objc/runtime.h>
#undef main
#define CHECK(x) do { if (!(x)) { NSLog(@"FAIL line %d: %s", __LINE__, #x); exit(1); } } while (0)
static NSModalResponse testResponse = NSAlertThirdButtonReturn;
static NSInteger alertCount = 0;
@interface NSAlert (TestResponses)
- (NSModalResponse)testRunModal;
@end
@implementation NSAlert (TestResponses)
- (NSModalResponse)testRunModal { alertCount++; return testResponse; }
@end
// Keep the real disk/save implementation; avoid modal UI in automated checks.
@interface TestDocument : DocumentWindow
@property BOOL errorShown;
@end
@implementation TestDocument
- (void)showError:(NSString *)message { self.errorShown = YES; }
@end
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        method_exchangeImplementations(class_getInstanceMethod(NSAlert.class, @selector(runModal)), class_getInstanceMethod(NSAlert.class, @selector(testRunModal)));
        NSURL *directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        CHECK([[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
        NSURL *url = [directory URLByAppendingPathComponent:@"test.md"];
        NSString *original = @"---\r\ntitle: Test\r\n---\r\n# Hello 🌺\r\n\r\n- [ ] Task\r\n";
        CHECK([original writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        TestDocument *doc = [[TestDocument alloc] initWithFileURL:url host:nil];
        CHECK(!doc.editing && doc.editorScroll.hidden);
        [doc toggleEditing:nil];
        CHECK(doc.editing && !doc.editorScroll.hidden);
        CHECK([doc.editor.string isEqualToString:original]);
        CHECK(!doc.editor.richText && doc.editor.allowsUndo);
        CHECK(!doc.editor.automaticQuoteSubstitutionEnabled);
        doc.editor.string = [original stringByAppendingString:@"\r\nNew text\r\n"];
        [doc textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:doc.editor]];
        CHECK(doc.dirty && doc.window.documentEdited && doc.saveButton.enabled);
        CHECK([doc saveChanges]);
        CHECK(!doc.dirty && !doc.window.documentEdited);
        CHECK([[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL] isEqualToString:doc.editor.string]);
        [doc toggleEditing:nil];
        CHECK(!doc.editing && doc.editorScroll.hidden && !doc.webView.hidden);
        [doc toggleEditing:nil];
        doc.previewButton.state = NSControlStateValueOff;
        [doc togglePreview:nil]; CHECK(doc.webView.hidden);
        doc.previewButton.state = NSControlStateValueOn;
        [doc togglePreview:nil]; CHECK(!doc.webView.hidden);
        // Returning to the saved text clears the edited flag.
        doc.editor.string = @"temporary"; [doc textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:doc.editor]]; CHECK(doc.dirty);
        doc.editor.string = doc.savedText; [doc textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:doc.editor]]; CHECK(!doc.dirty);
        // Native undo restores the saved state.
        [doc.window makeFirstResponder:doc.editor];
        [doc.editor insertText:@"added" replacementRange:NSMakeRange(doc.editor.string.length, 0)];
        CHECK(doc.dirty && doc.editor.undoManager.canUndo);
        [doc.editor.undoManager undo];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        CHECK(!doc.dirty);
        // Cancel and Discard are decisions, not destructive draft mutations.
        doc.editor.string = @"draft"; [doc updateDirtyState];
        testResponse = NSAlertThirdButtonReturn;
        CHECK(![doc confirmUnsavedChanges] && doc.dirty);
        [doc toggleEditing:nil]; CHECK(doc.editing && doc.dirty);
        testResponse = NSAlertSecondButtonReturn;
        CHECK([doc confirmUnsavedChanges] && doc.dirty);
        // External replacement and deletion cannot silently overwrite the disk.
        NSData *external = [@"external" dataUsingEncoding:NSUTF8StringEncoding];
        CHECK([external writeToURL:url atomically:YES]);
        testResponse = NSAlertFirstButtonReturn;
        NSInteger before = alertCount;
        CHECK(![doc saveChanges] && doc.dirty && alertCount == before + 1);
        CHECK([[NSData dataWithContentsOfURL:url] isEqual:external]);
        CHECK([[NSFileManager defaultManager] removeItemAtURL:url error:NULL]);
        CHECK(![doc saveChanges] && doc.dirty);
        CHECK(![[NSFileManager defaultManager] fileExistsAtPath:url.path]);
        // Legacy encoding round trips without silent lossy conversion.
        NSData *latin = [@"café\r\n" dataUsingEncoding:NSISOLatin1StringEncoding];
        CHECK([latin writeToURL:url atomically:YES]);
        CHECK([doc loadEditorFromDisk]); CHECK(doc.fileEncoding == NSISOLatin1StringEncoding);
        doc.editor.string = @"café edited\r\n"; [doc textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:doc.editor]]; CHECK([doc saveChanges]);
        NSData *saved = [NSData dataWithContentsOfURL:url];
        doc.editor.string = @"🌺"; [doc textDidChange:[NSNotification notificationWithName:NSTextDidChangeNotification object:doc.editor]];
        CHECK(![doc saveChanges] && doc.errorShown && doc.dirty);
        CHECK([[NSData dataWithContentsOfURL:url] isEqual:saved]);
        // Exercise the bundled renderer, including literal script-ending text.
        CHECK([[NSFileManager defaultManager] fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"template.html"]]);
        doc.editor.string = @"# Preview marker\n\n**bold**\n\n`</script>`";
        [doc render];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (doc.webView.loading && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        __block BOOL evaluated = NO;
        __block BOOL previewOK = NO;
        [doc.webView evaluateJavaScript:@"document.querySelector('h1').textContent === 'Preview marker' && document.querySelector('strong').textContent === 'bold' && document.querySelector('code').textContent === '</script>'" completionHandler:^(id value, NSError *error) {
            previewOK = !error && [value boolValue]; evaluated = YES;
        }];
        while (!evaluated && deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        }
        CHECK(evaluated && previewOK);
        [doc.previewTimer invalidate];
        if (doc.fileMonitor) dispatch_source_cancel(doc.fileMonitor);
        [doc.window.contentView layoutSubtreeIfNeeded];
        CHECK(doc.editorScroll.frame.size.width > 100 && doc.webView.frame.size.width > 100);
        CHECK(doc.splitView.frame.size.height > 300);
        [[NSFileManager defaultManager] removeItemAtURL:directory error:NULL];
        NSLog(@"PASS: bundled Markdown rendering, conflict/deletion protection, cancel/discard, native undo, layout,  editing modes, preview toggle, dirty state, atomic save, CRLF/Unicode, legacy encoding and failed-save draft retention");
    }
    return 0;
}
