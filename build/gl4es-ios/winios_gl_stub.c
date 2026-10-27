/* MABD local: linked in place of build/gl4es-ios when that is not built:
 * the OpenGL driver in driver_ios.c then reports no OpenGL, as before. */
int   winios_gl_init( void ) { return 0; }
void *winios_gl_proc( const char *name ) { return 0; }
void *winios_gl_context_create( void ) { return 0; }
void  winios_gl_context_destroy( void *ctx ) { }
int   winios_gl_make_current( void *ctx, void *surface, int w, int h ) { return 0; }
void *winios_gl_surface_create( void *hwnd ) { return 0; }
void  winios_gl_surface_destroy( void *surface ) { }
int   winios_gl_swap( void *surface, int w, int h ) { return 0; }
void  winios_gl_flush( void ) { }
