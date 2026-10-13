// Small 3D models of Alvar Aalto designs, drawn as hidden-line illustrations.
//
// Each design is built as a polygon mesh in centimetres from a few primitives:
// lathes (seats, lamps, rings), bent-wood sweeps (L-legs, loops, scrolls),
// layered slabs (rounded seats, the vase) and boxes. It is viewed
// orthographically as a level elevation. Every mesh edge that is a crease or a
// silhouette is a candidate line, plus a few "marks" drawn on surfaces for
// legibility; a depth buffer of the whole mesh decides which parts of each line
// are visible. The result is a single-weight line drawing with real occlusion.
#import <Foundation/Foundation.h>
#import "STStoolModel.h"
#import "STAaltoVasePlan.h"
#include <math.h>
#include <stdlib.h>

typedef struct { double x, y, z; } V3;
static V3 v3(double x, double y, double z) { return (V3){ x, y, z }; }
static V3 add(V3 a, V3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
static V3 sub(V3 a, V3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
static V3 mul(V3 a, double s) { return v3(a.x * s, a.y * s, a.z * s); }
static double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V3 cross(V3 a, V3 b) { return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
static V3 norm(V3 a) { double l = sqrt(dot(a, a)); return l > 0 ? mul(a, 1 / l) : a; }

static const V3 kX = { 1, 0, 0 }, kY = { 0, 1, 0 }, kZ = { 0, 0, 1 };

#pragma mark Mesh

typedef struct { int v[4]; int n; V3 normal; } Face;

typedef struct {
    V3 *verts; int nv, cv;
    Face *faces; int nf, cf;
    int *marks; int nm, cm;   // extra drawn lines that aren't mesh edges, as vertex pairs
    double elevation;         // camera elevation, degrees (0 = level)
    BOOL glass;               // see-through: hidden lines are kept, to draw faintly
} Mesh;

static int addVert(Mesh *m, V3 p) {
    if (m->nv == m->cv) { m->cv = m->cv ? m->cv * 2 : 256; m->verts = realloc(m->verts, sizeof(V3) * m->cv); }
    m->verts[m->nv] = p;
    return m->nv++;
}

// `inside` is any point inside the solid near this face; the normal is flipped
// to point away from it, which keeps every face outward-facing.
static void addFace(Mesh *m, int a, int b, int c, int d, V3 inside) {
    if (m->nf == m->cf) { m->cf = m->cf ? m->cf * 2 : 256; m->faces = realloc(m->faces, sizeof(Face) * m->cf); }
    Face f = { { a, b, c, d }, d < 0 ? 3 : 4, {0, 0, 0} };
    V3 nrm = v3(0, 0, 0), ctr = v3(0, 0, 0);
    for (int i = 0; i < f.n; i++) {   // Newell's method
        V3 p = m->verts[f.v[i]], q = m->verts[f.v[(i + 1) % f.n]];
        nrm.x += (p.y - q.y) * (p.z + q.z);
        nrm.y += (p.z - q.z) * (p.x + q.x);
        nrm.z += (p.x - q.x) * (p.y + q.y);
        ctr = add(ctr, p);
    }
    nrm = norm(nrm);
    ctr = mul(ctr, 1.0 / f.n);
    if (dot(nrm, sub(ctr, inside)) < 0) nrm = mul(nrm, -1);
    f.normal = nrm;
    m->faces[m->nf++] = f;
}

static V3 faceCenter(Mesh *m, int a, int b, int c, int d) {
    V3 s = add(add(m->verts[a], m->verts[b]), m->verts[c]);
    return d < 0 ? mul(s, 1.0 / 3) : mul(add(s, m->verts[d]), 0.25);
}

// A line drawn on the surface for legibility rather than a real edge. It still
// goes through the hidden-line test, so it only shows where its face is seen.
static void addMark(Mesh *m, V3 a, V3 b) {
    if (m->nm + 2 > m->cm) { m->cm = m->cm ? m->cm * 2 : 64; m->marks = realloc(m->marks, sizeof(int) * m->cm); }
    m->marks[m->nm++] = addVert(m, a);
    m->marks[m->nm++] = addVert(m, b);
}

#pragma mark 2D paths

typedef struct { double *x, *y; int n, cap; } Path2;

static void pathAdd(Path2 *p, double x, double y) {
    if (p->n == p->cap) {
        p->cap = p->cap ? p->cap * 2 : 64;
        p->x = realloc(p->x, sizeof(double) * p->cap);
        p->y = realloc(p->y, sizeof(double) * p->cap);
    }
    p->x[p->n] = x; p->y[p->n] = y; p->n++;
}

static void pathFree(Path2 *p) { free(p->x); free(p->y); *p = (Path2){0}; }

// A polyline with each corner rounded to its radius (0 = sharp), sampled every
// ~5°. For an open path the end radii are ignored.
static Path2 filleted(const double *vx, const double *vy, const double *rad, int n, BOOL closed) {
    Path2 out = {0};
    for (int i = 0; i < n; i++) {
        BOOL end = !closed && (i == 0 || i == n - 1);
        if (end || rad[i] <= 0) { pathAdd(&out, vx[i], vy[i]); continue; }
        int ip = (i + n - 1) % n, in = (i + 1) % n;
        double d1x = vx[i] - vx[ip], d1y = vy[i] - vy[ip], l1 = hypot(d1x, d1y);
        double d2x = vx[in] - vx[i], d2y = vy[in] - vy[i], l2 = hypot(d2x, d2y);
        d1x /= l1; d1y /= l1; d2x /= l2; d2y /= l2;
        double turn = acos(fmax(-1, fmin(1, d1x * d2x + d1y * d2y)));
        if (turn < 1e-6) { pathAdd(&out, vx[i], vy[i]); continue; }
        double side = d1x * d2y - d1y * d2x > 0 ? 1 : -1;   // +1 = left turn
        double td = fmin(rad[i] * tan(turn / 2), fmin(l1, l2) * 0.5);
        double r = td / tan(turn / 2);
        double ax = vx[i] - d1x * td, ay = vy[i] - d1y * td;
        double cx = ax - side * d1y * r, cy = ay + side * d1x * r;
        double a0 = atan2(ay - cy, ax - cx);
        int segs = MAX(2, (int)ceil(turn / (5 * M_PI / 180)));
        for (int k = 0; k <= segs; k++) {
            double a = a0 + side * turn * k / segs;
            pathAdd(&out, cx + r * cos(a), cy + r * sin(a));
        }
    }
    return out;
}

#pragma mark Primitives

// A plane to draw a 2D path in: point = o + a*x + b*y + w*z.
typedef struct { V3 o, a, b, w; } Frame;
static V3 at(Frame f, double x, double y, double z) {
    return add(f.o, add(mul(f.a, x), add(mul(f.b, y), mul(f.w, z))));
}

// Bent wood: a rectangle (thickness t in the plane, to the LEFT of the path's
// direction; width z0..z1 across it) swept along a path.
static void sweep(Mesh *m, Frame f, Path2 p, BOOL closed, double t, double z0, double z1) {
    int n = p.n;
    int (*ring)[4] = malloc(sizeof(int[4]) * n);
    V3 *ctr = malloc(sizeof(V3) * n), *tan3 = malloc(sizeof(V3) * n);
    for (int k = 0; k < n; k++) {
        int kp = closed ? (k + n - 1) % n : MAX(0, k - 1), kn = closed ? (k + 1) % n : MIN(n - 1, k + 1);
        double tx = p.x[kn] - p.x[kp], ty = p.y[kn] - p.y[kp], tl = hypot(tx, ty);
        tx /= tl; ty /= tl;
        double nx = -ty, ny = tx;                       // left normal
        // Mitre so the thickness stays t across corners.
        double sx = p.x[kn] - p.x[k], sy = p.y[kn] - p.y[k];
        if (k == kn) { sx = p.x[k] - p.x[kp]; sy = p.y[k] - p.y[kp]; }
        double sl = hypot(sx, sy), miter = 1;
        if (sl > 0) miter = 1 / fmax(0.5, nx * (-sy / sl) + ny * (sx / sl));
        double ix = p.x[k] + nx * t * miter, iy = p.y[k] + ny * t * miter;
        ring[k][0] = addVert(m, at(f, p.x[k], p.y[k], z0));
        ring[k][1] = addVert(m, at(f, p.x[k], p.y[k], z1));
        ring[k][2] = addVert(m, at(f, ix, iy, z1));
        ring[k][3] = addVert(m, at(f, ix, iy, z0));
        ctr[k] = at(f, (p.x[k] + ix) / 2, (p.y[k] + iy) / 2, (z0 + z1) / 2);
        tan3[k] = norm(add(mul(f.a, tx), mul(f.b, ty)));
    }
    int last = closed ? n : n - 1;
    for (int k = 0; k < last; k++) {
        int k2 = (k + 1) % n;
        V3 in = mul(add(ctr[k], ctr[k2]), 0.5);
        for (int c = 0; c < 4; c++) {
            int d = (c + 1) % 4;
            addFace(m, ring[k][c], ring[k][d], ring[k2][d], ring[k2][c], in);
        }
    }
    if (!closed) {
        addFace(m, ring[0][0], ring[0][1], ring[0][2], ring[0][3], add(ctr[0], tan3[0]));
        addFace(m, ring[n - 1][0], ring[n - 1][1], ring[n - 1][2], ring[n - 1][3], sub(ctr[n - 1], tan3[n - 1]));
    }
    free(ring); free(ctr); free(tan3);
}

// Revolve a closed (r, y) profile about an axis. Points with r = 0 sit on the
// axis and become poles.
static void lathe(Mesh *m, V3 o, V3 axis, V3 e1, Path2 p, int segs) {
    V3 e2 = cross(axis, e1);
    int n = p.n;
    double area = 0;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        area += p.x[i] * p.y[j] - p.x[j] * p.y[i];
    }
    double orient = area > 0 ? 1 : -1;
    int *ring = malloc(sizeof(int) * n * segs);
    for (int i = 0; i < n; i++) {
        BOOL pole = fabs(p.x[i]) < 1e-9;
        int shared = -1;
        for (int j = 0; j < segs; j++) {
            double a = 2 * M_PI * j / segs;
            V3 radial = add(mul(e1, cos(a)), mul(e2, sin(a)));
            V3 q = add(o, add(mul(radial, p.x[i]), mul(axis, p.y[i])));
            if (pole) { if (shared < 0) shared = addVert(m, q); ring[i * segs + j] = shared; }
            else ring[i * segs + j] = addVert(m, q);
        }
    }
    for (int i = 0; i < n; i++) {
        int i2 = (i + 1) % n;
        BOOL pa = fabs(p.x[i]) < 1e-9, pb = fabs(p.x[i2]) < 1e-9;
        if (pa && pb) continue;
        double dr = p.x[i2] - p.x[i], dy = p.y[i2] - p.y[i];
        double onr = orient * dy, ony = -orient * dr;    // outward normal in the profile plane
        for (int j = 0; j < segs; j++) {
            int j2 = (j + 1) % segs;
            double am = 2 * M_PI * (j + 0.5) / segs;
            V3 radial = add(mul(e1, cos(am)), mul(e2, sin(am)));
            V3 out = norm(add(mul(radial, onr), mul(axis, ony)));
            int A = ring[i * segs + j], B = ring[i * segs + j2], C = ring[i2 * segs + j2], D = ring[i2 * segs + j];
            if (pa)      addFace(m, A, C, D, -1, sub(faceCenter(m, A, C, D, -1), out));
            else if (pb) addFace(m, A, B, C, -1, sub(faceCenter(m, A, B, C, -1), out));
            else         addFace(m, A, B, C, D, sub(faceCenter(m, A, B, C, D), out));
        }
    }
    free(ring);
}

// A solid extruded through layers along f.w; each layer is the outline inset by
// some amount (for rounded edges). The outline must give the same number of
// points for every inset; side normals come from its winding, so deep lobes are
// fine, but the caps are fanned from the centroid (star-shaped about it).
typedef void (^Outline)(double inset, Path2 *out);

static void slab(Mesh *m, Frame f, Outline outline, const double *inset, const double *h, int nl) {
    int n = 0;
    int *ring = NULL;
    double *px = NULL, *py = NULL, orient = 1;
    V3 *cen = malloc(sizeof(V3) * nl);
    for (int l = 0; l < nl; l++) {
        Path2 p = {0};
        outline(inset[l], &p);
        if (!ring) {
            n = p.n;
            ring = malloc(sizeof(int) * n * nl);
            px = malloc(sizeof(double) * n * nl); py = malloc(sizeof(double) * n * nl);
            double area = 0;
            for (int i = 0; i < n; i++) area += p.x[i] * p.y[(i + 1) % n] - p.x[(i + 1) % n] * p.y[i];
            orient = area > 0 ? 1 : -1;
        }
        double cx = 0, cy = 0;
        for (int i = 0; i < n; i++) {
            ring[l * n + i] = addVert(m, at(f, p.x[i], p.y[i], h[l]));
            px[l * n + i] = p.x[i]; py[l * n + i] = p.y[i];
            cx += p.x[i]; cy += p.y[i];
        }
        cen[l] = at(f, cx / n, cy / n, h[l]);
        pathFree(&p);
    }
    V3 mid = mul(add(cen[0], cen[nl - 1]), 0.5);
    int c0 = addVert(m, cen[0]), c1 = addVert(m, cen[nl - 1]);
    for (int i = 0; i < n; i++) {
        int i2 = (i + 1) % n;
        addFace(m, c0, ring[i], ring[i2], -1, mid);
        addFace(m, c1, ring[(nl - 1) * n + i2], ring[(nl - 1) * n + i], -1, mid);
        for (int l = 0; l + 1 < nl; l++) {
            double dx = px[l * n + i2] - px[l * n + i], dy = py[l * n + i2] - py[l * n + i];
            V3 out = norm(add(mul(f.a, orient * dy), mul(f.b, -orient * dx)));
            int A = ring[l * n + i], B = ring[l * n + i2], C = ring[(l + 1) * n + i2], D = ring[(l + 1) * n + i];
            addFace(m, A, B, C, D, sub(faceCenter(m, A, B, C, D), out));
        }
    }
    free(ring); free(cen); free(px); free(py);
}

static void box(Mesh *m, V3 lo, V3 hi) {
    int v[8];
    for (int i = 0; i < 8; i++)
        v[i] = addVert(m, v3(i & 1 ? hi.x : lo.x, i & 2 ? hi.y : lo.y, i & 4 ? hi.z : lo.z));
    V3 c = mul(add(lo, hi), 0.5);
    addFace(m, v[0], v[1], v[3], v[2], c); addFace(m, v[4], v[5], v[7], v[6], c);
    addFace(m, v[0], v[1], v[5], v[4], c); addFace(m, v[2], v[3], v[7], v[6], c);
    addFace(m, v[0], v[2], v[6], v[4], c); addFace(m, v[1], v[3], v[7], v[5], c);
}

// Rounded-edge profile for a slab or a lathe: top/bottom fillets of radius fr.
static void filletLayers(double y0, double y1, double fr, double *inset, double *h, int *nl) {
    const int fs = 6;
    int k = 0;
    for (int i = 0; i <= fs; i++) {   // bottom fillet, underside out to the edge
        double a = M_PI_2 * i / fs;
        inset[k] = fr - fr * sin(a); h[k] = y0 + fr - fr * cos(a); k++;
    }
    for (int i = 0; i <= fs; i++) {   // top fillet, edge in to the top face
        double a = M_PI_2 * i / fs;
        inset[k] = fr - fr * cos(a); h[k] = y1 - fr + fr * sin(a); k++;
    }
    *nl = k;
}

#pragma mark Parts

static const double kLegW  = 4.6;   // tangential width of a bent leg
static const double kLegT  = 2.2;   // thickness of a bent leg
static const double kBendR = 5.0;   // outer radius of the bent knee

// A round seat or top with a slightly eased edge of radius fr.
static void roundSeatF(Mesh *m, double R, double top, double thick, double fr) {
    double inset[16], h[16];
    int nl;
    filletLayers(top - thick, top, fr, inset, h, &nl);
    Path2 p = {0};
    pathAdd(&p, 0, top - thick);
    for (int i = 0; i < nl; i++) pathAdd(&p, R - inset[i], h[i]);
    pathAdd(&p, 0, top);
    lathe(m, v3(0, 0, 0), kY, kX, p, 160);
    pathFree(&p);
}

// Aalto's bent-birch L-leg, as measured from Artek's own drawings. In the
// vertical plane through `o` along `out`, a w x t section is swept from the
// foot up the outside, round a knee of outer radius `bend` whose corner sits at
// radius rc, then in under the seat to radius rIn. Below the knee the leg leans
// out by `splay` degrees. The outer face sits outside the seat edge, so the
// knees bulge out from under the seat as on the real stools.
typedef struct { double rc, rIn, w, t, bend, splay; } AaltoLeg;

static void aaltoLeg(Mesh *m, V3 o, V3 out, double yUnder, AaltoLeg L) {
    V3 side = cross(kY, out);
    Frame f = { o, out, kY, side };
    double foot = L.rc + yUnder * tan(L.splay * M_PI / 180);
    double vx[3] = { foot, L.rc, L.rIn }, vy[3] = { 0, yUnder, yUnder }, rad[3] = { 0, L.bend, 0 };
    Path2 p = filleted(vx, vy, rad, 3, NO);
    sweep(m, f, p, NO, L.t, -L.w / 2, L.w / 2);
    pathFree(&p);
}

// The stools' leg, from the profile legs of Artek's Stool E60 drawing.
static const AaltoLeg kStoolLeg = { 20.8, 7.4, 3.9, 2.4, 5.9, 1.0 };

static void aaltoStool(Mesh *m, double R, double top, double thick, int legs, double phaseDeg, AaltoLeg L) {
    roundSeatF(m, R, top, thick, 0.3);
    for (int i = 0; i < legs; i++) {
        double a = phaseDeg * M_PI / 180 + i * 2 * M_PI / legs;
        aaltoLeg(m, v3(0, 0, 0), v3(cos(a), 0, sin(a)), top - thick, L);
    }
}

// Aalto's bent-birch L-leg in the vertical plane through `o` along `out`: up the
// outside at distance R, round the knee, then `tab` cm inward under the seat
// (whose underside is at yUnder). Adds the knee line across the outer face.
static void lLegSized(Mesh *m, V3 o, V3 out, double R, double yUnder, double tab,
                      double w, double t, double bend) {
    V3 side = cross(kY, out);
    Frame f = { o, out, kY, side };
    double vx[3] = { R, R, R - tab }, vy[3] = { 0, yUnder, yUnder }, rad[3] = { 0, bend, 0 };
    Path2 p = filleted(vx, vy, rad, 3, NO);
    sweep(m, f, p, NO, t, -w / 2, w / 2);
    pathFree(&p);

    // Level with the underside of the tab: on a leg facing the viewer it marks
    // where the face starts to bend away.
    double ka = asin((bend - t) / bend);
    double kx = R - bend + bend * cos(ka), ky = yUnder - bend + bend * sin(ka);
    addMark(m, at(f, kx, ky, -w / 2), at(f, kx, ky, w / 2));
}

static void lLeg(Mesh *m, V3 o, V3 out, double R, double yUnder, double tab) {
    lLegSized(m, o, out, R, yUnder, tab, kLegW, kLegT, kBendR);
}

static double envOr(const char *k, double d) { const char *s = getenv(k); return s ? atof(s) : d; }

#pragma mark Designs

const char *STDesignName(STDesign d) {
    switch (d) {
        case STDesignStool60:    return "Stool 60";
        case STDesignStoolE60:   return "Stool E60";
        case STDesignBarStool64: return "Bar Stool 64";
        case STDesignChair69:    return "Chair 69";
        case STDesignPaimio41:   return "Paimio Armchair 41";
        case STDesignGoldenBell: return "Golden Bell A330S";
        case STDesignBeehive:    return "Beehive A331";
        case STDesignSavoyVase:  return "Aalto Vase (study)";
        case STDesignTableRound: return "Aalto Table round";
        case STDesignTableRect:  return "Aalto Table rectangular";
        case STDesignTeaTrolley900: return "Tea Trolley 900";
        case STDesignVase160:    return "Aalto Vase 160mm";
        case STDesignVase120:    return "Aalto Vase 120mm";
        case STDesignVase95:     return "Aalto Vase 95mm";
        default:                 return "";
    }
}

static void buildChair69(Mesh *m) {
    // Seat: 42 x 40 rounded square, top at 44.
    double hw = 21, hd = 20, rc = 6, top = 44, thick = 2.4;
    Outline rr = ^(double inset, Path2 *o) {
        double w = hw - inset, d = hd - inset, r = fmax(0.05, rc - inset);
        double cx[4] = { w - r, -(w - r), -(w - r), w - r }, cz[4] = { d - r, d - r, -(d - r), -(d - r) };
        for (int c = 0; c < 4; c++)
            for (int k = 0; k <= 12; k++) {
                double a = M_PI_2 * (c + k / 12.0);
                pathAdd(o, cx[c] + r * cos(a), cz[c] + r * sin(a));
            }
    };
    double inset[16], h[16];
    int nl;
    filletLayers(top - thick, top, 0.8, inset, h, &nl);
    Frame f = { v3(0, 0, 0), kX, kZ, kY };
    slab(m, f, rr, inset, h, nl);

    // Front legs: L-legs bending in from each side under the seat.
    for (int s = -1; s <= 1; s += 2)
        lLeg(m, v3(0, 0, hd - 4), v3(s, 0, 0), hw, top - thick, 9);
    // Back legs run straight up to carry the curved backrest.
    for (int s = -1; s <= 1; s += 2) {
        double x0 = s > 0 ? hw - 2.4 : -hw, x1 = s > 0 ? hw : -hw + 2.4;
        box(m, v3(x0, 0, -hd + 0.5), v3(x1, 76, -hd + 4.5));
    }
    // Backrest: a bent band spanning between the uprights, bowed backwards.
    Path2 band = {0};
    double bw = hw - 2.4;
    for (int i = 0; i <= 40; i++) {
        double x = bw - 2 * bw * i / 40.0, u = x / bw;
        pathAdd(&band, x, -hd + 3.5 - 2.5 * (1 - u * u));
    }
    Frame hf = { v3(0, 0, 0), kX, kZ, kY };
    sweep(m, hf, band, NO, 1.4, 63, 73);
    pathFree(&band);
}

static void buildPaimio(Mesh *m) {
    // Side elevation: x forward, y up; the frames sit at z = ±27.
    Frame left = { v3(0, 0, 0), kX, kY, kZ };
    double fx[4] = { -40, 36, 30, -33 }, fy[4] = { 0, 0, 60, 53 }, fr[4] = { 10, 9, 16, 22 };
    Path2 loop = filleted(fx, fy, fr, 4, YES);
    sweep(m, left, loop, YES, 4.5, 25, 29.5);
    sweep(m, left, loop, YES, 4.5, -29.5, -25);
    pathFree(&loop);

    // Seat and back: one sheet of bent plywood, scrolled at both ends.
    double sx[9] = { -28.5, -31.5, -28, -23.5, -7, 25, 31, 30.5, 27 };
    double sy[9] = {  58,    62,    66.5, 65,  27, 37, 36, 30,   30 };
    double sr[9] = {  0,     2.5,   3,   3,    9,  6,  2.5, 2,  0 };
    Path2 sheet = filleted(sx, sy, sr, 9, NO);
    sweep(m, left, sheet, NO, 1.0, -25, 25);
    pathFree(&sheet);
}

// Radius of a lathe profile's outer surface at height y.
static double profileR(Path2 p, double y) {
    double r = 0;
    for (int i = 0; i + 1 < p.n; i++) {
        double y0 = p.y[i], y1 = p.y[i + 1];
        if ((y - y0) * (y - y1) > 0 || y0 == y1) continue;
        double t = (y - y0) / (y1 - y0);
        r = fmax(r, p.x[i] + (p.x[i + 1] - p.x[i]) * t);
    }
    return r;
}

static void buildGoldenBell(Mesh *m) {
    // Domed crown, sides flaring gently, then a turned-out lip.
    double vx[8] = { 0,  1.5, 1.5,  6.8, 7.4, 8.9, 0 }, vy[8] = { 23.5, 23.5, 20.5, 20.5, 4, 0, 0 };
    double vr[8] = { 0,  0.3, 0.3,  5.5, 7,   0,   0 };
    Path2 p = filleted(vx, vy, vr, 7, YES);
    lathe(m, v3(0, 0, 0), kY, kX, p, 144);

    // A ring of small vent holes round the crown.
    double hy = 18.2, hr = profileR(p, hy) + 0.02;
    for (int k = 0; k < 28; k++) {
        double a = 2 * M_PI * k / 28;
        V3 radial = v3(cos(a), 0, sin(a)), tangent = v3(-sin(a), 0, cos(a));
        V3 c = add(mul(radial, hr), v3(0, hy, 0));
        for (int s = 0; s < 10; s++) {
            double b0 = 2 * M_PI * s / 10, b1 = 2 * M_PI * (s + 1) / 10;
            addMark(m, add(c, add(mul(tangent, 0.35 * cos(b0)), mul(kY, 0.35 * sin(b0)))),
                       add(c, add(mul(tangent, 0.35 * cos(b1)), mul(kY, 0.35 * sin(b1)))));
        }
    }
    pathFree(&p);

    // Cord.
    Path2 cord = {0};
    pathAdd(&cord, 0, 23.5); pathAdd(&cord, 0.25, 23.5); pathAdd(&cord, 0.25, 36); pathAdd(&cord, 0, 36);
    lathe(m, v3(0, 0, 0), kY, kX, cord, 24);
    pathFree(&cord);
}

static void buildBeehive(Mesh *m) {
    // Dome of stacked louvre rings around a solid core.
    double (^dome)(double) = ^(double y) { double u = (y - 1) / 31; return 16.5 * sqrt(fmax(0, 1 - u * u)); };
    Path2 core = {0};
    pathAdd(&core, 0, 2);
    for (int i = 0; i <= 20; i++) { double y = 2 + 27 * i / 20.0; pathAdd(&core, fmax(0.5, dome(y) - 2), y); }
    pathAdd(&core, 0, 29);
    lathe(m, v3(0, 0, 0), kY, kX, core, 144);
    pathFree(&core);

    for (int i = 0; i < 8; i++) {
        double yt = 28.5 - i * 3.5, yb = yt - 2.7;
        double rt = dome(yt), rb = dome(yb) + 0.4;
        Path2 band = {0};
        pathAdd(&band, rt, yt); pathAdd(&band, rb, yb); pathAdd(&band, rb - 0.3, yb); pathAdd(&band, rt - 0.3, yt);
        lathe(m, v3(0, 0, 0), kY, kX, band, 144);
        pathFree(&band);
    }
    Path2 cap = {0};
    pathAdd(&cap, 0, 28); pathAdd(&cap, 3.5, 28); pathAdd(&cap, 3.5, 31.5); pathAdd(&cap, 0.25, 31.5);
    pathAdd(&cap, 0.25, 42); pathAdd(&cap, 0, 42);
    lathe(m, v3(0, 0, 0), kY, kX, cap, 96);
    pathFree(&cap);
}

static void buildSavoy(Mesh *m) {
    // The free-form wavy plan, extruded straight up.
    // Irregular bulges and pinches, smoothed with a closed Catmull-Rom spline
    // through twelve points spaced evenly round the plan.
    static const double rad[12] = { 9.5, 7.0, 8.8, 6.0, 7.8, 8.6, 5.8, 8.2, 9.2, 6.6, 9.8, 7.4 };
    Outline wave = ^(double inset, Path2 *o) {
        double kx[12], kz[12];
        for (int i = 0; i < 12; i++) {
            double a = 2 * M_PI * i / 12;
            kx[i] = 1.15 * (rad[i] - inset) * cos(a); kz[i] = (rad[i] - inset) * sin(a);
        }
        for (int i = 0; i < 12; i++)
            for (int k = 0; k < 30; k++) {
                double t = k / 30.0, t2 = t * t, t3 = t2 * t;
                int i0 = (i + 11) % 12, i1 = i, i2 = (i + 1) % 12, i3 = (i + 2) % 12;
                double b0 = -0.5 * t3 + t2 - 0.5 * t, b1 = 1.5 * t3 - 2.5 * t2 + 1;
                double b2 = -1.5 * t3 + 2 * t2 + 0.5 * t, b3 = 0.5 * t3 - 0.5 * t2;
                pathAdd(o, b0 * kx[i0] + b1 * kx[i1] + b2 * kx[i2] + b3 * kx[i3],
                           b0 * kz[i0] + b1 * kz[i1] + b2 * kz[i2] + b3 * kz[i3]);
            }
    };
    double inset[2] = { 0, 0 }, h[2] = { 0, 25 };   // the tall 251mm Savoy
    Frame f = { v3(0, 0, 0), kX, kZ, kY };
    slab(m, f, wave, inset, h, 2);

    // Straight on, the waves never overhang, so no edge shows them. Draw a
    // fold line down the wall at each pinch and crest instead; the hidden-line
    // test keeps only the ones on the side facing the viewer.
    for (int i = 0; i < 12; i++) {
        double a = 2 * M_PI * i / 12, r = rad[i] + 0.02;
        V3 base = v3(1.15 * r * cos(a), 0, r * sin(a));
        addMark(m, base, add(base, v3(0, 25, 0)));
    }
}


#pragma mark Tables

// A rounded-rectangle top (or any outline) with softly rounded edges.
static void roundedTop(Mesh *m, double hw, double hd, double rc, double top, double thick) {
    Outline rr = ^(double inset, Path2 *o) {
        double w = hw - inset, d = hd - inset, r = fmax(0.05, rc - inset);
        double cx[4] = { w - r, -(w - r), -(w - r), w - r }, cz[4] = { d - r, d - r, -(d - r), -(d - r) };
        for (int c = 0; c < 4; c++)
            for (int k = 0; k <= 12; k++) {
                double a = M_PI_2 * (c + k / 12.0);
                pathAdd(o, cx[c] + r * cos(a), cz[c] + r * sin(a));
            }
    };
    double inset[16], h[16];
    int nl;
    filletLayers(top - thick, top, 0.8, inset, h, &nl);
    Frame f = { v3(0, 0, 0), kX, kZ, kY };
    slab(m, f, rr, inset, h, nl);
}

// Aalto Table round 90A, from Artek's drawing: Ø100 top 3.6 thick; four legs
// square to the front, set 8cm in from the edge, upright (no splay).
static void buildTableRound(Mesh *m) {
    double top = 72.3, thick = 3.6;
    roundSeatF(m, 49.6, top, thick, 0.3);
    AaltoLeg L = { 41.7, 27.2, 5.0, 2.6, 5.3, 0 };
    for (int i = 0; i < 4; i++) {
        double a = i * M_PI / 2;
        aaltoLeg(m, v3(0, 0, 0), v3(cos(a), 0, sin(a)), top - thick, L);
    }
}

// Aalto Table rectangular 120 x 60, from Artek's drawing. The L-legs stand at
// the ends and bend in across the short side; at each end a crossbar joins the
// two tabs under the top.
static void buildTableRect(Mesh *m) {
    double hw = 60, hd = 30, top = 70.6, thick = 4.0, yUnder = top - thick;
    roundedTop(m, hw, hd, 0.5, top, thick);
    AaltoLeg L = { 27.5, 13.7, 4.8, 2.5, 4.5, 0 };
    for (int sx = -1; sx <= 1; sx += 2) {
        double x = sx * 55.15;
        for (int sz = -1; sz <= 1; sz += 2)
            aaltoLeg(m, v3(x, 0, 0), v3(0, 0, sz), yUnder, L);
        box(m, v3(x - 2.4, yUnder - 2.4, -13.7), v3(x + 2.4, yUnder, 13.7));
    }
}

// Tea Trolley 900, from Artek's side and end elevations (90 x 65 x 60). Each
// side is one closed loop of bent birch: a top rail under the tray, the far
// leg down to a floor runner, a diagonal rising behind the wheel to a short
// run at axle height, and back up the wheel end. Big lens-section wheels sit
// just outside the loops; a tiled tray rides on top; a rattan basket hangs
// under the handle end between the loops; a round handle bar crowns that end.
static void buildTeaTrolley(Mesh *m) {
    const double zIn = 23.73, zOut = 29.44;       // loop faces, each side
    Frame side = { v3(0, 0, 0), kX, kY, kZ };

    // Loop, outer edge, counter-clockwise so the thickness falls inside.
    double fx[6] = { -45.25, -11.48, 16.68, 45.25, 45.25, -45.25 };
    double fy[6] = {  13.93,  13.93,  0.0,  0.0,   53.28, 53.28 };
    double fr[6] = {  5.86,   5.86,   5.86, 5.86,  5.86,  5.86 };
    Path2 loop = filleted(fx, fy, fr, 6, YES);
    sweep(m, side, loop, YES, 1.5, zIn, zOut);
    sweep(m, side, loop, YES, 1.5, -zOut, -zIn);
    pathFree(&loop);

    // Tray: 65 x 65, 5.7 deep, flush with the wheel end of the loops.
    box(m, v3(-45.25, 53.28, -32.5), v3(20.11, 59.0, 32.5));

    // Wheels: Ø36 discs, thicker at the hub than at the rim, centred 31.2 out.
    Path2 lens = {0};
    const int nl = 8;
    for (int i = 0; i <= nl; i++) {           // one face, hub to rim
        double r = 17.95 * i / nl, u = r / 17.95;
        pathAdd(&lens, r, -(0.37 + 0.99 * (1 - u * u)));
    }
    for (int i = nl; i >= 0; i--) {           // the other face, rim to hub
        double r = 17.95 * i / nl, u = r / 17.95;
        pathAdd(&lens, r, 0.37 + 0.99 * (1 - u * u));
    }
    for (int s = -1; s <= 1; s += 2)
        lathe(m, v3(-27.0, 17.95, s * 31.17), kZ, kX, lens, 144);
    pathFree(&lens);
    // Axle bar between the loops, resting on their axle-height runs.
    box(m, v3(-29.35, 15.56, -zIn), v3(-24.65, 20.27, zIn));

    // Handle bar across the top of the far end, chamfered at its ends.
    Path2 bar = {0};
    pathAdd(&bar, 0, -zOut); pathAdd(&bar, 1.35, -zOut); pathAdd(&bar, 1.66, -zOut + 0.3);
    pathAdd(&bar, 1.66, zOut - 0.3); pathAdd(&bar, 1.35, zOut); pathAdd(&bar, 0, zOut);
    lathe(m, v3(45.13, 52.06, 0), kZ, kX, bar, 64);
    pathFree(&bar);

    // Basket hanger: a crossbar under the top rail with a strap down each side.
    box(m, v3(16.07, 44.93, -zIn), v3(17.69, 51.36, zIn));
    for (int s = -1; s <= 1; s += 2)
        box(m, v3(16.07, 31.04, s > 0 ? zIn - 0.44 : -zIn), v3(17.69, 44.93, s > 0 ? zIn : -zIn + 0.44));
    // Basket.
    box(m, v3(17.9, 31.04, -23.44), v3(43.23, 44.93, 23.44));
}

#pragma mark Glass

// One plan curve from STAaltoVasePlan.h, scaled, in the model's x/z plane: the
// plan's 20.3 cm width runs across the screen, its depth runs toward the viewer.
// `inset` moves it inward along its normal (the walls lean out toward the rim).
static void vasePlanCurve(const float (*c)[2], double scale, double inset, Path2 *out) {
    const int n = ST_VASE_PLAN_N;
    double area = 0;
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        area += c[i][0] * c[j][1] - c[j][0] * c[i][1];
    }
    double side = area > 0 ? 1 : -1;            // +1: interior lies to the left
    for (int i = 0; i < n; i++) {
        int ip = (i + n - 1) % n, in = (i + 1) % n;
        double tu = c[in][0] - c[ip][0], tv = c[in][1] - c[ip][1], tl = hypot(tu, tv);
        double nu = -side * tv / tl, nv = side * tu / tl;   // inward normal
        double u = c[i][0] * scale + nu * inset, v = c[i][1] * scale + nv * inset;
        pathAdd(out, v, -u);   // the wavy left flank faces the viewer, as in the drawing
    }
}

// The iittala Aalto vase: mould-blown glass whose walls flare slightly from a
// smaller foot to the rim (0.77 cm per side on the 160 mm vase), with a 0.5 cm
// wall and a thick base. Plan from the traced drawing, scaled per size.
static void buildAaltoVase(Mesh *m, double height, double scale) {
    const int n = ST_VASE_PLAN_N;
    double taper = 0.77 * height / 16.0, base = 0.9 * height / 16.0 + 0.3;
    Path2 rimOut = {0}, rimIn = {0}, foot = {0}, floorIn = {0};
    vasePlanCurve(kVaseOuter, scale, 0, &rimOut);
    vasePlanCurve(kVaseInner, scale, 0, &rimIn);
    vasePlanCurve(kVaseOuter, scale, taper, &foot);
    vasePlanCurve(kVaseFloor, scale, 0, &floorIn);

    int *o0 = malloc(sizeof(int) * n), *o1 = malloc(sizeof(int) * n);
    int *i1 = malloc(sizeof(int) * n), *i0 = malloc(sizeof(int) * n);
    double cx = 0, cz = 0;
    for (int i = 0; i < n; i++) {
        o0[i] = addVert(m, v3(foot.x[i], 0, foot.y[i]));
        o1[i] = addVert(m, v3(rimOut.x[i], height, rimOut.y[i]));
        i1[i] = addVert(m, v3(rimIn.x[i], height, rimIn.y[i]));
        i0[i] = addVert(m, v3(floorIn.x[i], base, floorIn.y[i]));
        cx += foot.x[i]; cz += foot.y[i];
    }
    cx /= n; cz /= n;
    double area = 0;
    for (int i = 0; i < n; i++) area += rimOut.x[i] * rimOut.y[(i + 1) % n] - rimOut.x[(i + 1) % n] * rimOut.y[i];
    double orient = area > 0 ? 1 : -1;
    int cb = addVert(m, v3(cx, 0, cz)), cf = addVert(m, v3(cx, base, cz));
    for (int i = 0; i < n; i++) {
        int j = (i + 1) % n;
        double dx = rimOut.x[j] - rimOut.x[i], dz = rimOut.y[j] - rimOut.y[i];
        V3 out = norm(v3(orient * dz, 0, -orient * dx));     // horizontal, away from the glass
        V3 mid = faceCenter(m, o0[i], o0[j], o1[j], o1[i]);
        addFace(m, o0[i], o0[j], o1[j], o1[i], sub(mid, out));                 // outer wall
        mid = faceCenter(m, i0[i], i0[j], i1[j], i1[i]);
        addFace(m, i0[i], i0[j], i1[j], i1[i], add(mid, out));                 // inner wall faces the cavity
        mid = faceCenter(m, o1[i], o1[j], i1[j], i1[i]);
        addFace(m, o1[i], o1[j], i1[j], i1[i], sub(mid, v3(0, 1, 0)));         // rim
        addFace(m, cb, o0[i], o0[j], -1, v3(cx, 0.5 * base, cz));              // underside
        addFace(m, cf, i0[j], i0[i], -1, v3(cx, 0.5 * base, cz));              // inner floor
    }
    free(o0); free(o1); free(i1); free(i0);

    // Fold lines down the outside at each pinch of the plan, where the glass
    // creases (as the reference drawing marks them): found as the points of
    // tightest concave curvature, radius under 2.5 cm at full size.
    const int k = 4;
    for (int i = 0; i < n; i++) {
        double kap[2 * 8 + 1];
        for (int d = -8; d <= 8; d++) {
            int c = (i + d + n) % n, a = (c - k + n) % n, b = (c + k) % n;
            double v1x = rimOut.x[c] - rimOut.x[a], v1z = rimOut.y[c] - rimOut.y[a];
            double v2x = rimOut.x[b] - rimOut.x[c], v2z = rimOut.y[b] - rimOut.y[c];
            double l1 = hypot(v1x, v1z), l2 = hypot(v2x, v2z);
            double turn = asin(fmax(-1, fmin(1, (v1x * v2z - v1z * v2x) / (l1 * l2))));
            kap[d + 8] = -orient * turn / (0.5 * (l1 + l2)) * scale;   // concave > 0, at full size
        }
        BOOL peak = kap[8] > 0.4;
        for (int d = 0; d < 17 && peak; d++) if (kap[d] > kap[8]) peak = NO;
        if (!peak) continue;
        V3 a = v3(foot.x[i], 0, foot.y[i]), b = v3(rimOut.x[i], height, rimOut.y[i]);
        V3 nudge = mul(norm(v3(foot.x[i] - cx, 0, foot.y[i] - cz)), 0.02);
        addMark(m, add(a, nudge), add(b, nudge));
    }
    pathFree(&rimOut); pathFree(&rimIn); pathFree(&foot); pathFree(&floorIn);
    m->glass = YES;
    m->elevation = 14;
}

static void buildDesign(Mesh *m, STDesign d) {
    switch (d) {
        // Legs at 30/150/270: Artek's front elevation, with the back leg in the
        // middle (its tab's lower edge reads as the knee line) and the front
        // pair at the sides.
        case STDesignStool60:    aaltoStool(m, 17.25, 44, 2.6, 3, envOr("ST_PHI", 30), kStoolLeg); break;
        case STDesignStoolE60:   aaltoStool(m, 17.25, 44, 2.6, 4, 0, kStoolLeg); break;
        case STDesignBarStool64: {
            // 75cm version: splayed legs and a foot ring just inside them.
            AaltoLeg L = { 21.58, 7.8, 4.2, 2.8, 4.2, 5.4 };
            aaltoStool(m, 18.75, 74.6, 2.9, 4, 0, L);
            Path2 ring = {0};
            pathAdd(&ring, 21.3, 20.5); pathAdd(&ring, 23.0, 20.5); pathAdd(&ring, 23.0, 24.0); pathAdd(&ring, 21.3, 24.0);
            lathe(m, v3(0, 0, 0), kY, kX, ring, 160);
            pathFree(&ring);
            break;
        }
        case STDesignChair69:    buildChair69(m); break;
        case STDesignPaimio41:   buildPaimio(m); break;
        case STDesignGoldenBell: buildGoldenBell(m); break;
        case STDesignBeehive:    buildBeehive(m); break;
        case STDesignSavoyVase:  buildSavoy(m); break;
        case STDesignTableRound: buildTableRound(m); break;
        case STDesignTableRect:  buildTableRect(m); break;
        case STDesignTeaTrolley900: buildTeaTrolley(m); break;
        // Sizes sharing the 160 mm plan: 120 mm is 14.6 x 12.7 (MoMA), 95 mm is
        // 11.3 x 10 (Boijmans), both the same 1.14 proportion as the 160 mm.
        case STDesignVase160:    buildAaltoVase(m, 16.0, 1.0); break;
        case STDesignVase120:    buildAaltoVase(m, 12.0, 0.72); break;
        case STDesignVase95:     buildAaltoVase(m, 9.5, 0.557); break;
        default: break;
    }
}

#pragma mark Hidden-line render

typedef struct { int a, b, f; } HalfEdge;

static int cmpEdge(const void *x, const void *y) {
    const HalfEdge *p = x, *q = y;
    if (p->a != q->a) return p->a - q->a;
    return p->b - q->b;
}

CGPathRef STCreateDesignDrawingFull(STDesign design, STStoolHull *hullOut, CGPathRef *hiddenOut, CGPathRef *fillOut) {
    Mesh m = {0};
    buildDesign(&m, design);

    // Orthographic camera, level with the object (a straight elevation) unless
    // the design asks for a little height, as the glass does to show its rim.
    double el = envOr("ST_EL", m.elevation) * M_PI / 180, az = envOr("ST_AZ", 0) * M_PI / 180;
    V3 eye = v3(cos(el) * sin(az), sin(el), cos(el) * cos(az));   // toward the viewer
    V3 right = v3(cos(az), 0, -sin(az));
    V3 up = cross(eye, right);

    // Project: x, y on screen (cm), z = depth (bigger is farther).
    V3 *P = malloc(sizeof(V3) * m.nv);
    double minX = 1e9, maxX = -1e9, minY = 1e9, maxY = -1e9;
    for (int i = 0; i < m.nv; i++) {
        V3 p = m.verts[i];
        P[i] = v3(dot(p, right), dot(p, up), -dot(p, eye));
        minX = fmin(minX, P[i].x); maxX = fmax(maxX, P[i].x);
        minY = fmin(minY, P[i].y); maxY = fmax(maxY, P[i].y);
    }

    // Depth buffer over the drawing's bounds, ~2400px on the long side.
    const double ppc = 2400 / fmax(maxX - minX, maxY - minY);   // buffer pixels per cm
    const int pad = 4;
    int W = (int)ceil((maxX - minX) * ppc) + 2 * pad, H = (int)ceil((maxY - minY) * ppc) + 2 * pad;
    float *Z = malloc(sizeof(float) * W * H);
    for (int i = 0; i < W * H; i++) Z[i] = INFINITY;
    #define BX(x) (((x) - minX) * ppc + pad)
    #define BY(y) (((y) - minY) * ppc + pad)
    for (int f = 0; f < m.nf; f++) {
        Face *F = &m.faces[f];
        for (int t = 1; t + 1 < F->n; t++) {
            V3 a = P[F->v[0]], b = P[F->v[t]], c = P[F->v[t + 1]];
            double ax = BX(a.x), ay = BY(a.y), bx = BX(b.x), by = BY(b.y), cx = BX(c.x), cy = BY(c.y);
            double area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
            if (fabs(area) < 1e-9) continue;
            int x0 = fmax(0, floor(fmin(ax, fmin(bx, cx)))), x1 = fmin(W - 1, ceil(fmax(ax, fmax(bx, cx))));
            int y0 = fmax(0, floor(fmin(ay, fmin(by, cy)))), y1 = fmin(H - 1, ceil(fmax(ay, fmax(by, cy))));
            for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) {
                double px = x + 0.5, py = y + 0.5;
                double w0 = ((bx - px) * (cy - py) - (by - py) * (cx - px)) / area;
                double w1 = ((cx - px) * (ay - py) - (cy - py) * (ax - px)) / area;
                double w2 = 1 - w0 - w1;
                if (w0 < -1e-6 || w1 < -1e-6 || w2 < -1e-6) continue;
                float z = w0 * a.z + w1 * b.z + w2 * c.z;
                if (z < Z[y * W + x]) Z[y * W + x] = z;
            }
        }
    }

    // Edge adjacency: pair up the two faces sharing each edge.
    int nh = 0;
    for (int f = 0; f < m.nf; f++) nh += m.faces[f].n;
    HalfEdge *he = malloc(sizeof(HalfEdge) * nh);
    nh = 0;
    for (int f = 0; f < m.nf; f++) {
        Face *F = &m.faces[f];
        for (int i = 0; i < F->n; i++) {
            int a = F->v[i], b = F->v[(i + 1) % F->n];
            if (a == b) continue;
            he[nh++] = (HalfEdge){ a < b ? a : b, a < b ? b : a, f };
        }
    }
    qsort(he, nh, sizeof(HalfEdge), cmpEdge);

    CGMutablePathRef path = CGPathCreateMutable();
    CGMutablePathRef hidden = m.glass ? CGPathCreateMutable() : NULL;
    const double creaseCos = cos(35 * M_PI / 180);
    const double eps = 2.4 / ppc;          // depth slack for lines lying on surfaces
    // Stroke the visible parts of the projected segment a-b.
    void (^strokeVisible)(V3, V3) = ^(V3 a, V3 b) {
        double len = hypot(BX(b.x) - BX(a.x), BY(b.y) - BY(a.y));
        int steps = MAX(1, (int)ceil(len / 0.5));
        int runStart = -1;
        BOOL runVis = NO;
        for (int k = 0; k <= steps + 1; k++) {
            BOOL vis = NO;
            if (k <= steps) {
                double t = (double)k / steps;
                double x = BX(a.x + (b.x - a.x) * t), y = BY(a.y + (b.y - a.y) * t);
                double z = a.z + (b.z - a.z) * t;
                int ix = (int)x, iy = (int)y;
                float zmax = -INFINITY;   // most permissive depth in the 3x3 neighbourhood
                for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
                    int xx = ix + dx, yy = iy + dy;
                    if (xx < 0 || yy < 0 || xx >= W || yy >= H) { zmax = INFINITY; continue; }
                    zmax = fmax(zmax, Z[yy * W + xx]);
                }
                vis = z <= zmax + eps;
            }
            // Split the segment into runs of equal visibility; visible runs go
            // to the main path, hidden ones (glass only) to the faint path.
            BOOL done = k > steps;
            if (runStart >= 0 && (done || vis != runVis)) {
                int k1 = k - 1;
                CGMutablePathRef dst = runVis ? path : hidden;
                if (dst && (k1 > runStart || steps == 1)) {
                    double t0 = (double)runStart / steps, t1 = (double)k1 / steps;
                    CGPathMoveToPoint(dst, NULL, a.x + (b.x - a.x) * t0, a.y + (b.y - a.y) * t0);
                    CGPathAddLineToPoint(dst, NULL, a.x + (b.x - a.x) * t1, a.y + (b.y - a.y) * t1);
                }
                runStart = -1;
            }
            if (!done && runStart < 0 && (vis || hidden)) { runStart = k; runVis = vis; }
        }
    };

    for (int i = 0; i < nh; ) {
        int j = i + 1;
        while (j < nh && he[j].a == he[i].a && he[j].b == he[i].b) j++;
        BOOL draw;
        if (j - i == 1) draw = YES;
        else {
            V3 n1 = m.faces[he[i].f].normal, n2 = m.faces[he[i + 1].f].normal;
            double f1 = dot(n1, eye), f2 = dot(n2, eye);
            // Faces seen exactly edge-on (the seat's top and underside in a level
            // view) count as turned away; the tolerance absorbs rounding noise.
            BOOL front1 = f1 > 1e-6, front2 = f2 > 1e-6;
            draw = dot(n1, n2) < creaseCos || front1 != front2;
            if (!front1 && !front2 && !m.glass) draw = NO;   // both faces turned away: hidden (unless glass)
        }
        if (draw) strokeVisible(P[he[i].a], P[he[i].b]);
        i = j;
    }
    for (int i = 0; i < m.nm; i += 2) strokeVisible(P[m.marks[i]], P[m.marks[i + 1]]);

    if (hullOut) {
        hullOut->count = m.nv;
        hullOut->points = malloc(sizeof(CGPoint) * m.nv);
        for (int i = 0; i < m.nv; i++) hullOut->points[i] = CGPointMake(P[i].x, P[i].y);
    }
    if (fillOut) {
        // The solid silhouette: every face turned toward the viewer, each wound
        // the same way on screen so a nonzero fill gives their union.
        CGMutablePathRef fill = CGPathCreateMutable();
        for (int f = 0; f < m.nf; f++) {
            Face *F = &m.faces[f];
            if (dot(F->normal, eye) <= 1e-6) continue;
            double area = 0;
            for (int i = 0; i < F->n; i++) {
                V3 a = P[F->v[i]], b = P[F->v[(i + 1) % F->n]];
                area += a.x * b.y - b.x * a.y;
            }
            if (fabs(area) < 1e-9) continue;
            for (int k = 0; k < F->n; k++) {
                V3 q = P[F->v[area > 0 ? k : F->n - 1 - k]];
                if (k == 0) CGPathMoveToPoint(fill, NULL, q.x, q.y);
                else CGPathAddLineToPoint(fill, NULL, q.x, q.y);
            }
            CGPathCloseSubpath(fill);
        }
        *fillOut = fill;
    }
    free(he); free(Z); free(P); free(m.verts); free(m.faces); free(m.marks);
    if (hiddenOut) *hiddenOut = hidden;
    else if (hidden) CGPathRelease(hidden);
    return path;
}

CGPathRef STCreateDesignDrawingEx(STDesign design, STStoolHull *hullOut, CGPathRef *hiddenOut) {
    return STCreateDesignDrawingFull(design, hullOut, hiddenOut, NULL);
}

CGPathRef STCreateDesignDrawing(STDesign design, STStoolHull *hullOut) {
    return STCreateDesignDrawingFull(design, hullOut, NULL, NULL);
}

CGPathRef STCreateStoolDrawing(STStoolHull *hullOut) {
    return STCreateDesignDrawing(STDesignStool60, hullOut);
}
