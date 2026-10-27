/* MABD local: the one piece of the iOS OpenGL glue that needs gl4es's
 * internals (built against gl4es/src). gl4es draws "the screen" (framebuffer
 * 0) into glstate->fbo.mainfbo_fbo; iOS has no window framebuffer, so the
 * window's IOSurface-backed FBO (winios_gl.m) becomes that main FBO, and its
 * colour texture the main texture (glBlitFramebuffer reads it). fbo 0 clears
 * both, which must happen before DeleteGLState: gl4es would delete them. */
#include "gl/gl4es.h"

/* Returns 1 when the program has the screen bound right now, so the caller
 * binds the new FBO itself (gl4es only rebinds on the next glBindFramebuffer). */
int winios_gl4es_set_mainfbo(unsigned int fbo, unsigned int tex, int width, int height)
{
    if (!glstate) return 0;
    glstate->fbo.mainfbo_fbo = fbo;
    glstate->fbo.mainfbo_tex = fbo ? tex : 0;
    glstate->fbo.mainfbo_dep = 0;
    glstate->fbo.mainfbo_ste = 0;
    glstate->fbo.mainfbo_width = width;
    glstate->fbo.mainfbo_height = height;
    glstate->fbo.mainfbo_nwidth = width;
    glstate->fbo.mainfbo_nheight = height;
    return fbo && glstate->fbo.current_fb == glstate->fbo.fbo_0;
}
