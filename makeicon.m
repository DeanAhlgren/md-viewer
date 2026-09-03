// Draws the app icon (rounded dark tile with the "M↓" markdown mark) at 1024px.
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: makeicon out.png\n"); return 1; }
        CGFloat size = 1024;
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
        [image lockFocus];

        CGFloat inset = size * 0.09;
        NSRect tile = NSMakeRect(inset, inset, size - inset * 2, size - inset * 2);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:tile
                                                             xRadius:size * 0.185
                                                             yRadius:size * 0.185];
        NSGradient *gradient = [[NSGradient alloc] initWithColors:@[
            [NSColor colorWithCalibratedRed:0.13 green:0.16 blue:0.22 alpha:1],
            [NSColor colorWithCalibratedRed:0.05 green:0.07 blue:0.10 alpha:1],
        ]];
        [gradient drawInBezierPath:path angle:-90];

        [[NSColor whiteColor] setStroke];
        CGFloat stroke = size * 0.062;

        NSBezierPath *glyph = [NSBezierPath bezierPath];
        glyph.lineWidth = stroke;
        glyph.lineCapStyle = NSLineCapStyleRound;
        glyph.lineJoinStyle = NSLineJoinStyleRound;
        CGFloat baseY = size * 0.36, topY = size * 0.62;
        [glyph moveToPoint:NSMakePoint(size * 0.24, baseY)];
        [glyph lineToPoint:NSMakePoint(size * 0.24, topY)];
        [glyph lineToPoint:NSMakePoint(size * 0.37, size * 0.46)];
        [glyph lineToPoint:NSMakePoint(size * 0.50, topY)];
        [glyph lineToPoint:NSMakePoint(size * 0.50, baseY)];
        [glyph stroke];

        CGFloat ax = size * 0.68;
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        arrow.lineWidth = stroke;
        arrow.lineCapStyle = NSLineCapStyleRound;
        arrow.lineJoinStyle = NSLineJoinStyleRound;
        [arrow moveToPoint:NSMakePoint(ax, topY)];
        [arrow lineToPoint:NSMakePoint(ax, baseY + size * 0.02)];
        [arrow moveToPoint:NSMakePoint(ax - size * 0.09, baseY + size * 0.11)];
        [arrow lineToPoint:NSMakePoint(ax, baseY)];
        [arrow lineToPoint:NSMakePoint(ax + size * 0.09, baseY + size * 0.11)];
        [arrow stroke];

        [image unlockFocus];

        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[image TIFFRepresentation]];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[1]) atomically:YES]) {
            fprintf(stderr, "write failed\n");
            return 1;
        }
    }
    return 0;
}
