/* Acceptance test PE for 32-bit OpenGL (opengl32's WoW64 thunks rewritten for
 * the guest window, build/win32u-unix/opengl32_wow64_ios.py; gl4es draws).
 *
 * A 32-bit PE that opens a window, makes a WGL context and checks each kind
 * of pointer crossing the 32-bit boundary, reading the result back with
 * glReadPixels (itself a guest pointer the unix side writes):
 *
 *   - glGetString: a host string copied into guest memory,
 *   - glClear: nothing crosses, the baseline,
 *   - glVertexPointer + glColorPointer from client memory: guest pointers,
 *   - the same arrays from a VBO: offsets that must NOT be converted,
 *   - glMapBuffer: a guest pointer handed back to 32-bit code.
 *
 * Then it spins the VBO triangle for MADEIRA_GL_SECONDS so it can be seen.
 *
 * Exit status (MADEIRA-EXIT: gl-x86.exe status=<n>):
 *   43  every check passed
 *   30  window / pixel format / context setup failed
 *   31  glGetString returned NULL or garbage
 *   32  glClear readback wrong
 *   33  client-array triangle readback wrong
 *   34  VBO triangle readback wrong
 *   35  glMapBuffer returned NULL or its write did not reach the draw
 */
#include <stddef.h>
#include <windows.h>
#include <GL/gl.h>

#define MADEIRA_GL_SECONDS 10
#define WIN_W 320
#define WIN_H 240

#define GL_ARRAY_BUFFER   0x8892
#define GL_STATIC_DRAW    0x88E4
#define GL_DYNAMIC_DRAW   0x88E8
#define GL_WRITE_ONLY     0x88B9
typedef void (APIENTRY *PFNGLGENBUFFERS)(GLsizei, GLuint *);
typedef void (APIENTRY *PFNGLBINDBUFFER)(GLenum, GLuint);
typedef void (APIENTRY *PFNGLBUFFERDATA)(GLenum, ptrdiff_t, const void *, GLenum);
typedef void *(APIENTRY *PFNGLMAPBUFFER)(GLenum, GLenum);
typedef GLboolean (APIENTRY *PFNGLUNMAPBUFFER)(GLenum);

void *memset( void *dst, int c, size_t n )
{
    unsigned char *p = dst;
    while (n--) *p++ = (unsigned char)c;
    return dst;
}

void *memcpy( void *dst, const void *src, size_t n )
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

static void out_str( const char *s )
{
    DWORD written = 0;
    const char *e = s;
    while (*e) e++;
    WriteFile( GetStdHandle( STD_ERROR_HANDLE ), s, (DWORD)(e - s), &written, NULL );
}

static void out_hex( const char *what, unsigned int v )
{
    static const char digits[] = "0123456789abcdef";
    char buf[96], *p = buf;
    const char *s = "MADEIRA-GL: ";
    int i;
    while (*s) *p++ = *s++;
    while (*what) *p++ = *what++;
    *p++ = ' '; *p++ = '0'; *p++ = 'x';
    for (i = 28; i >= 0; i -= 4) *p++ = digits[(v >> i) & 0xf];
    *p++ = '\n'; *p = 0;
    out_str( buf );
}

static void fail( const char *why, unsigned int v, UINT code )
{
    out_hex( why, v );
    ExitProcess( code );
}

static LRESULT CALLBACK wnd_proc( HWND hwnd, UINT msg, WPARAM wp, LPARAM lp )
{
    if (msg == WM_CLOSE) { PostQuitMessage( 0 ); return 0; }
    return DefWindowProcA( hwnd, msg, wp, lp );
}

static int pump( void )
{
    MSG msg;
    while (PeekMessageA( &msg, NULL, 0, 0, PM_REMOVE ))
    {
        if (msg.message == WM_QUIT) return 0;
        TranslateMessage( &msg );
        DispatchMessageA( &msg );
    }
    return 1;
}

/* The centre pixel, as 0x00RRGGBB. */
static unsigned int centre( void )
{
    unsigned char px[4] = { 0 };
    glFinish();
    glReadPixels( WIN_W / 2, WIN_H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px );
    return (px[0] << 16) | (px[1] << 8) | px[2];
}

static int close_to( unsigned int got, unsigned int want )
{
    int i;
    for (i = 0; i < 24; i += 8)
    {
        int a = (got >> i) & 0xff, b = (want >> i) & 0xff;
        if (a - b > 8 || b - a > 8) return 0;
    }
    return 1;
}

/* A triangle covering the centre: x, y pairs and RGB colours. */
static const GLfloat tri_xy[6] = { -0.8f, -0.8f, 0.8f, -0.8f, 0.0f, 0.8f };
static const GLubyte tri_green[12] = { 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255 };

void start( void )
{
    PIXELFORMATDESCRIPTOR pfd;
    WNDCLASSA wc;
    HINSTANCE inst = GetModuleHandleA( NULL );
    HWND hwnd;
    HDC hdc;
    HGLRC ctx;
    int format;
    const GLubyte *s;
    PFNGLGENBUFFERS pglGenBuffers;
    PFNGLBINDBUFFER pglBindBuffer;
    PFNGLBUFFERDATA pglBufferData;
    PFNGLMAPBUFFER pglMapBuffer;
    PFNGLUNMAPBUFFER pglUnmapBuffer;
    GLuint vbo[2];
    GLubyte *mapped;
    DWORD t0;
    unsigned int px, frames = 0, i;

    out_str( "MADEIRA-GL: 32-bit OpenGL test starting\n" );
    memset( &wc, 0, sizeof(wc) );
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.lpszClassName = "MadeiraGLX86";
    wc.style = CS_OWNDC;
    if (!RegisterClassA( &wc )) fail( "RegisterClassA failed", GetLastError(), 30 );
    hwnd = CreateWindowExA( 0, wc.lpszClassName, "Madeira OpenGL (32-bit)", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                            0, 0, WIN_W, WIN_H, NULL, NULL, inst, NULL );
    if (!hwnd) fail( "CreateWindowExA failed", GetLastError(), 30 );
    hdc = GetDC( hwnd );

    memset( &pfd, 0, sizeof(pfd) );
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    format = ChoosePixelFormat( hdc, &pfd );
    if (!format || !SetPixelFormat( hdc, format, &pfd )) fail( "pixel format failed", GetLastError(), 30 );
    ctx = wglCreateContext( hdc );
    if (!ctx || !wglMakeCurrent( hdc, ctx )) fail( "context failed", GetLastError(), 30 );
    out_str( "MADEIRA-GL: context current\n" );

    s = glGetString( GL_VERSION );
    if (!s || s[0] < '1' || s[0] > '9') fail( "glGetString(GL_VERSION) bad", (unsigned int)(ULONG_PTR)s, 31 );
    out_str( "MADEIRA-GL: GL_VERSION " ); out_str( (const char *)s ); out_str( "\n" );
    s = glGetString( GL_RENDERER );
    if (s) { out_str( "MADEIRA-GL: GL_RENDERER " ); out_str( (const char *)s ); out_str( "\n" ); }

    glViewport( 0, 0, WIN_W, WIN_H );
    glClearColor( 1.0f, 0.0f, 0.0f, 1.0f );
    glClear( GL_COLOR_BUFFER_BIT );
    px = centre();
    if (!close_to( px, 0xff0000 )) fail( "glClear readback", px, 32 );
    out_hex( "clear ok", px );

    /* client arrays: guest pointers */
    glClearColor( 0.0f, 0.0f, 0.0f, 1.0f );
    glClear( GL_COLOR_BUFFER_BIT );
    glEnableClientState( GL_VERTEX_ARRAY );
    glEnableClientState( GL_COLOR_ARRAY );
    glVertexPointer( 2, GL_FLOAT, 0, tri_xy );
    glColorPointer( 4, GL_UNSIGNED_BYTE, 0, tri_green );
    glDrawArrays( GL_TRIANGLES, 0, 3 );
    px = centre();
    if (!close_to( px, 0x00ff00 )) fail( "client-array triangle readback", px, 33 );
    out_hex( "client arrays ok", px );

    pglGenBuffers = (PFNGLGENBUFFERS)wglGetProcAddress( "glGenBuffers" );
    pglBindBuffer = (PFNGLBINDBUFFER)wglGetProcAddress( "glBindBuffer" );
    pglBufferData = (PFNGLBUFFERDATA)wglGetProcAddress( "glBufferData" );
    pglMapBuffer = (PFNGLMAPBUFFER)wglGetProcAddress( "glMapBuffer" );
    pglUnmapBuffer = (PFNGLUNMAPBUFFER)wglGetProcAddress( "glUnmapBuffer" );
    if (!pglGenBuffers || !pglBindBuffer || !pglBufferData || !pglMapBuffer || !pglUnmapBuffer)
        fail( "no buffer objects", 0, 34 );

    /* VBOs: the pointers are offsets */
    pglGenBuffers( 2, vbo );
    pglBindBuffer( GL_ARRAY_BUFFER, vbo[0] );
    pglBufferData( GL_ARRAY_BUFFER, sizeof(tri_xy), tri_xy, GL_STATIC_DRAW );
    pglBindBuffer( GL_ARRAY_BUFFER, vbo[1] );
    pglBufferData( GL_ARRAY_BUFFER, 12, NULL, GL_DYNAMIC_DRAW );
    mapped = pglMapBuffer( GL_ARRAY_BUFFER, GL_WRITE_ONLY );
    if (!mapped) fail( "glMapBuffer returned NULL", 0, 35 );
    out_hex( "mapped at", (unsigned int)(ULONG_PTR)mapped );
    for (i = 0; i < 12; i += 4) { mapped[i] = 0; mapped[i + 1] = 0; mapped[i + 2] = 255; mapped[i + 3] = 255; }
    pglUnmapBuffer( GL_ARRAY_BUFFER );
    glColorPointer( 4, GL_UNSIGNED_BYTE, 0, (const void *)0 );
    pglBindBuffer( GL_ARRAY_BUFFER, vbo[0] );
    glVertexPointer( 2, GL_FLOAT, 0, (const void *)0 );
    pglBindBuffer( GL_ARRAY_BUFFER, 0 );
    glClear( GL_COLOR_BUFFER_BIT );
    glDrawArrays( GL_TRIANGLES, 0, 3 );
    px = centre();
    if (!close_to( px, 0x0000ff )) fail( close_to( px, 0 ) ? "VBO triangle readback" : "mapped colours readback", px,
                                     close_to( px, 0 ) ? 34 : 35 );
    out_hex( "VBO + glMapBuffer ok", px );
    SwapBuffers( hdc );

    t0 = GetTickCount();
    while (pump() && GetTickCount() - t0 < MADEIRA_GL_SECONDS * 1000)
    {
        glClear( GL_COLOR_BUFFER_BIT );
        glMatrixMode( GL_MODELVIEW );
        glLoadIdentity();
        glRotatef( (GLfloat)((GetTickCount() - t0) % 3600) / 10.0f, 0.0f, 0.0f, 1.0f );
        glDrawArrays( GL_TRIANGLES, 0, 3 );
        SwapBuffers( hdc );
        frames++;
    }
    out_hex( "done, frames", frames );
    wglMakeCurrent( NULL, NULL );
    wglDeleteContext( ctx );
    ReleaseDC( hwnd, hdc );
    DestroyWindow( hwnd );
    ExitProcess( 43 );
}
