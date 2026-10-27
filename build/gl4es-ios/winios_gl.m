// MABD local: OpenGL for Windows programs on iOS.
//
// The pieces: gl4es (../../gl4es) turns the program's desktop OpenGL 2.1 into
// OpenGL ES; iOS's own OpenGL ES (EAGL) runs it; a window has no framebuffer
// on iOS, so its "screen" is an FBO whose colour buffer is one of three
// IOSurfaces; at each SwapBuffers the finished IOSurface is drawn by Metal
// into the same CAMetalLayer Direct3D games present to (IOSDisplayShim.m).
// The Wine side is driver_ios.c (winios_OpenGLInit and the drawable/context
// callbacks), which calls the C functions at the bottom of this file.
//
// Raw OpenGL ES calls go through pointers looked up in OpenGLES.framework:
// gl4es defines the same gl* names in this binary, and its bookkeeping must
// not see the window buffers.

#import <Foundation/Foundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLIOSurface.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

// gl4es (include/gl4esinit.h and gl/glstate.c)
void set_getprocaddress(void *(*new_proc_address)(const char *));
void set_getmainfbsize(void (*new_getMainFBSize)(int *width, int *height));
void initialize_gl4es(void);
void *gl4es_GetProcAddress(const char *name);
void *NewGLState(void *shared_glstate, int es2only);
void DeleteGLState(void *oldstate);
void ActivateGLState(void *new_glstate);
// gl4es_glue.c
int winios_gl4es_set_mainfbo(unsigned int fbo, unsigned int tex, int width, int height);
// IOSDisplayShim.m / Winios.m
CAMetalLayer *madeira_display_layer(void) __attribute__((weak));
CAMetalLayer *winios_metal_layer_for_hwnd(void *hwnd) __attribute__((weak));
void winios_note_game_metal_hwnd(void *hwnd) __attribute__((weak));

#define LOG(...) do { fprintf(stderr, "[gl] " __VA_ARGS__); fputc('\n', stderr); } while (0)

static void *gles_lib;
static void *(*p_proc)(const char *);

#define RAW(ret, name, args) static ret (*r_##name) args
RAW(void, glGenTextures, (GLsizei, GLuint *));
RAW(void, glDeleteTextures, (GLsizei, const GLuint *));
RAW(void, glBindTexture, (GLenum, GLuint));
RAW(void, glTexParameteri, (GLenum, GLenum, GLint));
RAW(void, glGenFramebuffers, (GLsizei, GLuint *));
RAW(void, glDeleteFramebuffers, (GLsizei, const GLuint *));
RAW(void, glBindFramebuffer, (GLenum, GLuint));
RAW(void, glFramebufferTexture2D, (GLenum, GLenum, GLenum, GLuint, GLint));
RAW(void, glFramebufferRenderbuffer, (GLenum, GLenum, GLenum, GLuint));
RAW(GLenum, glCheckFramebufferStatus, (GLenum));
RAW(void, glGenRenderbuffers, (GLsizei, GLuint *));
RAW(void, glDeleteRenderbuffers, (GLsizei, const GLuint *));
RAW(void, glBindRenderbuffer, (GLenum, GLuint));
RAW(void, glRenderbufferStorage, (GLenum, GLenum, GLsizei, GLsizei));
RAW(void, glGetIntegerv, (GLenum, GLint *));
RAW(void, glFinish, (void));
RAW(void, glFlush, (void));
#undef RAW

static void *gles_proc(const char *name) { return gles_lib ? dlsym(gles_lib, name) : NULL; }

// --- Contexts -------------------------------------------------------------

#define BUFFERS 3

struct winios_gl_surface;

struct winios_gl_context {
    void *eagl;                     // EAGLContext, retained
    void *glstate;                  // gl4es state
    struct winios_gl_surface *surf; // what it draws to (NULL: nothing)
    int viewport_set;
};

struct fbo_slot {
    struct winios_gl_context *ctx;
    GLuint fbo;
    int generation;                 // surface generation it is attached for
    int index;                      // colour buffer attached
};

struct winios_gl_surface {
    void *hwnd;
    int w, h, generation;
    IOSurfaceRef io[BUFFERS];
    GLuint tex[BUFFERS];
    void *mtl[BUFFERS];             // id<MTLTexture>, retained
    GLuint depth;
    int cur;
    struct fbo_slot fbos[8];
    int noted;
    void *layer;                    // CAMetalLayer it presents to, retained
    unsigned long swaps;
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static EAGLSharegroup *g_share;
static void *g_shared_state;        // first gl4es state: every other shares it
static int g_gl4es_ready;
static __thread struct winios_gl_context *t_current;

static Class eagl_class(void) { return NSClassFromString(@"EAGLContext"); }

static void main_fb_size(int *w, int *h)
{
    struct winios_gl_context *c = t_current;
    *w = c && c->surf ? c->surf->w : 1;
    *h = c && c->surf ? c->surf->h : 1;
}

int winios_gl_init(void)
{
    if (gles_lib) return 1;
    gles_lib = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_LOCAL);
    if (!gles_lib || !eagl_class()) { LOG("OpenGL ES is not available: %s", dlerror()); gles_lib = NULL; return 0; }
#define LOAD(name) if (!(r_##name = gles_proc(#name))) { LOG("missing %s", #name); return 0; }
    LOAD(glGenTextures) LOAD(glDeleteTextures) LOAD(glBindTexture) LOAD(glTexParameteri)
    LOAD(glGenFramebuffers) LOAD(glDeleteFramebuffers) LOAD(glBindFramebuffer)
    LOAD(glFramebufferTexture2D) LOAD(glFramebufferRenderbuffer) LOAD(glCheckFramebufferStatus)
    LOAD(glGenRenderbuffers) LOAD(glDeleteRenderbuffers) LOAD(glBindRenderbuffer)
    LOAD(glRenderbufferStorage) LOAD(glGetIntegerv) LOAD(glFinish) LOAD(glFlush)
#undef LOAD
    set_getprocaddress(gles_proc);
    set_getmainfbsize(main_fb_size);
    LOG("OpenGL ES loaded; desktop OpenGL through gl4es");
    return 1;
}

void *winios_gl_proc(const char *name)
{
    return gl4es_GetProcAddress(name);
}

void *winios_gl_context_create(void)
{
    struct winios_gl_context *c = calloc(1, sizeof(*c));
    EAGLContext *e;
    pthread_mutex_lock(&g_lock);
    e = [[eagl_class() alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3 sharegroup:g_share];
    if (!e) e = [[eagl_class() alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2 sharegroup:g_share];
    if (e && !g_share) g_share = e.sharegroup;
    pthread_mutex_unlock(&g_lock);
    if (!e) { LOG("EAGLContext creation failed"); free(c); return NULL; }
    c->eagl = (__bridge_retained void *)e;
    LOG("context %p (OpenGL ES %d)", c, (int)e.API);
    return c;
}

static void release_fbos_of(struct winios_gl_context *c);

void winios_gl_context_destroy(void *handle)
{
    struct winios_gl_context *c = handle;
    if (!c) return;
    if (t_current == c) {
        winios_gl4es_set_mainfbo(0, 0, 0, 0);
        [eagl_class() setCurrentContext:nil];
        t_current = NULL;
    }
    release_fbos_of(c);
    if (c->glstate && c->glstate != g_shared_state) {
        void *keep = g_shared_state;
        ActivateGLState(c->glstate);
        winios_gl4es_set_mainfbo(0, 0, 0, 0);
        DeleteGLState(c->glstate);
        if (keep) ActivateGLState(keep);
    }
    CFBridgingRelease(c->eagl);
    free(c);
}

// --- Window buffers -------------------------------------------------------

static id<MTLDevice> g_device;
static id<MTLCommandQueue> g_queue;
static id<MTLRenderPipelineState> g_pipeline;
static MTLPixelFormat g_pipeline_format;

static void free_buffers(struct winios_gl_surface *s)
{
    for (int i = 0; i < BUFFERS; i++) {
        if (s->tex[i]) r_glDeleteTextures(1, &s->tex[i]);
        if (s->mtl[i]) CFBridgingRelease(s->mtl[i]);
        if (s->io[i]) CFRelease(s->io[i]);
        s->tex[i] = 0; s->mtl[i] = NULL; s->io[i] = NULL;
    }
    if (s->depth) r_glDeleteRenderbuffers(1, &s->depth);
    s->depth = 0;
}

// Needs the surface's context current (textures live in the shared group).
static int make_buffers(struct winios_gl_surface *s, int w, int h)
{
    EAGLContext *e = [eagl_class() currentContext];
    GLint old_tex = 0, old_rb = 0;
    if (!g_device) {
        g_device = MTLCreateSystemDefaultDevice();
        g_queue = [g_device newCommandQueue];
    }
    free_buffers(s);
    r_glGetIntegerv(GL_TEXTURE_BINDING_2D, &old_tex);
    r_glGetIntegerv(GL_RENDERBUFFER_BINDING, &old_rb);
    for (int i = 0; i < BUFFERS; i++) {
        NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h),
                                 (id)kIOSurfaceBytesPerElement: @4,
                                 (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
        s->io[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!s->io[i]) { LOG("IOSurface %dx%d failed", w, h); free_buffers(s); return 0; }
        r_glGenTextures(1, &s->tex[i]);
        r_glBindTexture(GL_TEXTURE_2D, s->tex[i]);
        r_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        r_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        r_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        r_glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        if (![e texImageIOSurface:s->io[i] target:GL_TEXTURE_2D internalFormat:GL_RGBA
                            width:w height:h format:GL_BGRA_EXT type:GL_UNSIGNED_BYTE plane:0]) {
            LOG("texImageIOSurface failed"); free_buffers(s); return 0;
        }
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [g_device newTextureWithDescriptor:d iosurface:s->io[i] plane:0];
        s->mtl[i] = (__bridge_retained void *)t;
    }
    r_glGenRenderbuffers(1, &s->depth);
    r_glBindRenderbuffer(GL_RENDERBUFFER, s->depth);
    r_glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, w, h);
    r_glBindTexture(GL_TEXTURE_2D, old_tex);
    r_glBindRenderbuffer(GL_RENDERBUFFER, old_rb);
    s->w = w; s->h = h; s->cur = 0; s->generation++;
    LOG("window %p buffers %dx%d", s->hwnd, w, h);
    return 1;
}

void *winios_gl_surface_create(void *hwnd)
{
    struct winios_gl_surface *s = calloc(1, sizeof(*s));
    s->hwnd = hwnd;
    return s;
}

static void release_fbos_of(struct winios_gl_context *c)
{
    // Only the context's own surface can hold its FBOs while it is current.
    struct winios_gl_surface *s = c->surf;
    if (!s) return;
    for (int i = 0; i < 8; i++)
        if (s->fbos[i].ctx == c) {
            if (t_current == c) r_glDeleteFramebuffers(1, &s->fbos[i].fbo);
            s->fbos[i].ctx = NULL; s->fbos[i].fbo = 0;
        }
}

void winios_gl_surface_destroy(void *handle)
{
    struct winios_gl_surface *s = handle;
    if (!s) return;
    if (t_current && t_current->surf == s) {
        winios_gl4es_set_mainfbo(0, 0, 0, 0);
        for (int i = 0; i < 8; i++) if (s->fbos[i].ctx == t_current) r_glDeleteFramebuffers(1, &s->fbos[i].fbo);
        free_buffers(s);
        t_current->surf = NULL;
    } else {
        // GL names are reclaimed with the share group; the CPU-side objects go now.
        for (int i = 0; i < BUFFERS; i++) {
            if (s->mtl[i]) CFBridgingRelease(s->mtl[i]);
            if (s->io[i]) CFRelease(s->io[i]);
        }
    }
    if (s->layer) CFBridgingRelease(s->layer);
    free(s);
}

// The current context's FBO for its surface, attached to the current buffer.
static GLuint attach(struct winios_gl_context *c, struct winios_gl_surface *s)
{
    struct fbo_slot *slot = NULL;
    GLint old_fb = 0;
    for (int i = 0; i < 8 && !slot; i++) if (s->fbos[i].ctx == c) slot = &s->fbos[i];
    for (int i = 0; i < 8 && !slot; i++) if (!s->fbos[i].ctx) { slot = &s->fbos[i]; slot->ctx = c; slot->fbo = 0; }
    if (!slot) return 0;
    r_glGetIntegerv(GL_FRAMEBUFFER_BINDING, &old_fb);
    if (!slot->fbo) { r_glGenFramebuffers(1, &slot->fbo); slot->generation = -1; }
    if (slot->generation != s->generation || slot->index != s->cur) {
        r_glBindFramebuffer(GL_FRAMEBUFFER, slot->fbo);
        r_glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s->tex[s->cur], 0);
        if (slot->generation != s->generation) {
            r_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, s->depth);
            r_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, s->depth);
            GLenum st = r_glCheckFramebufferStatus(GL_FRAMEBUFFER);
            if (st != GL_FRAMEBUFFER_COMPLETE) LOG("window FBO incomplete: %#x", st);
        }
        slot->generation = s->generation;
        slot->index = s->cur;
        r_glBindFramebuffer(GL_FRAMEBUFFER, old_fb);
    }
    return slot->fbo;
}

// Point gl4es's screen at the surface (and bind it if the program draws to the screen now).
static void use_as_screen(struct winios_gl_context *c, struct winios_gl_surface *s)
{
    GLuint fbo = attach(c, s);
    if (winios_gl4es_set_mainfbo(fbo, s->tex[s->cur], s->w, s->h))
        r_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
}

int winios_gl_make_current(void *ctx_handle, void *surf_handle, int w, int h)
{
    struct winios_gl_context *c = ctx_handle;
    struct winios_gl_surface *s = surf_handle;
    if (!c) {
        if (t_current) winios_gl4es_set_mainfbo(0, 0, 0, 0);
        [eagl_class() setCurrentContext:nil];
        t_current = NULL;
        return 1;
    }
    if (![eagl_class() setCurrentContext:(__bridge EAGLContext *)c->eagl]) { LOG("setCurrentContext failed"); return 0; }
    if (!g_gl4es_ready) {
        initialize_gl4es();
        g_gl4es_ready = 1;
    }
    if (!c->glstate) {
        c->glstate = NewGLState(g_shared_state, 0);
        if (!g_shared_state) g_shared_state = c->glstate;
    }
    ActivateGLState(c->glstate);
    t_current = c;
    c->surf = s;
    if (!s) { winios_gl4es_set_mainfbo(0, 0, 0, 0); return 1; }
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if ((s->w != w || s->h != h || !s->tex[0]) && !make_buffers(s, w, h)) return 0;
    use_as_screen(c, s);
    if (!c->viewport_set) {
        void (*viewport)(GLint, GLint, GLsizei, GLsizei) = gl4es_GetProcAddress("glViewport");
        void (*scissor)(GLint, GLint, GLsizei, GLsizei) = gl4es_GetProcAddress("glScissor");
        if (viewport) viewport(0, 0, w, h);
        if (scissor) scissor(0, 0, w, h);
        c->viewport_set = 1;
    }
    return 1;
}

// --- Present --------------------------------------------------------------

static id<MTLRenderPipelineState> pipeline_for(MTLPixelFormat format)
{
    if (g_pipeline && g_pipeline_format == format) return g_pipeline;
    static NSString *src =
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct V { float4 pos [[position]]; float2 uv; };\n"
         "vertex V vs(uint id [[vertex_id]]) {\n"
         "  float2 p = float2((id << 1) & 2, id & 2);\n"
         "  V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = p; return o; }\n"
         "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
         "  constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
         "  return float4(t.sample(s, in.uv).rgb, 1.0); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:nil error:&err];
    if (!lib) { LOG("present shader: %s", err.localizedDescription.UTF8String); return nil; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"fs"];
    d.colorAttachments[0].pixelFormat = format;
    g_pipeline = [g_device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!g_pipeline) LOG("present pipeline: %s", err.localizedDescription.UTF8String);
    g_pipeline_format = format;
    return g_pipeline;
}

static CAMetalLayer *layer_for(struct winios_gl_surface *s)
{
    const char *desk = getenv("MADEIRA_DESKTOP");
    CAMetalLayer *layer;
    if (s->layer) return (__bridge CAMetalLayer *)s->layer;
    if (desk && *desk == '1') layer = winios_metal_layer_for_hwnd ? winios_metal_layer_for_hwnd(s->hwnd) : nil;
    else {
        if (!s->noted && winios_note_game_metal_hwnd) { winios_note_game_metal_hwnd(s->hwnd); s->noted = 1; }
        layer = madeira_display_layer ? madeira_display_layer() : nil;
    }
    LOG("window %p presents to %s layer %p", s->hwnd, desk && *desk == '1' ? "its desktop" : "the game", (__bridge void *)layer);
    if (layer) s->layer = (__bridge_retained void *)layer;
    return layer;
}

int winios_gl_swap(void *surf_handle, int w, int h)
{
    struct winios_gl_surface *s = surf_handle;
    struct winios_gl_context *c = t_current;
    if (!s || !c || c->surf != s || !s->tex[0]) {
        static int said;
        if (said++ < 5) LOG("swap skipped: surface %p current %p (draws to %p) buffers %u", s, c, c ? c->surf : NULL, s ? s->tex[0] : 0);
        return 0;
    }
    r_glFinish();
    @autoreleasepool {
        CAMetalLayer *layer = layer_for(s);
        id<MTLTexture> tex = (__bridge id<MTLTexture>)s->mtl[s->cur];
        if (layer && tex) {
            if (!layer.device) layer.device = g_device;
            if (layer.drawableSize.width != s->w || layer.drawableSize.height != s->h)
                layer.drawableSize = CGSizeMake(s->w, s->h);
            id<MTLRenderPipelineState> pipe = pipeline_for(layer.pixelFormat);
            id<CAMetalDrawable> drawable = pipe ? [layer nextDrawable] : nil;
            if (s->swaps < 3 || !(s->swaps % 600))
                LOG("swap #%lu window %p %dx%d: layer %p pipeline %p drawable %p", s->swaps, s->hwnd, s->w, s->h,
                    (__bridge void *)layer, (__bridge void *)pipe, (__bridge void *)drawable);
            if (drawable) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = drawable.texture;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLCommandBuffer> cb = [g_queue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:pipe];
                [enc setFragmentTexture:tex atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding];
                [cb presentDrawable:drawable];
                [cb commit];
            }
        }
    }
    s->swaps++;
    // Next frame into the next buffer (Metal may still be reading this one).
    s->cur = (s->cur + 1) % BUFFERS;
    if (w > 0 && h > 0 && (w != s->w || h != s->h)) make_buffers(s, w, h);
    use_as_screen(c, s);
    return 1;
}

void winios_gl_flush(void)
{
    if (r_glFlush) r_glFlush();
}
