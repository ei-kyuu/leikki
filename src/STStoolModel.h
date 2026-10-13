#import <CoreGraphics/CoreGraphics.h>

// Every projected mesh vertex (cm); the caller takes the convex hull. Caller frees `points`.
typedef struct { CGPoint *points; int count; } STStoolHull;

typedef enum {
    STDesignStool60,
    STDesignStoolE60,
    STDesignBarStool64,
    STDesignChair69,
    STDesignPaimio41,
    STDesignGoldenBell,
    STDesignBeehive,
    STDesignSavoyVase,        // the opaque fluted study from the first sheet
    STDesignTableRound,
    STDesignTableRect,
    STDesignTeaTrolley900,
    STDesignVase160,
    STDesignVase120,
    STDesignVase95,
    STDesignCount
} STDesign;

const char *STDesignName(STDesign d);

// A design as a hidden-line drawing in screen-plane centimetres (y up).
CGPathRef STCreateDesignDrawing(STDesign d, STStoolHull *hullOut);

// As above; for glass designs, also the lines seen through the glass (hidden
// behind its front surfaces), for drawing faintly. *hiddenOut is NULL for
// opaque designs.
CGPathRef STCreateDesignDrawingEx(STDesign d, STStoolHull *hullOut, CGPathRef *hiddenOut);

// As above, plus the solid silhouette (every face turned toward the viewer, as
// one nonzero-fill path) for filling the object in.
CGPathRef STCreateDesignDrawingFull(STDesign d, STStoolHull *hullOut, CGPathRef *hiddenOut, CGPathRef *fillOut);

// The Stool 60, as used by the saver.
CGPathRef STCreateStoolDrawing(STStoolHull *hullOut);
