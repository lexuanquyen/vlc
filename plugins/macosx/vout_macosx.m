/*****************************************************************************
 * vout_macosx.m: MacOS X video output plugin
 *****************************************************************************
 * Copyright (C) 2001, 2002 VideoLAN
 * $Id: vout_macosx.m,v 1.8 2002/07/15 01:54:04 jlj Exp $
 *
 * Authors: Colin Delacroix <colin@zoy.org>
 *          Florian G. Pflug <fgp@phlo.org>
 *          Jon Lech Johansen <jon-vl@nanocrew.net>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 * 
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111, USA.
 *****************************************************************************/

/*****************************************************************************
 * Preamble
 *****************************************************************************/
#include <errno.h>                                                 /* ENOMEM */
#include <stdlib.h>                                                /* free() */
#include <string.h>                                            /* strerror() */

#include <vlc/vlc.h>
#include <vlc/vout.h>
#include <vlc/intf.h>

#include <Cocoa/Cocoa.h>
#include <QuickTime/QuickTime.h>

#include "intf_macosx.h"
#include "vout_macosx.h"

#define QT_MAX_DIRECTBUFFERS 10

struct picture_sys_s
{
    void *p_info;
    unsigned int i_size;

    /* When using I420 output */
    PlanarPixmapInfoYUV420 pixmap_i420;
};

/*****************************************************************************
 * Local prototypes
 *****************************************************************************/
static int  vout_Create    ( vout_thread_t * );
static int  vout_Init      ( vout_thread_t * );
static void vout_End       ( vout_thread_t * );
static void vout_Destroy   ( vout_thread_t * );
static int  vout_Manage    ( vout_thread_t * );
static void vout_Render    ( vout_thread_t *, picture_t * );
static void vout_Display   ( vout_thread_t *, picture_t * );

static int  CoSendRequest      ( vout_thread_t *, long );
static int  CoCreateWindow     ( vout_thread_t * );
static int  CoDestroyWindow    ( vout_thread_t * );
static int  CoToggleFullscreen ( vout_thread_t * );

static void QTScaleMatrix      ( vout_thread_t * );
static int  QTCreateSequence   ( vout_thread_t * );
static void QTDestroySequence  ( vout_thread_t * );
static int  QTNewPicture       ( vout_thread_t *, picture_t * );
static void QTFreePicture      ( vout_thread_t *, picture_t * );

/*****************************************************************************
 * Functions exported as capabilities. They are declared as static so that
 * we don't pollute the namespace too much.
 *****************************************************************************/
void _M( vout_getfunctions )( function_list_t * p_function_list )
{
    p_function_list->functions.vout.pf_create     = vout_Create;
    p_function_list->functions.vout.pf_init       = vout_Init;
    p_function_list->functions.vout.pf_end        = vout_End;
    p_function_list->functions.vout.pf_destroy    = vout_Destroy;
    p_function_list->functions.vout.pf_manage     = vout_Manage;
    p_function_list->functions.vout.pf_render     = vout_Render;
    p_function_list->functions.vout.pf_display    = vout_Display;
}

/*****************************************************************************
 * vout_Create: allocates MacOS X video thread output method
 *****************************************************************************
 * This function allocates and initializes a MacOS X vout method.
 *****************************************************************************/
static int vout_Create( vout_thread_t *p_vout )
{
    OSErr err;

    p_vout->p_sys = malloc( sizeof( vout_sys_t ) );
    if( p_vout->p_sys == NULL )
    {
        msg_Err( p_vout, "out of memory" );
        return( 1 );
    }

    memset( p_vout->p_sys, 0, sizeof( vout_sys_t ) );

    p_vout->p_sys->p_intf = vlc_object_find( p_vout, VLC_OBJECT_INTF, 
                                             FIND_ANYWHERE );
    if( p_vout->p_sys->p_intf == NULL )
    {
        msg_Err( p_vout, "no interface present" );
        free( p_vout->p_sys );
        return( 1 );
    }

    if( p_vout->p_sys->p_intf->p_module == NULL || 
        strcmp( p_vout->p_sys->p_intf->p_module->psz_object_name, 
                MODULE_STRING ) != 0 )
    {
        msg_Err( p_vout, "MacOS X interface module required" );
        vlc_object_release( p_vout->p_sys->p_intf );
        free( p_vout->p_sys );
        return( 1 );
    }

    p_vout->p_sys->h_img_descr = 
        (ImageDescriptionHandle)NewHandleClear( sizeof(ImageDescription) );
    p_vout->p_sys->p_matrix = (MatrixRecordPtr)malloc( sizeof(MatrixRecord) );

    p_vout->p_sys->b_mouse_pointer_visible = 1;

    /* set window size */
    p_vout->p_sys->s_rect.size.width = p_vout->i_window_width;
    p_vout->p_sys->s_rect.size.height = p_vout->i_window_height;

    if( ( err = EnterMovies() ) != noErr )
    {
        msg_Err( p_vout, "EnterMovies failed: %d", err );
        free( p_vout->p_sys->p_matrix );
        DisposeHandle( (Handle)p_vout->p_sys->h_img_descr );
        free( p_vout->p_sys );
        return( 1 );
    } 

    if( vout_ChromaCmp( p_vout->render.i_chroma, FOURCC_I420 ) )
    {
        err = FindCodec( kYUV420CodecType, bestSpeedCodec,
                         nil, &p_vout->p_sys->img_dc );
        if( err == noErr && p_vout->p_sys->img_dc != 0 )
        {
            p_vout->output.i_chroma = FOURCC_I420;
            p_vout->p_sys->i_codec = kYUV420CodecType;
        }
        else
        {
            msg_Err( p_vout, "failed to find an appropriate codec" );
        }
    }
    else
    {
        msg_Err( p_vout, "chroma 0x%08x not supported",
                         p_vout->render.i_chroma );
    }

    if( p_vout->p_sys->img_dc == 0 )
    {
        free( p_vout->p_sys->p_matrix );
        DisposeHandle( (Handle)p_vout->p_sys->h_img_descr );
        free( p_vout->p_sys );
        return( 1 );        
    }

    if( CoCreateWindow( p_vout ) )
    {
        msg_Err( p_vout, "unable to create window" );
        free( p_vout->p_sys->p_matrix );
        DisposeHandle( (Handle)p_vout->p_sys->h_img_descr );
        free( p_vout->p_sys ); 
        return( 1 );
    }

    return( 0 );
}

/*****************************************************************************
 * vout_Init: initialize video thread output method
 *****************************************************************************/
static int vout_Init( vout_thread_t *p_vout )
{
    int i_index;
    picture_t *p_pic;

    I_OUTPUTPICTURES = 0;

    /* Initialize the output structure; we already found a codec,
     * and the corresponding chroma we will be using. Since we can
     * arbitrary scale, stick to the coordinates and aspect. */
    p_vout->output.i_width  = p_vout->render.i_width;
    p_vout->output.i_height = p_vout->render.i_height;
    p_vout->output.i_aspect = p_vout->render.i_aspect;

    SetPort( p_vout->p_sys->p_qdport );
    QTScaleMatrix( p_vout );

    if( QTCreateSequence( p_vout ) )
    {
        msg_Err( p_vout, "unable to create sequence" );
        return( 1 );
    }

    /* Try to initialize up to QT_MAX_DIRECTBUFFERS direct buffers */
    while( I_OUTPUTPICTURES < QT_MAX_DIRECTBUFFERS )
    {
        p_pic = NULL;

        /* Find an empty picture slot */
        for( i_index = 0; i_index < VOUT_MAX_PICTURES; i_index++ )
        {
            if( p_vout->p_picture[ i_index ].i_status == FREE_PICTURE )
            {
                p_pic = p_vout->p_picture + i_index;
                break;
            }
        }

        /* Allocate the picture */
        if( p_pic == NULL || QTNewPicture( p_vout, p_pic ) )
        {
            break;
        }

        p_pic->i_status = DESTROYED_PICTURE;
        p_pic->i_type   = DIRECT_PICTURE;

        PP_OUTPUTPICTURE[ I_OUTPUTPICTURES ] = p_pic;

        I_OUTPUTPICTURES++;
    }

    return( 0 );
}

/*****************************************************************************
 * vout_End: terminate video thread output method
 *****************************************************************************/
static void vout_End( vout_thread_t *p_vout )
{
    int i_index;

    QTDestroySequence( p_vout );

    /* Free the direct buffers we allocated */
    for( i_index = I_OUTPUTPICTURES; i_index; )
    {
        i_index--;
        QTFreePicture( p_vout, PP_OUTPUTPICTURE[ i_index ] );
    }
}

/*****************************************************************************
 * vout_Destroy: destroy video thread output method
 *****************************************************************************/
static void vout_Destroy( vout_thread_t *p_vout )
{
    if( CoDestroyWindow( p_vout ) )
    {
        msg_Err( p_vout, "unable to destroy window" );
    }

    ExitMovies();

    free( p_vout->p_sys->p_matrix );
    DisposeHandle( (Handle)p_vout->p_sys->h_img_descr );

    vlc_object_release( p_vout->p_sys->p_intf );

    free( p_vout->p_sys );
}

/*****************************************************************************
 * vout_Manage: handle events
 *****************************************************************************
 * This function should be called regularly by video output thread. It manages
 * console events. It returns a non null value on error.
 *****************************************************************************/
static int vout_Manage( vout_thread_t *p_vout )
{    
    if( p_vout->i_changes & VOUT_FULLSCREEN_CHANGE )
    {
        if( CoToggleFullscreen( p_vout ) )  
        {
            return( 1 );
        }

        p_vout->i_changes &= ~VOUT_FULLSCREEN_CHANGE;
    }

    if( p_vout->i_changes & VOUT_SIZE_CHANGE ) 
    {
        QTScaleMatrix( p_vout );
        SetDSequenceMatrix( p_vout->p_sys->i_seq, 
                            p_vout->p_sys->p_matrix );
 
        p_vout->i_changes &= ~VOUT_SIZE_CHANGE;
    }

    /* hide/show mouse cursor */
    if( p_vout->p_sys->b_mouse_moved ||
        p_vout->p_sys->i_time_mouse_last_moved )
    {
        vlc_bool_t b_change = 0;

        if( !p_vout->p_sys->b_mouse_pointer_visible )
        {
            CGDisplayShowCursor( kCGDirectMainDisplay );
            b_change = 1;
        }
#if 0
        else if( !p_vout->p_sys->b_mouse_moved && 
            mdate() - p_vout->p_sys->i_time_mouse_last_moved > 2000000 &&
            p_vout->p_sys->b_mouse_pointer_visible )
        {
            CGDisplayHideCursor( kCGDirectMainDisplay );
            b_change = 1;
        }
#endif

        if( b_change )
        {
            p_vout->p_sys->i_time_mouse_last_moved = 0;
            p_vout->p_sys->b_mouse_moved = 0;
            p_vout->p_sys->b_mouse_pointer_visible =
                !p_vout->p_sys->b_mouse_pointer_visible;
        }
    }

    return( 0 );
}

/*****************************************************************************
 * vout_Render: render previously calculated output
 *****************************************************************************/
static void vout_Render( vout_thread_t *p_vout, picture_t *p_pic )
{
    ;
}

/*****************************************************************************
 * vout_Display: displays previously rendered output
 *****************************************************************************
 * This function sends the currently rendered image to the display.
 *****************************************************************************/
static void vout_Display( vout_thread_t *p_vout, picture_t *p_pic )
{
    OSErr err;
    CodecFlags flags;

    if( ( err = DecompressSequenceFrameS( 
                    p_vout->p_sys->i_seq,
                    p_pic->p_sys->p_info,
                    p_pic->p_sys->i_size,                    
                    codecFlagUseImageBuffer, &flags, nil ) != noErr ) )
    {
        msg_Err( p_vout, "DecompressSequenceFrameS failed: %d", err );
    }
}

/*****************************************************************************
 * CoSendRequest: send request to interface thread
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int CoSendRequest( vout_thread_t *p_vout, long i_request )
{
    NSArray *o_array;
    NSPortMessage *o_msg;
    struct vout_req_s req;
    struct vout_req_s *p_req = &req;
    NSAutoreleasePool *o_pool = [[NSAutoreleasePool alloc] init];
    NSPort *recvPort = [[NSPort port] retain];

    memset( &req, 0, sizeof(req) );
    req.i_type = i_request;
    req.p_vout = p_vout;

    req.o_lock = [[NSConditionLock alloc] initWithCondition: 0];

    o_array = [NSArray arrayWithObject:
        [NSData dataWithBytes: &p_req length: sizeof(void *)]];
    o_msg = [[NSPortMessage alloc]
        initWithSendPort: p_vout->p_sys->p_intf->p_sys->o_sendport
        receivePort: recvPort components: o_array]; 

    [o_msg sendBeforeDate: [NSDate distantPast]];

    [req.o_lock lockWhenCondition: 1];
    [req.o_lock unlock];

    [o_msg release];
    [req.o_lock release];

    [recvPort release];
    [o_pool release];

    return( !req.i_result );
}

/*****************************************************************************
 * CoCreateWindow: create new window 
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int CoCreateWindow( vout_thread_t *p_vout )
{
    if( CoSendRequest( p_vout, VOUT_REQ_CREATE_WINDOW ) )
    {
        msg_Err( p_vout, "CoSendRequest (CREATE_WINDOW) failed" );
        return( 1 );
    }

    return( 0 );
}

/*****************************************************************************
 * CoDestroyWindow: destroy window 
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int CoDestroyWindow( vout_thread_t *p_vout )
{
    if( !p_vout->p_sys->b_mouse_pointer_visible )
    {
        CGDisplayShowCursor( kCGDirectMainDisplay );
        p_vout->p_sys->b_mouse_pointer_visible = 1;
    }

    if( CoSendRequest( p_vout, VOUT_REQ_DESTROY_WINDOW ) )
    {
        msg_Err( p_vout, "CoSendRequest (DESTROY_WINDOW) failed" );
        return( 1 );
    }

    return( 0 );
}

/*****************************************************************************
 * CoToggleFullscreen: toggle fullscreen 
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int CoToggleFullscreen( vout_thread_t *p_vout )
{
    QTDestroySequence( p_vout );

    if( CoDestroyWindow( p_vout ) )
    {
        msg_Err( p_vout, "unable to destroy window" );
        return( 1 );
    }
    
    p_vout->b_fullscreen = !p_vout->b_fullscreen;

    if( p_vout->b_fullscreen )
    {
        HideMenuBar();
    }
    else
    {
        ShowMenuBar();
    }

    if( CoCreateWindow( p_vout ) )
    {
        msg_Err( p_vout, "unable to create window" );
        return( 1 );
    }

    SetPort( p_vout->p_sys->p_qdport );
    QTScaleMatrix( p_vout );

    if( QTCreateSequence( p_vout ) )
    {
        msg_Err( p_vout, "unable to create sequence" );
        return( 1 ); 
    } 

    return( 0 );
}

/*****************************************************************************
 * QTScaleMatrix: scale matrix 
 *****************************************************************************/
static void QTScaleMatrix( vout_thread_t *p_vout )
{
    Rect s_rect;
    int i_width, i_height;
    Fixed factor_x, factor_y;
    int i_offset_x = 0;
    int i_offset_y = 0;

    GetPortBounds( p_vout->p_sys->p_qdport, &s_rect );

    i_width = s_rect.right - s_rect.left;
    i_height = s_rect.bottom - s_rect.top;

    if( i_height * p_vout->output.i_aspect < i_width * VOUT_ASPECT_FACTOR )
    {
        int i_adj_width = i_height * p_vout->output.i_aspect /
                          VOUT_ASPECT_FACTOR;

        factor_x = FixDiv( Long2Fix( i_adj_width ),
                           Long2Fix( p_vout->output.i_width ) );
        factor_y = FixDiv( Long2Fix( i_height ),
                           Long2Fix( p_vout->output.i_height ) );

        i_offset_x = (i_width - i_adj_width) / 2;
    }
    else
    {
        int i_adj_height = i_width * VOUT_ASPECT_FACTOR /
                           p_vout->output.i_aspect;

        factor_x = FixDiv( Long2Fix( i_width ),
                           Long2Fix( p_vout->output.i_width ) );
        factor_y = FixDiv( Long2Fix( i_adj_height ),
                           Long2Fix( p_vout->output.i_height ) );

        i_offset_y = (i_height - i_adj_height) / 2;
    }

    SetIdentityMatrix( p_vout->p_sys->p_matrix );

    ScaleMatrix( p_vout->p_sys->p_matrix,
                 factor_x, factor_y,
                 Long2Fix(0), Long2Fix(0) );            

    TranslateMatrix( p_vout->p_sys->p_matrix, 
                     Long2Fix(i_offset_x), 
                     Long2Fix(i_offset_y) );
}

/*****************************************************************************
 * QTCreateSequence: create a new sequence 
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int QTCreateSequence( vout_thread_t *p_vout )
{
    OSErr err;
    ImageDescriptionPtr p_descr;

    HLock( (Handle)p_vout->p_sys->h_img_descr );
    p_descr = *p_vout->p_sys->h_img_descr;

    p_descr->idSize = sizeof(ImageDescription);
    p_descr->cType = p_vout->p_sys->i_codec;
    p_descr->version = 1;
    p_descr->revisionLevel = 0;
    p_descr->vendor = 'appl';
    p_descr->width = p_vout->output.i_width;
    p_descr->height = p_vout->output.i_height;
    p_descr->hRes = Long2Fix(72);
    p_descr->vRes = Long2Fix(72);
    p_descr->spatialQuality = codecLosslessQuality;
    p_descr->frameCount = 1;
    p_descr->clutID = -1;
    p_descr->dataSize = 0;
    p_descr->depth = 12;

    HUnlock( (Handle)p_vout->p_sys->h_img_descr );

    if( ( err = DecompressSequenceBeginS( 
                              &p_vout->p_sys->i_seq,
                              p_vout->p_sys->h_img_descr,
                              NULL, 0,
                              p_vout->p_sys->p_qdport,
                              NULL, NULL,
                              p_vout->p_sys->p_matrix,
                              0, NULL,
                              codecFlagUseImageBuffer,
                              codecLosslessQuality,
                              p_vout->p_sys->img_dc ) ) )
    {
        msg_Err( p_vout, "DecompressSequenceBeginS failed: %d", err );
        return( 1 );
    }

    return( 0 );
}

/*****************************************************************************
 * QTDestroySequence: destroy sequence 
 *****************************************************************************/
static void QTDestroySequence( vout_thread_t *p_vout )
{
    CDSequenceEnd( p_vout->p_sys->i_seq );
}

/*****************************************************************************
 * QTNewPicture: allocate a picture
 *****************************************************************************
 * Returns 0 on success, 1 otherwise
 *****************************************************************************/
static int QTNewPicture( vout_thread_t *p_vout, picture_t *p_pic )
{
    int i_width  = p_vout->output.i_width;
    int i_height = p_vout->output.i_height;

    /* We know the chroma, allocate a buffer which will be used
     * directly by the decoder */
    p_pic->p_sys = malloc( sizeof( picture_sys_t ) );

    if( p_pic->p_sys == NULL )
    {
        return( -1 );
    }

    switch( p_vout->output.i_chroma )
    {
        case FOURCC_I420:

            p_pic->p_sys->p_info = (void *)&p_pic->p_sys->pixmap_i420;
            p_pic->p_sys->i_size = sizeof(PlanarPixmapInfoYUV420);

            /* Allocate the memory buffer */
            p_pic->p_data = vlc_memalign( &p_pic->p_data_orig,
                                          16, i_width * i_height * 3 / 2 );

            /* Y buffer */
            p_pic->Y_PIXELS = p_pic->p_data; 
            p_pic->p[Y_PLANE].i_lines = i_height;
            p_pic->p[Y_PLANE].i_pitch = i_width;
            p_pic->p[Y_PLANE].i_pixel_bytes = 1;
            p_pic->p[Y_PLANE].b_margin = 0;

            /* U buffer */
            p_pic->U_PIXELS = p_pic->Y_PIXELS + i_height * i_width;
            p_pic->p[U_PLANE].i_lines = i_height / 2;
            p_pic->p[U_PLANE].i_pitch = i_width / 2;
            p_pic->p[U_PLANE].i_pixel_bytes = 1;
            p_pic->p[U_PLANE].b_margin = 0;

            /* V buffer */
            p_pic->V_PIXELS = p_pic->U_PIXELS + i_height * i_width / 4;
            p_pic->p[V_PLANE].i_lines = i_height / 2;
            p_pic->p[V_PLANE].i_pitch = i_width / 2;
            p_pic->p[V_PLANE].i_pixel_bytes = 1;
            p_pic->p[V_PLANE].b_margin = 0;

            /* We allocated 3 planes */
            p_pic->i_planes = 3;

#define P p_pic->p_sys->pixmap_i420
            P.componentInfoY.offset = (void *)p_pic->Y_PIXELS
                                       - p_pic->p_sys->p_info;
            P.componentInfoCb.offset = (void *)p_pic->U_PIXELS
                                        - p_pic->p_sys->p_info;
            P.componentInfoCr.offset = (void *)p_pic->V_PIXELS
                                        - p_pic->p_sys->p_info;

            P.componentInfoY.rowBytes = i_width;
            P.componentInfoCb.rowBytes = i_width / 2;
            P.componentInfoCr.rowBytes = i_width / 2;
#undef P

            break;

    default:
        /* Unknown chroma, tell the guy to get lost */
        free( p_pic->p_sys );
        msg_Err( p_vout, "never heard of chroma 0x%.8x (%4.4s)",
                 p_vout->output.i_chroma, (char*)&p_vout->output.i_chroma );
        p_pic->i_planes = 0;
        return( -1 );
    }

    return( 0 );
}

/*****************************************************************************
 * QTFreePicture: destroy a picture allocated with QTNewPicture
 *****************************************************************************/
static void QTFreePicture( vout_thread_t *p_vout, picture_t *p_pic )
{
    switch( p_vout->output.i_chroma )
    {
        case FOURCC_I420:
            free( p_pic->p_data_orig );
            break;
    }

    free( p_pic->p_sys );
}

/*****************************************************************************
 * VLCWindow implementation
 *****************************************************************************/
@implementation VLCWindow

- (void)setVout:(vout_thread_t *)_p_vout
{
    p_vout = _p_vout;
}

- (void)toggleFullscreen
{
    p_vout->i_changes |= VOUT_FULLSCREEN_CHANGE;
}

- (BOOL)isFullscreen
{
    return( p_vout->b_fullscreen );
}

- (BOOL)canBecomeKeyWindow
{
    return( YES );
}

- (void)keyDown:(NSEvent *)o_event
{
    unichar key = 0;

    if( [[o_event characters] length] )
    {
        key = [[o_event characters] characterAtIndex: 0];
    }

    switch( key )
    {
        case 'f': case 'F':
            [self toggleFullscreen];
            break;

        case (unichar)0x1b: /* escape */
            if( [self isFullscreen] )
            {
                [self toggleFullscreen];
            }
            break;

        case 'q': case 'Q':
            p_vout->p_vlc->b_die = 1;
            break;

        default:
            [super keyDown: o_event];
            break;
    }
}

@end

/*****************************************************************************
 * VLCView implementation
 *****************************************************************************/
@implementation VLCView

- (void)setVout:(vout_thread_t *)_p_vout
{
    p_vout = _p_vout;
}

- (void)drawRect:(NSRect)rect
{
    [[NSColor blackColor] set];
    NSRectFill( rect );
    [super drawRect: rect];

    p_vout->i_changes |= VOUT_SIZE_CHANGE;
}

@end
