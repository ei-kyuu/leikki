// stool-bounce — Alvar Aalto pieces tumbling around the screen as 2D rigid
// bodies: gravity, spin, and friction against the screen edges and each other.
// Options picks the group: his stools (60, E60, Bar Stool 64), tables and the
// Tea Trolley 900, or iittala's Aalto vases.
//
// Each piece is a hidden-line drawing of a 3D model (STStoolModel.m), built once
// as a CGPath in centimetres and hosted in a CAShapeLayer; physics only moves and
// rotates those layers. Collisions use the convex hull of each drawing, so the
// strokes never leave the screen. A group shares one scale, so pieces keep
// their real relative sizes. Glass is drawn see-through: the lines behind its
// front surfaces are kept, faintly.
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>
#import "STStoolModel.h"

#pragma mark - Geometry helpers

static CGFloat Cross(CGPoint o, CGPoint a, CGPoint b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

// Andrew's monotone chain; returns the hull counter-clockwise.
static NSArray<NSValue *> *ConvexHull(NSArray<NSValue *> *input) {
    NSArray *s = [input sortedArrayUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGPoint p = a.pointValue, q = b.pointValue;
        if (p.x != q.x) return p.x < q.x ? NSOrderedAscending : NSOrderedDescending;
        if (p.y != q.y) return p.y < q.y ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray<NSValue *> *h = [NSMutableArray array];
    for (int pass = 0; pass < 2; pass++) {
        NSUInteger start = h.count;
        NSEnumerator *e = pass == 0 ? s.objectEnumerator : s.reverseObjectEnumerator;
        for (NSValue *v in e) {
            while (h.count >= start + 2 &&
                   Cross(h[h.count - 2].pointValue, h[h.count - 1].pointValue, v.pointValue) <= 0)
                [h removeLastObject];
            [h addObject:v];
        }
        [h removeLastObject];
    }
    return h;
}

#pragma mark - Type

// Small type laid out like a Swiss poster: the quote in the top-left corner and
// three city clocks in the bottom-left, all hanging off one left margin.
// Akkurat when the build bundles it (the author's own copy); otherwise Helvetica
// Neue, which ships with every Mac, so shared builds carry no licensed font.
static BOOL sHaveAkkurat;
static NSString *TypeFontName(void) { return sHaveAkkurat ? @"Akkurat" : @"HelveticaNeue"; }

static const struct { const char *city; const char *zone; } kClocks[] = {
    { "Toronto",       "America/Toronto" },
    { "San Francisco", "America/Los_Angeles" },
    { "London",        "Europe/London" },
};
#define ST_CLOCKS (sizeof(kClocks) / sizeof(kClocks[0]))

static NSString *const kPlayFont = @"Futura-Medium";   // ships with macOS

typedef NS_ENUM(NSInteger, STText) { STTextPoster, STTextPlay, STTextCount };
static NSString *const kTextNames[STTextCount] = { @"1 — Poster", @"2 — Play" };

static void RegisterFonts(NSBundle *bundle) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url = [bundle URLForResource:@"Akkurat" withExtension:@"ttf"];
        if (url) CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
        // CoreText substitutes silently for a missing name, so check what resolved.
        CTFontRef f = CTFontCreateWithName(CFSTR("Akkurat"), 12, NULL);
        CFStringRef ps = CTFontCopyPostScriptName(f);
        sHaveAkkurat = CFEqual(ps, CFSTR("Akkurat"));
        CFRelease(ps);
        CFRelease(f);
    });
}

// Settings live in a plain plist rather than ScreenSaverDefaults: the Options
// sheet and the rendering host can be separate processes with separate
// preferences containers, so CFPreferences writes don't reliably cross over.
static NSURL *SettingsFileURL(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [base URLByAppendingPathComponent:@"com.aq.leikki" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"settings.plist"];
}

// Append `text`'s glyph outlines to `path` with its baseline starting at (x, y).
static void AddText(CGMutablePathRef path, NSString *text, CTFontRef font, CGFloat x, CGFloat y) {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text
        attributes:@{ (__bridge NSString *)kCTFontAttributeName: (__bridge id)font }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    for (id r in (__bridge NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (__bridge CTRunRef)r;
        CTFontRef rf = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CFIndex count = CTRunGetGlyphCount(run);
        for (CFIndex g = 0; g < count; g++) {
            CGGlyph glyph; CGPoint pos;
            CTRunGetGlyphs(run, CFRangeMake(g, 1), &glyph);
            CTRunGetPositions(run, CFRangeMake(g, 1), &pos);
            CGPathRef gp = CTFontCreatePathForGlyph(rf, glyph, NULL);
            if (!gp) continue;
            CGAffineTransform t = CGAffineTransformMakeTranslation(x + pos.x, y + pos.y);
            CGPathAddPath(path, &t, gp);
            CGPathRelease(gp);
        }
    }
    CFRelease(line);
}

static CGFloat TextWidth(NSString *text, CTFontRef font) {
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text
        attributes:@{ (__bridge NSString *)kCTFontAttributeName: (__bridge id)font }];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
    CGFloat w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    return w;
}

#pragma mark - View

#define ST_MAX_HULL 256
#define ST_MAX_BODIES 4

typedef struct {
    CALayer *node;                       // moves and turns; holds the three below
    CALayer *fill;                       // minute fill, one pixel per dither block
    CAShapeLayer *ghost;                 // glass only: lines seen through it, faint
    CAShapeLayer *layer;                 // the line drawing, on top
    CGPathRef unitPath;                  // cm, centred on the hull centroid
    CGPathRef unitHidden;                // glass only, same frame as unitPath
    CGPathRef unitFill;                  // solid silhouette, same frame
    uint32_t rgb;

    // Dither grid in the body's own frame: block (c, r) covers
    // [c, c+1) x [r, r+1) * blockSize points. Rows are stored top first.
    int c0, r0, cols, rows;
    uint32_t *pixels;                    // premultiplied BGRA, cols x rows
    int nWet;                            // blocks inside the silhouette:
    int *wetIndex;                       //   their pixel index,
    float *wetX, *wetY;                  //   centre in the body's frame (points),
    float *wetRank;                      //   and order they switch on (0-64)
    float *heights;                      // scratch: heights above the water's "down"

    // The water's surface tilt (radians from level, world frame) and its rate:
    // a damped spring back to level, kicked by collisions.
    CGFloat slosh, sloshRate;
    CGFloat kickVX;                      // horizontal velocity change since last frame
    CGPoint hullCM[ST_MAX_HULL];         // cm, centred on the hull centroid, CCW
    int hullN;
    CGFloat areaCM2;                     // hull area: the body's mass, in cm²
    CGFloat inertiaCM2;                  // I / m for the hull, cm²
    CGFloat rmaxCM;                      // farthest hull point from the centroid

    // Scaled to the current bounds.
    CGPoint hull[ST_MAX_HULL];           // points
    CGFloat invM, invI;
    CGFloat energy;                      // target energy per unit mass

    // State (points, radians).
    CGPoint pos, vel;
    CGFloat angle, spin;
} Body;

// Which Aalto pieces bounce, chosen in Options. Each group shares one scale, so
// pieces keep their real relative sizes; `reach` is how far the group's biggest
// piece extends from its centre, as a fraction of the screen's short side.
//
// Furniture is drawn in Aalto's colours: natural bent birch, the sunlit yellow
// of the Paimio Sanatorium floors, and the blue of the Finnish lakes. The glass
// takes iittala's Aalto colours: sea blue, moss green and clear.
typedef NS_ENUM(NSInteger, STObjects) { STObjectsStools, STObjectsTables, STObjectsVases, STObjectsCount };
static NSString *const kObjectNames[STObjectsCount] = { @"1 — Stools", @"2 — Tables + Tea Trolley", @"3 — Vases" };

static const struct { int n; STDesign design[ST_MAX_BODIES]; uint32_t rgb[ST_MAX_BODIES]; CGFloat reach; } kGroups[STObjectsCount] = {
    { 3, { STDesignStool60, STDesignStoolE60, STDesignBarStool64 },
         { 0xE2CDA2, 0xE3B23C, 0x6F9CBB }, 0.288 },
    { 3, { STDesignTableRound, STDesignTableRect, STDesignTeaTrolley900 },
         { 0xE2CDA2, 0xE3B23C, 0x6F9CBB }, 0.27 },
    { 3, { STDesignVase160, STDesignVase120, STDesignVase95 },
         { 0x4C93AE, 0x7F9157, 0xCFD8D8 }, 0.24 },
};

// Lines seen through glass are drawn at this opacity.
static const CGFloat kGhostAlpha = 0.3;

// The minute fill, matching the mono-fill saver's "Dither (surface)" style: each
// piece fills from its feet up over the minute, solid below a dithered water
// line, and is completely solid at :60. At the turn of the minute it drains: the
// fill played backwards, fast. Same timings, block size, Bayer order, per-block
// offsets and fade as mono-fill.
static const CGFloat kDrainSeconds = 0.5;    // full -> empty at the top of the minute
static const CGFloat kFillStart = 1.3;       // the new minute's fill starts here
static const CGFloat kSurfaceBand = 0.28;    // gradient band depth, fraction of height
static const CGFloat kDitherBlock = 3.0;     // block side at mono-fill's 1442 x 810 canvas
static const CGFloat kDitherFadeLevels = 0.35;

static const int kBayer8[8][8] = {
    { 0, 32, 8, 40, 2, 34, 10, 42 },   { 48, 16, 56, 24, 50, 18, 58, 26 },
    { 12, 44, 4, 36, 14, 46, 6, 38 },  { 60, 28, 52, 20, 62, 30, 54, 22 },
    { 3, 35, 11, 43, 1, 33, 9, 41 },   { 51, 19, 59, 27, 49, 17, 57, 25 },
    { 15, 47, 7, 39, 13, 45, 5, 37 },  { 63, 31, 55, 23, 61, 29, 53, 21 },
};

static inline uint32_t Hash3(int32_t a, int32_t b, int32_t c) {
    uint32_t h = (uint32_t)a * 0x8da6b343u ^ (uint32_t)b * 0xd8163841u ^ (uint32_t)c * 0xcb1ab31fu;
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return h;
}

// Order (0-64) in which block (c, r) switches on: its Bayer rank plus a fixed
// offset within the rank, so blocks of one rank trickle in instead of popping
// together.
static inline float DitherRank(int c, int r) {
    return kBayer8[r & 7][c & 7] + (Hash3(c, r, 91) & 0xffff) / 65536.0f;
}

static inline CGFloat Clamp01(CGFloat t) { return fmin(fmax(t, 0.0), 1.0); }
static inline CGFloat EaseInOut(CGFloat t) { t = Clamp01(t); return t * t * (3.0 - 2.0 * t); }

// 0-1 progress of the fill for `secs` into the minute: draining at the start,
// then filling from kFillStart to full at :60.
static CGFloat MinuteFill(CGFloat secs) {
    if (secs < kDrainSeconds) return 1.0 - EaseInOut(secs / kDrainSeconds);
    return Clamp01((secs - kFillStart) / (60.0 - kFillStart));
}

@interface STStoolView : ScreenSaverView
@end

@implementation STStoolView {
    CAShapeLayer *_quote, *_clock, *_play;
    STText _text;
    CFTimeInterval _lastSettingsCheck;
    NSWindow *_configWindow;
    NSPopUpButton *_textPopup, *_objectsPopup;
    STObjects _objects, _builtObjects;
    CTFontRef _font;
    CGFloat _margin, _leading;
    NSInteger _clockSecond;
    NSDateFormatter *_clockFormat;
    Body _b[ST_MAX_BODIES];
    int _count;
    CGFloat _scale;                      // points per cm, shared by the group
    CGFloat _g;                          // pt/s²
    CGFloat _lineWidth;
    CGFloat _blockSize;                  // dither block side, whole points
    CGSize _size;
    BOOL _placed;

    CFTimeInterval _lastTime;
    CADisplayLink *_displayLink API_AVAILABLE(macos(14.0));
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        self.animationTimeInterval = 1.0 / 60.0;

        CALayer *root = [CALayer layer];
        root.backgroundColor = CGColorCreateSRGB(0x1A / 255.0, 0x1A / 255.0, 0x1A / 255.0, 1);
        self.layer = root;
        self.wantsLayer = YES;

        RegisterFonts([NSBundle bundleForClass:[self class]]);
        [self reloadSettings];
        _clockSecond = -1;
        _play = [CAShapeLayer layer];
        _play.fillColor = CGColorCreateSRGB(0x26 / 255.0, 0x25 / 255.0, 0x23 / 255.0, 1);
        _play.actions = @{ @"path": [NSNull null], @"hidden": [NSNull null] };
        [root addSublayer:_play];
        CGColorRef ink = CGColorCreateSRGB(0xD8 / 255.0, 0xD3 / 255.0, 0xC6 / 255.0, 1);
        _quote = [CAShapeLayer layer];
        _clock = [CAShapeLayer layer];
        for (CAShapeLayer *l in @[ _quote, _clock ]) {
            l.fillColor = ink;
            l.actions = @{ @"path": [NSNull null], @"hidden": [NSNull null] };
            [root addSublayer:l];
        }
        CGColorRelease(ink);

        [self setupBodies];
    }
    return self;
}

- (void)dealloc {
    if (_font) CFRelease(_font);
    [self teardownBodies];
}

static CAShapeLayer *StrokeLayer(uint32_t rgb, CGFloat alpha) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = NULL;
    CGColorRef c = CGColorCreateSRGB(((rgb >> 16) & 0xFF) / 255.0, ((rgb >> 8) & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, alpha);
    l.strokeColor = c;
    CGColorRelease(c);
    l.lineCap = kCALineCapRound;
    l.lineJoin = kCALineJoinRound;
    l.actions = @{ @"position": [NSNull null], @"transform": [NSNull null],
                   @"path": [NSNull null], @"lineWidth": [NSNull null] };
    return l;
}

- (void)teardownBodies {
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        [b->node removeFromSuperlayer];
        CGPathRelease(b->unitPath);
        CGPathRelease(b->unitHidden);
        CGPathRelease(b->unitFill);
        free(b->pixels); free(b->wetIndex); free(b->wetX); free(b->wetY);
        free(b->wetRank); free(b->heights);
        *b = (Body){0};
    }
    _count = 0;
}

// (Re)build the bodies for the chosen group and drop them in afresh.
- (void)setupBodies {
    [self teardownBodies];
    _builtObjects = _objects;
    _count = kGroups[_objects].n;
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        [self buildBody:b design:kGroups[_objects].design[k]];
        uint32_t rgb = kGroups[_objects].rgb[k];
        b->rgb = rgb;
        // Sublayers of one node, so they move and turn together for free.
        b->node = [CALayer layer];
        b->node.actions = @{ @"position": [NSNull null], @"transform": [NSNull null] };
        b->fill = [CALayer layer];
        b->fill.magnificationFilter = kCAFilterNearest;   // crisp 1-bit blocks
        b->fill.actions = @{ @"contents": [NSNull null], @"frame": [NSNull null],
                             @"bounds": [NSNull null], @"position": [NSNull null] };
        [b->node addSublayer:b->fill];
        if (b->unitHidden) {
            b->ghost = StrokeLayer(rgb, kGhostAlpha);
            [b->node addSublayer:b->ghost];
        }
        b->layer = StrokeLayer(rgb, 1);
        [b->node addSublayer:b->layer];
        [self.layer addSublayer:b->node];
    }
    _placed = NO;
    _size = CGSizeZero;
    [self layoutStools];
}

- (void)buildBody:(Body *)b design:(STDesign)design {
    STStoolHull verts;
    CGPathRef hidden = NULL, solid = NULL;
    CGPathRef raw = STCreateDesignDrawingFull(design, &verts, &hidden, &solid);
    NSMutableArray<NSValue *> *pts = [NSMutableArray arrayWithCapacity:verts.count];
    for (int i = 0; i < verts.count; i++) [pts addObject:[NSValue valueWithPoint:verts.points[i]]];
    free(verts.points);
    NSArray<NSValue *> *hull = ConvexHull(pts);

    // Area centroid and polar moment of the hull (uniform density).
    CGFloat A = 0, cx = 0, cy = 0;
    NSUInteger n = hull.count;
    for (NSUInteger i = 0; i < n; i++) {
        CGPoint a = hull[i].pointValue, c = hull[(i + 1) % n].pointValue;
        CGFloat k = a.x * c.y - c.x * a.y;
        A += k; cx += (a.x + c.x) * k; cy += (a.y + c.y) * k;
    }
    A *= 0.5; cx /= 6 * A; cy /= 6 * A;

    CGFloat J = 0;
    b->hullN = (int)MIN(n, ST_MAX_HULL);
    b->rmaxCM = 0;
    for (int i = 0; i < b->hullN; i++) {
        CGPoint p = hull[i].pointValue;
        b->hullCM[i] = CGPointMake(p.x - cx, p.y - cy);
        b->rmaxCM = fmax(b->rmaxCM, hypot(b->hullCM[i].x, b->hullCM[i].y));
    }
    for (int i = 0; i < b->hullN; i++) {
        CGPoint a = b->hullCM[i], c = b->hullCM[(i + 1) % b->hullN];
        CGFloat k = a.x * c.y - c.x * a.y;
        J += k * (a.x * a.x + a.x * c.x + c.x * c.x + a.y * a.y + a.y * c.y + c.y * c.y);
    }
    b->areaCM2 = A;
    b->inertiaCM2 = (J / 12.0) / A;

    CGAffineTransform t = CGAffineTransformMakeTranslation(-cx, -cy);
    b->unitPath = CGPathCreateCopyByTransformingPath(raw, &t);
    CGPathRelease(raw);
    if (hidden) {
        b->unitHidden = CGPathCreateCopyByTransformingPath(hidden, &t);
        CGPathRelease(hidden);
    }
    b->unitFill = CGPathCreateCopyByTransformingPath(solid, &t);
    CGPathRelease(solid);
}

// Rasterise the silhouette onto the dither grid at the current scale: one
// pixel per block, a block holding water if the silhouette covers at least half
// of it.
- (void)layoutFill:(Body *)b blockSize:(CGFloat)px {
    free(b->pixels); free(b->wetIndex); free(b->wetX); free(b->wetY);
    free(b->wetRank); free(b->heights);
    CGAffineTransform t = CGAffineTransformMakeScale(_scale, _scale);
    CGPathRef shape = CGPathCreateCopyByTransformingPath(b->unitFill, &t);
    CGRect box = CGPathGetPathBoundingBox(shape);
    b->c0 = (int)floor(CGRectGetMinX(box) / px);
    b->r0 = (int)floor(CGRectGetMinY(box) / px);
    b->cols = (int)ceil(CGRectGetMaxX(box) / px) - b->c0;
    b->rows = (int)ceil(CGRectGetMaxY(box) / px) - b->r0;

    int n = b->cols * b->rows;
    uint8_t *mask = calloc(n, 1);
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(mask, b->cols, b->rows, 8, b->cols, gray, kCGImageAlphaNone);
    CGColorSpaceRelease(gray);
    CGContextScaleCTM(ctx, 1 / px, 1 / px);
    CGContextTranslateCTM(ctx, -b->c0 * px, -b->r0 * px);
    CGContextAddPath(ctx, shape);
    CGContextSetGrayFillColor(ctx, 1, 1);
    CGContextFillPath(ctx);
    CGContextRelease(ctx);
    CGPathRelease(shape);

    int wet = 0;
    for (int i = 0; i < n; i++) wet += mask[i] >= 128;
    b->nWet = wet;
    b->pixels = calloc(n, sizeof(uint32_t));
    b->wetIndex = malloc(sizeof(int) * wet);
    b->wetX = malloc(sizeof(float) * wet);
    b->wetY = malloc(sizeof(float) * wet);
    b->wetRank = malloc(sizeof(float) * wet);
    b->heights = malloc(sizeof(float) * wet);
    int k = 0;
    for (int m = 0; m < b->rows; m++) {         // memory rows run top first
        int r = b->r0 + b->rows - 1 - m;
        for (int c = 0; c < b->cols; c++) {
            int i = m * b->cols + c;
            if (mask[i] < 128) continue;
            b->wetIndex[k] = i;
            b->wetX[k] = (b->c0 + c + 0.5) * px;
            b->wetY[k] = (r + 0.5) * px;
            b->wetRank[k] = DitherRank(b->c0 + c, r);
            k++;
        }
    }
    free(mask);
    b->fill.frame = CGRectMake(b->c0 * px, b->r0 * px, b->cols * px, b->rows * px);
    b->fill.contents = nil;
}

// k-th smallest of v[0..n) (quickselect; reorders v).
static float SelectKth(float *v, int n, int k) {
    int lo = 0, hi = n - 1;
    while (lo < hi) {
        float pivot = v[(lo + hi) / 2];
        int i = lo, j = hi;
        while (i <= j) {
            while (v[i] < pivot) i++;
            while (v[j] > pivot) j--;
            if (i <= j) { float t = v[i]; v[i] = v[j]; v[j] = t; i++; j--; }
        }
        if (k <= j) hi = j; else if (k >= i) lo = i; else return v[k];
    }
    return v[k];
}

// The slosh: a damped spring (~1.1 Hz) pulling the surface back to level,
// kicked by each collision's sideways jolt (the water lags behind the jolt).
static const CGFloat kSloshHz = 1.1, kSloshDamping = 0.14, kSloshMax = 0.45;

- (void)stepSlosh:(CGFloat)dt {
    CGFloat w = 2 * M_PI * kSloshHz, kick = 1.0 / (0.15 * MIN(_size.width, _size.height));
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        b->sloshRate -= b->kickVX * kick;
        b->kickVX = 0;
        b->sloshRate += (-w * w * b->slosh - 2 * kSloshDamping * w * b->sloshRate) * dt;
        b->slosh = fmax(-kSloshMax, fmin(kSloshMax, b->slosh + b->sloshRate * dt));
    }
}

// Each piece holds water: the minute's share of its silhouette, settled to
// whichever side is down right now, with a level (or sloshing) surface. The
// surface is mono-fill's dithered band; the blocks stay locked to the piece's
// own grid, so the waterline steps across them as it turns.
- (void)updateFills {
    CGFloat secs = fmod([NSDate date].timeIntervalSinceReferenceDate, 60.0);
    if (getenv("ST_SECONDS")) secs = atof(getenv("ST_SECONDS"));   // previews/tests
    CGFloat f = MinuteFill(secs), f4 = pow(f, 4);
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        if (!b->nWet) continue;
        // Height of each block above the water's "down", in points: the world's
        // up direction tilted by the slosh, expressed in the body's frame.
        CGFloat ux = -sin(b->slosh), uy = cos(b->slosh);
        CGFloat c = cos(b->angle), s = sin(b->angle);
        float ax = ux * c + uy * s, ay = -ux * s + uy * c;
        float hmin = INFINITY, hmax = -INFINITY;
        for (int i = 0; i < b->nWet; i++) {
            float h = ax * b->wetX[i] + ay * b->wetY[i];
            b->heights[i] = h;
            hmin = fminf(hmin, h); hmax = fmaxf(hmax, h);
        }
        // The level that holds this minute's share of the silhouette.
        int want = (int)floor(f * b->nWet);
        float level = want <= 0 ? hmin - 1 : want >= b->nWet ? hmax + 1
                    : SelectKth(b->heights, b->nWet, want);
        CGFloat band = (hmax - hmin) * kSurfaceBand;

        uint32_t rgb = b->rgb;
        CGFloat R = (rgb >> 16) & 0xFF, G = (rgb >> 8) & 0xFF, B = rgb & 0xFF;
        memset(b->pixels, 0, sizeof(uint32_t) * b->cols * b->rows);
        if (f > 0) {
            for (int i = 0; i < b->nWet; i++) {
                float h = ax * b->wetX[i] + ay * b->wetY[i];
                if (h > level) continue;
                CGFloat d = Clamp01((level - h) / band + f4);
                CGFloat a = Clamp01((d * (64.0 + kDitherFadeLevels) - b->wetRank[i]) / kDitherFadeLevels);
                if (a <= 0) continue;
                uint32_t A = (uint32_t)lround(a * 255);
                b->pixels[b->wetIndex[i]] = (A << 24) | ((uint32_t)lround(R * a) << 16)
                                          | ((uint32_t)lround(G * a) << 8) | (uint32_t)lround(B * a);
            }
        }
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(b->pixels, b->cols, b->rows, 8, b->cols * 4, cs,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        b->fill.contents = (__bridge id)img;
        [CATransaction commit];
        CGImageRelease(img);
    }
}

// One scale for the whole group: its biggest piece reaches the group's `reach`
// of the short side from its centre, leaving room for all to drift and tumble.
- (void)layoutStools {
    NSSize sz = self.bounds.size;
    if (sz.width < 1 || sz.height < 1) return;
    if (_placed && CGSizeEqualToSize(sz, _size)) return;
    _size = sz;
    CGFloat shortSide = MIN(sz.width, sz.height);

    [self layoutType];

    CGFloat rmax = 0, area0 = _b[0].areaCM2;
    for (int k = 0; k < _count; k++) rmax = fmax(rmax, _b[k].rmaxCM);
    _scale = kGroups[_builtObjects].reach * shortSide / rmax;
    _lineWidth = fmax(0.75, shortSide * 0.0016);
    _blockSize = fmax(2.0, round(kDitherBlock * fmin(sz.width / 1442.0, sz.height / 810.0)));
    // Low, moon-like gravity: a fall from top to floor takes ~2.6s.
    _g = 0.3 * sz.height;

    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        for (int i = 0; i < b->hullN; i++)
            b->hull[i] = CGPointMake(b->hullCM[i].x * _scale, b->hullCM[i].y * _scale);
        CGFloat mass = b->areaCM2 / area0;      // relative to the group's first piece
        b->invM = 1 / mass;
        b->invI = 1 / (mass * b->inertiaCM2 * _scale * _scale);

        CGAffineTransform t = CGAffineTransformMakeScale(_scale, _scale);
        CGPathRef p = CGPathCreateCopyByTransformingPath(b->unitPath, &t);
        b->layer.path = p;
        CGPathRelease(p);
        b->layer.lineWidth = _lineWidth;
        if (b->ghost) {
            CGPathRef gp = CGPathCreateCopyByTransformingPath(b->unitHidden, &t);
            b->ghost.path = gp;
            CGPathRelease(gp);
            b->ghost.lineWidth = _lineWidth;
        }
        [self layoutFill:b blockSize:_blockSize];

        CGFloat r = b->rmaxCM * _scale;
        if (!_placed) {
            // Spread across the width, each starting a little differently.
            CGFloat sign = k % 2 ? -1 : 1;
            b->pos = CGPointMake(sz.width * (k + 0.5) / _count, sz.height - r - 0.02 * sz.height * k);
            b->vel = CGPointMake(sz.width * 0.12 * sign, sz.height * 0.04 * (k - 1));
            b->angle = 0.35 - 0.3 * k;
            b->spin = 0.5 * sign;
        }
        // Keep the bounce height: enough energy to throw the centroid ~ to the top.
        b->energy = _g * (sz.height - 1.05 * r) + 0.5 * pow(sz.width * 0.12, 2);
    }
    _placed = YES;
    [self resolveContacts];
    [self applyTransforms];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutStools];
}

#pragma mark Type

// Type size, margin and leading all follow the short side, so the poster keeps
// its proportions on any screen. The quote's cap height hangs from the top
// margin; the last clock's baseline sits on the bottom margin.
- (void)layoutType {
    CGFloat shortSide = MIN(_size.width, _size.height);
    if (_font) CFRelease(_font);
    _font = CTFontCreateWithName((__bridge CFStringRef)TypeFontName(), fmax(7, shortSide * 0.016), NULL);
    _margin = shortSide * 0.045;
    _leading = CTFontGetSize(_font) * 1.3;

    BOOL poster = _text == STTextPoster;
    _quote.hidden = _clock.hidden = !poster;
    _play.hidden = poster;
    if (!poster) { [self layoutPlay]; return; }

    // Aalto's words, with the English directly beneath on the next line.
    CGMutablePathRef q = CGPathCreateMutable();
    CGFloat quoteBase = _size.height - _margin - CTFontGetCapHeight(_font);
    AddText(q, @"Ettehän unohda leikkiä", _font, _margin, quoteBase);
    AddText(q, @"Don\u2019t forget to play", _font, _margin, quoteBase - _leading);
    _quote.path = q;
    CGPathRelease(q);

    _clockSecond = -1;
    [self updateClock];
}

// Lowercase "play" in Futura Medium, set from the user's Illustrator mockup:
// each gap between letters is matched to the mockup's measured ink gaps (−20
// tracking plus their hand kerning), as a fraction of the 'l' height.
static const CGFloat kPlayGaps[3] = { 23.0 / 415, 22.0 / 415, 24.0 / 415 };   // p|l, l|a, a|y

// Optical centring: the word is placed between centring its bounding box and
// centring its ink's centre of mass. Vertically the box sits too low (the tall
// 'l' lifts it while the eye reads the x-height band), so the mass gets half
// the say. Horizontally the box is nearly right; the y's open diagonal only
// earns it a small nudge.
static CGFloat OpticalWeightX(void) { return getenv("ST_OPX") ? atof(getenv("ST_OPX")) : 0.2; }
static CGFloat OpticalWeightY(void) { return getenv("ST_OPY") ? atof(getenv("ST_OPY")) : 0.5; }

static CGPoint InkCentroid(CGPathRef path, CGRect ink) {
    const int W = 400;
    int H = MAX(1, (int)ceil(W * ink.size.height / ink.size.width));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, W, cs, kCGImageAlphaNone);
    CGColorSpaceRelease(cs);
    CGFloat k = W / ink.size.width;
    CGContextScaleCTM(ctx, k, k);
    CGContextTranslateCTM(ctx, -ink.origin.x, -ink.origin.y);
    CGContextAddPath(ctx, path);
    CGContextSetGrayFillColor(ctx, 1, 1);
    CGContextFillPath(ctx);
    const uint8_t *px = CGBitmapContextGetData(ctx);
    double sum = 0, sx = 0, sy = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            double v = px[y * W + x];
            sum += v; sx += v * (x + 0.5); sy += v * (H - y - 0.5);   // rows run top-down
        }
    CGContextRelease(ctx);
    if (sum == 0) return CGPointMake(CGRectGetMidX(ink), CGRectGetMidY(ink));
    return CGPointMake(ink.origin.x + sx / sum / k, ink.origin.y + sy / sum / k);
}

- (void)layoutPlay {
    CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)kPlayFont, 100, NULL);
    UniChar chars[4] = { 'p', 'l', 'a', 'y' };
    CGGlyph glyphs[4];
    CTFontGetGlyphsForCharacters(font, chars, glyphs, 4);

    CGPathRef gp[4];
    CGRect gb[4];
    for (int i = 0; i < 4; i++) {
        gp[i] = CTFontCreatePathForGlyph(font, glyphs[i], NULL);
        gb[i] = CGPathGetPathBoundingBox(gp[i]);
    }
    CFRelease(font);
    CGFloat unit = gb[1].size.height;   // the 'l': baseline to ascender

    CGMutablePathRef word = CGPathCreateMutable();
    CGFloat right = 0;
    for (int i = 0; i < 4; i++) {
        CGFloat left = i == 0 ? 0 : right + kPlayGaps[i - 1] * unit;
        CGAffineTransform t = CGAffineTransformMakeTranslation(left - CGRectGetMinX(gb[i]), 0);
        CGPathAddPath(word, &t, gp[i]);
        right = left + gb[i].size.width;
        CGPathRelease(gp[i]);
    }

    CGRect ink = CGPathGetPathBoundingBox(word);
    CGPoint mass = InkCentroid(word, ink);
    CGPoint centre = CGPointMake(CGRectGetMidX(ink) + (mass.x - CGRectGetMidX(ink)) * OpticalWeightX(),
                                 CGRectGetMidY(ink) + (mass.y - CGRectGetMidY(ink)) * OpticalWeightY());
    // As large as possible with the optical centre on the screen's centre and
    // every side of the ink still inside the margin.
    CGFloat hw = _size.width / 2 - _margin, hh = _size.height / 2 - _margin;
    CGFloat s = fmin(fmin(hw / (centre.x - CGRectGetMinX(ink)), hw / (CGRectGetMaxX(ink) - centre.x)),
                     fmin(hh / (centre.y - CGRectGetMinY(ink)), hh / (CGRectGetMaxY(ink) - centre.y)));
    CGAffineTransform t = CGAffineTransformMakeTranslation(_size.width / 2 - centre.x * s, _size.height / 2 - centre.y * s);
    t = CGAffineTransformScale(t, s, s);
    CGPathRef placed = CGPathCreateCopyByTransformingPath(word, &t);
    _play.path = placed;
    CGPathRelease(placed);
    CGPathRelease(word);
}

#pragma mark Settings

- (void)reloadSettings {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfURL:SettingsFileURL()];
    NSInteger t = [d[@"Text"] integerValue], o = [d[@"Objects"] integerValue];
    if (getenv("ST_TEXT")) t = atoi(getenv("ST_TEXT")) - 1;         // preview/testing: 1-based
    if (getenv("ST_OBJECTS")) o = atoi(getenv("ST_OBJECTS")) - 1;
    _text = (t >= 0 && t < STTextCount) ? (STText)t : STTextPoster;
    _objects = (o >= 0 && o < STObjectsCount) ? (STObjects)o : STObjectsStools;
}

// The Options sheet may live on a different view instance or process than the
// one rendering, so the renderer re-reads the file once a second.
- (void)pollSettings:(CFTimeInterval)now {
    if (now - _lastSettingsCheck < 1.0) return;
    _lastSettingsCheck = now;
    STText before = _text;
    [self reloadSettings];
    if (_text != before) [self layoutType];
    if (_objects != _builtObjects) [self setupBodies];
}

- (BOOL)hasConfigureSheet { return YES; }

- (NSWindow *)configureSheet {
    if (!_configWindow) {
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 360, 160)
                                                    styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.title = @"Leikki Options";
        NSView *content = win.contentView;
        NSTextField *ol = [NSTextField labelWithString:@"Objects:"];
        ol.frame = NSMakeRect(20, 115, 80, 20);
        [content addSubview:ol];
        _objectsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(102, 110, 238, 28) pullsDown:NO];
        for (NSInteger i = 0; i < STObjectsCount; i++) [_objectsPopup addItemWithTitle:kObjectNames[i]];
        [content addSubview:_objectsPopup];

        NSTextField *l = [NSTextField labelWithString:@"Text:"];
        l.frame = NSMakeRect(20, 79, 80, 20);
        [content addSubview:l];
        _textPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(102, 74, 238, 28) pullsDown:NO];
        for (NSInteger i = 0; i < STTextCount; i++) [_textPopup addItemWithTitle:kTextNames[i]];
        [content addSubview:_textPopup];

        NSDictionary *info = [NSBundle bundleForClass:[self class]].infoDictionary;
        NSTextField *ver = [NSTextField labelWithString:[NSString stringWithFormat:@"Leikki %@ (%@)",
                                                         info[@"CFBundleShortVersionString"], info[@"CFBundleVersion"]]];
        ver.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
        ver.textColor = NSColor.secondaryLabelColor;
        ver.frame = NSMakeRect(20, 22, 140, 16);
        [content addSubview:ver];

        NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(configCancel:)];
        cancel.frame = NSMakeRect(170, 16, 82, 30);
        cancel.keyEquivalent = @"\033";
        [content addSubview:cancel];
        NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(configOK:)];
        ok.frame = NSMakeRect(258, 16, 82, 30);
        ok.keyEquivalent = @"\r";
        [content addSubview:ok];
        _configWindow = win;
    }
    [self reloadSettings];
    [_textPopup selectItemAtIndex:_text];
    [_objectsPopup selectItemAtIndex:_objects];
    return _configWindow;
}

- (void)configOK:(id)sender {
    _text = (STText)_textPopup.indexOfSelectedItem;
    _objects = (STObjects)_objectsPopup.indexOfSelectedItem;
    [@{ @"Text" : @(_text), @"Objects" : @(_objects) } writeToURL:SettingsFileURL() error:nil];
    [self layoutType];
    if (_objects != _builtObjects) [self setupBodies];
    [[NSApplication sharedApplication] endSheet:_configWindow returnCode:NSModalResponseOK];
}

- (void)configCancel:(id)sender {
    [[NSApplication sharedApplication] endSheet:_configWindow returnCode:NSModalResponseCancel];
}

- (void)updateClock {
    if (_text != STTextPoster) return;
    // Re-pathed once a second, on the first frame after the second turns over.
    NSDate *now = [NSDate date];
    NSInteger second = (NSInteger)floor(now.timeIntervalSinceReferenceDate);
    if (second == _clockSecond || !_font) return;
    _clockSecond = second;

    // Cities in one column, times in a second column one em past the longest name.
    CGFloat col = 0;
    for (size_t i = 0; i < ST_CLOCKS; i++)
        col = fmax(col, TextWidth([NSString stringWithUTF8String:kClocks[i].city], _font));
    col += CTFontGetSize(_font) * 1.0;

    if (!_clockFormat) {
        _clockFormat = [[NSDateFormatter alloc] init];
        _clockFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _clockFormat.dateFormat = @"HH:mm:ss";   // tabular figures, so nothing shifts as it ticks
    }
    NSDateFormatter *fmt = _clockFormat;
    CGMutablePathRef p = CGPathCreateMutable();
    for (size_t i = 0; i < ST_CLOCKS; i++) {
        CGFloat y = _margin + (ST_CLOCKS - 1 - i) * _leading;
        fmt.timeZone = [NSTimeZone timeZoneWithName:[NSString stringWithUTF8String:kClocks[i].zone]];
        AddText(p, [NSString stringWithUTF8String:kClocks[i].city], _font, _margin, y);
        AddText(p, [fmt stringFromDate:now], _font, _margin + col, y);
    }
    _clock.path = p;
    CGPathRelease(p);
}

#pragma mark Physics

static const CGFloat kRestitution = 0.92;
static const CGFloat kFriction    = 0.25;
static const CGFloat kMaxSpin     = 1.4;   // rad/s
static const double  kStep        = 1.0 / 480.0;

static CGPoint Rot(CGPoint p, CGFloat c, CGFloat s) { return CGPointMake(c * p.x - s * p.y, s * p.x + c * p.y); }

// Velocity of the body's material at offset r from its centre.
static CGPoint PointVel(Body *b, CGPoint r) { return CGPointMake(b->vel.x - b->spin * r.y, b->vel.y + b->spin * r.x); }

static void ApplyImpulse(Body *b, CGPoint r, CGPoint P) {
    b->kickVX += P.x * b->invM;       // the water feels the sideways jolt
    b->vel.x += P.x * b->invM;
    b->vel.y += P.y * b->invM;
    b->spin += (r.x * P.y - r.y * P.x) * b->invI;
}

// Contact impulse between two bodies (b may be NULL for a static wall) at a
// point with offsets ra/rb, normal n pointing from a to b: restitution along the
// normal, Coulomb friction along the surface (which turns glancing hits into
// spin and vice versa).
static void Collide(Body *a, Body *b, CGPoint ra, CGPoint rb, CGPoint n) {
    CGPoint va = PointVel(a, ra), vb = b ? PointVel(b, rb) : CGPointZero;
    CGPoint v = CGPointMake(vb.x - va.x, vb.y - va.y);
    CGFloat vn = v.x * n.x + v.y * n.y;
    if (vn >= 0) return;

    CGFloat ran = ra.x * n.y - ra.y * n.x, rbn = rb.x * n.y - rb.y * n.x;
    CGFloat kn = a->invM + ran * ran * a->invI + (b ? b->invM + rbn * rbn * b->invI : 0);
    CGFloat jn = -(1 + kRestitution) * vn / kn;

    CGPoint t = CGPointMake(-n.y, n.x);
    CGFloat vt = v.x * t.x + v.y * t.y;
    CGFloat rat = ra.x * t.y - ra.y * t.x, rbt = rb.x * t.y - rb.y * t.x;
    CGFloat kt = a->invM + rat * rat * a->invI + (b ? b->invM + rbt * rbt * b->invI : 0);
    CGFloat jt = fmax(-kFriction * jn, fmin(kFriction * jn, -vt / kt));

    CGPoint P = CGPointMake(n.x * jn + t.x * jt, n.y * jn + t.y * jt);
    ApplyImpulse(a, ra, CGPointMake(-P.x, -P.y));
    if (b) ApplyImpulse(b, rb, P);
}

- (void)step:(CGFloat)dt {
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        b->vel.y -= _g * dt;
        b->pos.x += b->vel.x * dt;
        b->pos.y += b->vel.y * dt;
        b->angle += b->spin * dt;
    }
    [self resolveContacts];
}

- (void)resolveContacts {
    for (int iter = 0; iter < 3; iter++) {
        for (int i = 0; i < _count; i++)
            for (int j = i + 1; j < _count; j++) [self collide:&_b[i] with:&_b[j]];
        for (int k = 0; k < _count; k++) [self collideWalls:&_b[k]];
    }
}

// For each screen edge, push out the deepest hull vertex and bounce off it.
- (void)collideWalls:(Body *)b {
    CGFloat c = cos(b->angle), s = sin(b->angle);
    CGFloat inset = _lineWidth * 0.5 + 1;
    const CGPoint normals[4] = { {1, 0}, {-1, 0}, {0, 1}, {0, -1} };
    const CGFloat offsets[4] = { inset, -(_size.width - inset), inset, -(_size.height - inset) };
    for (int w = 0; w < 4; w++) {
        CGPoint n = normals[w];
        int best = -1;
        CGFloat bestD = 0;
        CGPoint bestR = CGPointZero;
        for (int i = 0; i < b->hullN; i++) {
            CGPoint r = Rot(b->hull[i], c, s);
            CGFloat d = n.x * (b->pos.x + r.x) + n.y * (b->pos.y + r.y) - offsets[w];
            if (d < bestD) { bestD = d; best = i; bestR = r; }
        }
        if (best < 0) continue;
        b->pos.x -= n.x * bestD;
        b->pos.y -= n.y * bestD;
        // The wall pushes the body along n; as "a" the body sees the wall's normal reversed.
        Collide(b, NULL, bestR, CGPointZero, CGPointMake(-n.x, -n.y));
    }
}

// Least-penetration axis over both hulls' edges (separating axis theorem). If
// the hulls overlap, the deepest vertex along that axis is the contact point.
static CGFloat DeepestAxis(const CGPoint *A, int na, const CGPoint *B, int nb, CGPoint *nOut, CGPoint *pOut) {
    CGFloat best = -INFINITY;
    for (int i = 0; i < na; i++) {
        CGPoint a0 = A[i], a1 = A[(i + 1) % na];
        CGFloat ex = a1.x - a0.x, ey = a1.y - a0.y, el = hypot(ex, ey);
        if (el < 1e-9) continue;
        CGPoint n = CGPointMake(ey / el, -ex / el);     // outward for a CCW hull
        CGFloat minS = INFINITY;
        CGPoint deepest = CGPointZero;
        for (int j = 0; j < nb; j++) {
            CGFloat sep = n.x * (B[j].x - a0.x) + n.y * (B[j].y - a0.y);
            if (sep < minS) { minS = sep; deepest = B[j]; }
        }
        if (minS > best) { best = minS; *nOut = n; *pOut = deepest; }
        if (best > 0) return best;                       // separated: done
    }
    return best;
}

- (void)collide:(Body *)a with:(Body *)b {
    CGFloat dx = b->pos.x - a->pos.x, dy = b->pos.y - a->pos.y;
    CGFloat reach = (a->rmaxCM + b->rmaxCM) * _scale + _lineWidth;
    if (dx * dx + dy * dy > reach * reach) return;

    CGPoint WA[ST_MAX_HULL], WB[ST_MAX_HULL];
    CGFloat ca = cos(a->angle), sa = sin(a->angle), cb = cos(b->angle), sb = sin(b->angle);
    for (int i = 0; i < a->hullN; i++) { CGPoint r = Rot(a->hull[i], ca, sa); WA[i] = CGPointMake(a->pos.x + r.x, a->pos.y + r.y); }
    for (int i = 0; i < b->hullN; i++) { CGPoint r = Rot(b->hull[i], cb, sb); WB[i] = CGPointMake(b->pos.x + r.x, b->pos.y + r.y); }

    // Leave a stroke's width between them so the lines themselves never cross.
    CGFloat gap = _lineWidth;
    CGPoint nA, pA, nB, pB;
    CGFloat sA = DeepestAxis(WA, a->hullN, WB, b->hullN, &nA, &pA) - gap;
    if (sA >= 0) return;
    CGFloat sB = DeepestAxis(WB, b->hullN, WA, a->hullN, &nB, &pB) - gap;
    if (sB >= 0) return;

    CGPoint n, p;      // n points from a to b
    CGFloat depth;
    if (sA > sB) { n = nA; p = pA; depth = -sA; }
    else { n = CGPointMake(-nB.x, -nB.y); p = pB; depth = -sB; }

    CGFloat share = a->invM + b->invM;
    a->pos.x -= n.x * depth * a->invM / share; a->pos.y -= n.y * depth * a->invM / share;
    b->pos.x += n.x * depth * b->invM / share; b->pos.y += n.y * depth * b->invM / share;

    CGPoint ra = CGPointMake(p.x - a->pos.x, p.y - a->pos.y), rb = CGPointMake(p.x - b->pos.x, p.y - b->pos.y);
    Collide(a, b, ra, rb, n);
}

// Collisions bleed energy; a gentle governor tops each stool back up so they
// keep bouncing forever instead of coming to rest on the floor.
- (void)govern:(CGFloat)dt {
    for (int k = 0; k < _count; k++) {
        Body *b = &_b[k];
        CGFloat I = 1 / (b->invI * (1 / b->invM));   // I per unit mass
        CGFloat ke = 0.5 * (b->vel.x * b->vel.x + b->vel.y * b->vel.y) + 0.5 * I * b->spin * b->spin;
        CGFloat want = b->energy - _g * b->pos.y;
        if (ke > 1e-3 && want > 0) {
            CGFloat f = sqrt(want / ke);
            f = 1 + (f - 1) * fmin(1, dt * 0.6);
            b->vel.x *= f; b->vel.y *= f; b->spin *= f;
        }
        if (fabs(b->spin) > kMaxSpin) b->spin -= (b->spin - copysign(kMaxSpin, b->spin)) * fmin(1, dt * 2);
        // Never settle into a dead-vertical bounce.
        CGFloat minVX = _size.width * 0.05;
        if (fabs(b->vel.x) < minVX) b->vel.x += copysign(minVX, b->vel.x ?: 1) * dt;
    }
}

- (void)advanceTo:(CFTimeInterval)now {
    if (_lastTime == 0) _lastTime = now;
    double dt = fmin(now - _lastTime, 0.1);
    _lastTime = now;
    int steps = (int)ceil(dt / kStep);
    for (int i = 0; i < steps; i++) [self step:dt / steps];
    [self govern:dt];
    [self stepSlosh:dt];
    [self applyTransforms];
    [self updateFills];
    [self pollSettings:now];
    [self updateClock];
}

- (void)applyTransforms {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int k = 0; k < _count; k++) {
        _b[k].node.position = _b[k].pos;
        _b[k].node.affineTransform = CGAffineTransformMakeRotation(_b[k].angle);
    }
    [CATransaction commit];
}

#pragma mark Animation

- (BOOL)wantsDisplayLink {
    if (@available(macOS 14.0, *)) return [self respondsToSelector:@selector(displayLinkWithTarget:selector:)];
    return NO;
}

- (void)startAnimation {
    BOOL link = [self wantsDisplayLink];
    self.animationTimeInterval = link ? 1.0 : 1.0 / 60.0;
    [super startAnimation];
    _lastTime = 0;
    if (link) {
        if (@available(macOS 14.0, *)) {
            _displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
            _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
            [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        }
    }
}

- (void)stopAnimation {
    if (@available(macOS 14.0, *)) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    [super stopAnimation];
}

- (void)displayLinkFired:(CADisplayLink *)link API_AVAILABLE(macos(14.0)) {
    [self advanceTo:link.targetTimestamp];
}

- (void)animateOneFrame {
    if (@available(macOS 14.0, *)) { if (_displayLink) return; }
    [self advanceTo:CACurrentMediaTime()];
}


@end
