//
//  TermView.m
//  TermPlays
//
//  Created by Michael G. Kazakov on 17.11.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "TermView.h"
#import "OrthodoxMonospace.h"
#import "FontCache.h"
#import "TermScreen.h"
#import "TermParser.h"
#import "Common.h"

struct SelPoint
{
    int x;
    int y;
    inline bool operator > (const SelPoint&_r) const { return (y > _r.y) || (y == _r.y && x >  _r.x); }
    inline bool operator >=(const SelPoint&_r) const { return (y > _r.y) || (y == _r.y && x >= _r.x); }
    inline bool operator < (const SelPoint&_r) const { return !(*this >= _r); }
    inline bool operator <=(const SelPoint&_r) const { return !(*this >  _r); }
    inline bool operator ==(const SelPoint&_r) const { return y == _r.y && x == _r.x; }
    inline bool operator !=(const SelPoint&_r) const { return y != _r.y || x != _r.x; }
};

static const DoubleColor& TermColorToDoubleColor(int _color)
{
    static const DoubleColor colors[16] = {
        {  0./ 255.,   0./ 255.,   0./ 255., 1.}, // Black
        {153./ 255.,   0./ 255.,   0./ 255., 1.}, // Red
        {  0./ 255., 166./ 255.,   0./ 255., 1.}, // Green
        {153./ 255., 153./ 255.,   0./ 255., 1.}, // Yellow
        {  0./ 255.,   0./ 255., 178./ 255., 1.}, // Blue
        {178./ 255.,   0./ 255., 178./ 255., 1.}, // Magenta
        {  0./ 255., 166./ 255., 178./ 255., 1.}, // Cyan
        {191./ 255., 191./ 255., 191./ 255., 1.}, // White
        {102./ 255., 102./ 255., 102./ 255., 1.}, // Bright Black
        {229./ 255.,   0./ 255.,   0./ 255., 1.}, // Bright Red
        {  0./ 255., 217./ 255.,   0./ 255., 1.}, // Bright Green
        {229./ 255., 229./ 255.,   0./ 255., 1.}, // Bright Yellow
        {  0./ 255.,   0./ 255., 255./ 255., 1.}, // Bright Blue
        {229./ 255.,   0./ 255., 229./ 255., 1.}, // Bright Magenta
        {  0./ 255., 229./ 255., 229./ 255., 1.}, // Bright Cyan
        {229./ 255., 229./ 255., 229./ 235., 1.}  // Bright White
    };
    assert(_color >= 0 && _color <= 15);
    return colors[_color];
}

static const DoubleColor g_BackgroundColor = {0., 0., 0., 1.};
static const DoubleColor g_SelectionColor = {0.1, 0.2, 1.0, 0.7};

static inline bool IsBoxDrawingCharacter(unsigned short _ch)
{
    return _ch >= 0x2500 && _ch <= 0x257F;
}

@implementation TermView
{
    shared_ptr<FontCache> m_FontCache;
    TermScreen     *m_Screen;
    TermParser     *m_Parser;
    void          (^m_RawTaskFeed)(const void* _d, int _sz);
    
    int             m_LastScreenFSY;
    
    bool            m_HasSelection;
    SelPoint        m_SelStart;
    SelPoint        m_SelEnd;
}

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code here.
        CTFontRef font = CTFontCreateWithName( (CFStringRef) @"Menlo-Regular", 13, 0);
        m_FontCache = FontCache::FontCacheFromFont(font);
        CFRelease(font);
        m_LastScreenFSY = 0;
        m_HasSelection = false;
    }
    return self;
}

- (BOOL)isFlipped
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

-(BOOL) isOpaque
{
	return YES;
}

- (void)resetCursorRects
{
    [self addCursorRect:self.frame cursor:[NSCursor IBeamCursor]];
}

- (FontCache*) FontCache
{
    return m_FontCache.get();
}

- (void) AttachToScreen:(TermScreen*)_scr
{
    m_Screen = _scr;
}

- (void) AttachToParser:(TermParser*)_par
{
    m_Parser = _par;
}

- (void) setRawTaskFeed:(void(^)(const void* _d, int _sz))_feed
{
    m_RawTaskFeed = _feed;
}

- (void)keyDown:(NSEvent *)event
{
    NSString*  const character = [event charactersIgnoringModifiers];
    if ( [character length] == 1 )
        m_HasSelection = false;

    m_Parser->ProcessKeyDown(event);
    [self scrollToBottom];
}

- (void)adjustSizes:(bool)_mandatory
{
    int fsy = m_Screen->Height() + m_Screen->ScrollBackLinesCount();
    if(fsy == m_LastScreenFSY && _mandatory == false)
        return;
    
    m_LastScreenFSY = fsy;
    
    double sx = self.frame.size.width;
    double sy = fsy * m_FontCache->Height();
    
    double rest = [self.superview frame].size.height -
        floor([self.superview frame].size.height / m_FontCache->Height()) * m_FontCache->Height();
    
    [self setFrame: NSMakeRect(0, 0, sx, sy + rest)];
    
    [self scrollToBottom];
}

- (void) scrollToBottom
{
    [((NSClipView*)self.superview) scrollToPoint:NSMakePoint(0,
                                              self.frame.size.height - ((NSScrollView*)self.superview.superview).contentSize.height)];
}

- (void)drawRect:(NSRect)dirtyRect
{
	[super drawRect:dirtyRect];
	
    // Drawing code here.
    CGContextRef context = (CGContextRef) [[NSGraphicsContext currentContext] graphicsPort];
    oms::SetFillColor(context, g_BackgroundColor);
    CGContextFillRect(context, NSRectToCGRect(dirtyRect));
    
    if(!m_Screen)
        return;
    
/*    static uint64_t last_redraw = GetTimeInNanoseconds();
    uint64_t now = GetTimeInNanoseconds();
    NSLog(@"%llu", (now - last_redraw)/1000000);
    last_redraw = now;*/
    
//    MachTimeBenchmark tmb;
    
    int line_start = floor([self.superview bounds].origin.y / m_FontCache->Height());
    int line_end   = line_start + ceil(NSHeight(self.superview.bounds) / m_FontCache->Height());
    
    m_Screen->Lock();
    
//    oms::SetParamsForUserASCIIArt(context, m_FontCache);
    oms::SetParamsForUserReadableText(context, m_FontCache.get());
    CGContextSetShouldSmoothFonts(context, true);

    for(int i = line_start; i < line_end; ++i)
    {
        
        if(i < m_Screen->ScrollBackLinesCount())
        {
            // scrollback
            auto *line = m_Screen->GetScrollBackLine(i);
            if(line)
                [self DrawLine:line
                          at_y:i
                         sel_y:i - m_Screen->ScrollBackLinesCount()
                       context:context
                     cursor_at:-1];
        }
        else
        {
            // real screen
            auto *line = m_Screen->GetScreenLine(i - m_Screen->ScrollBackLinesCount());
            if(line)
            {
                if(m_Screen->CursorY() != i - m_Screen->ScrollBackLinesCount())
                    [self DrawLine:line
                              at_y:i
                             sel_y:i - m_Screen->ScrollBackLinesCount()
                           context:context
                         cursor_at:-1];
                else
                    [self DrawLine:line
                              at_y:i
                             sel_y:i - m_Screen->ScrollBackLinesCount()
                           context:context
                         cursor_at:m_Screen->CursorX()];
            }
        }
    }
    
    m_Screen->Unlock();
    
//    tmb.Reset("drawn in: ");
    
}

- (void) DrawLine:(const vector<TermScreen::Space> *)_line
             at_y:(int)_y
            sel_y:(int)_sel_y
          context:(CGContextRef)_context
        cursor_at:(int)_cur_x
{
    // draw backgrounds
    DoubleColor curr_c = {-1, -1, -1, -1};
    int x = 0;
    for(int n = 0; n < _line->size(); ++n)
    {
        TermScreen::Space char_space = (*_line)[n];
        const DoubleColor &c = TermColorToDoubleColor(char_space.reverse ? char_space.foreground : char_space.background);
        if(c != g_BackgroundColor)
        {
            if(c != curr_c)
                oms::SetFillColor(_context, curr_c = c);
        
            CGContextFillRect(_context,
                            CGRectMake(x * m_FontCache->Width(),
                                        _y * m_FontCache->Height(),
                                        m_FontCache->Width(),
                                        m_FontCache->Height()));
        }
        ++x;
    }
    
    // draw selection if it's here
    if(m_HasSelection)
    {
        CGRect rc = {{-1, -1}, {0, 0}};
        if(m_SelStart.y == m_SelEnd.y && m_SelStart.y == _sel_y)
            rc = CGRectMake(m_SelStart.x * m_FontCache->Width(),
                            _y * m_FontCache->Height(),
                            (m_SelEnd.x - m_SelStart.x) * m_FontCache->Width(),
                            m_FontCache->Height());
        else if(_sel_y < m_SelEnd.y && _sel_y > m_SelStart.y)
            rc = CGRectMake(0,
                            _y * m_FontCache->Height(),
                            self.frame.size.width,
                            m_FontCache->Height());
        else if(_sel_y == m_SelStart.y)
            rc = CGRectMake(m_SelStart.x * m_FontCache->Width(),
                            _y * m_FontCache->Height(),
                            self.frame.size.width - m_SelStart.x * m_FontCache->Width(),
                            m_FontCache->Height());
        else if(_sel_y == m_SelEnd.y)
            rc = CGRectMake(0,
                            _y * m_FontCache->Height(),
                            m_SelEnd.x * m_FontCache->Width(),
                            m_FontCache->Height());
        
        if(rc.origin.x >= 0)
        {
            oms::SetFillColor(_context, g_SelectionColor);
            CGContextFillRect(_context, rc);
        }
        
    }
    
    // draw cursor if it's here
    if(_cur_x >= 0)
    {
        CGContextSetRGBFillColor(_context, 0.4, 0.4, 0.4, 1.);
        CGContextFillRect(_context,
                        CGRectMake(_cur_x * m_FontCache->Width(),
                                    _y * m_FontCache->Height(),
                                    m_FontCache->Width(),
                                    m_FontCache->Height()));
    }
    
    // draw glyphs
    x = 0;
    curr_c = {-1, -1, -1, -1};
    bool is_aa = true;
    CGContextSetShouldAntialias(_context, is_aa);
    
    for(int n = 0; n < _line->size(); ++n)
    {
        TermScreen::Space char_space = (*_line)[n];
        int foreground = char_space.foreground;
        if(char_space.intensity)
            foreground += 8;
        
        if(char_space.l != 0 &&
           char_space.l != 32 &&
           char_space.l != TermScreen::MultiCellGlyph
           )
        {
            const DoubleColor &c = TermColorToDoubleColor(char_space.reverse ? char_space.background : foreground);
            if(c != curr_c)
                oms::SetFillColor(_context, curr_c = c);
            
            bool should_aa = !IsBoxDrawingCharacter(char_space.l);
            if(should_aa != is_aa)
                CGContextSetShouldAntialias(_context, is_aa = should_aa);
            
            oms::DrawSingleUniCharXY(char_space.l, x, _y, _context, m_FontCache.get());
            
            if(char_space.c1 != 0)
                oms::DrawSingleUniCharXY(char_space.c1, x, _y, _context, m_FontCache.get());
            if(char_space.c2 != 0)
                oms::DrawSingleUniCharXY(char_space.c2, x, _y, _context, m_FontCache.get());
        }        
        
        if(char_space.underline)
        {
            /* NEED REAL UNDERLINE POSITION HERE !!! */
            // need to set color here?
            CGRect rc;
            rc.origin.x = x * m_FontCache->Width();
            rc.origin.y = _y * m_FontCache->Height() + m_FontCache->Height() - 1;
            rc.size.width = m_FontCache->Width();
            rc.size.height = 1;
            CGContextFillRect(_context, rc);
        }
        
        ++x;
    }
}

- (NSRect)adjustScroll:(NSRect)proposedVisibleRect
{
    proposedVisibleRect.origin.y = (int)(proposedVisibleRect.origin.y/m_FontCache->Height() + 0.5) * m_FontCache->Height();
    return proposedVisibleRect;
}

/**
 * return predicted character position regarding current font setup
 * y values [0...+y should be treated as rows in real terminal screen
 * y values -y...0) should be treated as rows in backscroll. y=-1 mean the closes to real screen row
 * x values are trivial - float x position divided by font's width
 * returned points may not correlate with real lines' lengths or scroll sizes, so they need to be treated carefully
 */
- (SelPoint)ProjectPoint:(NSPoint)_point
{
    int line_predict = floor(_point.y / m_FontCache->Height()) - m_Screen->ScrollBackLinesCount();
    int col_predict = floor(_point.x / m_FontCache->Width());
    return SelPoint{col_predict, line_predict};
}

- (void) mouseDown:(NSEvent *)_event
{

//    NSPoint pt = [m_View convertPoint:[event locationInWindow] fromView:nil];
//    [self ProjectPoint:[self convertPoint:[_event locationInWindow] fromView:nil]];
    [self HandleSelectionWithMouseDragging:_event];
}

- (void) HandleSelectionWithMouseDragging: (NSEvent*) event
{
    // TODO: not a precise selection modification. look at viewer, it has better implementation.
    
    bool modifying_existing_selection = ([event modifierFlags] & NSShiftKeyMask) ? true : false;
    NSPoint first_loc = [self convertPoint:[event locationInWindow] fromView:nil];
    
    while ([event type]!=NSLeftMouseUp)
    {
        NSPoint curr_loc = [self convertPoint:[event locationInWindow] fromView:nil];
        
        SelPoint start = [self ProjectPoint:first_loc];
        SelPoint end   = [self ProjectPoint:curr_loc];
        
        if(start > end)
            swap(start, end);
        
        
        if(modifying_existing_selection && m_HasSelection)
        {
            if(end > m_SelStart) {
                m_SelEnd = end;
                [self setNeedsDisplay:true];
            }
            else if(end < m_SelStart) {
                m_SelStart = end;
                [self setNeedsDisplay:true];
            }
        }
        else if(!m_HasSelection || m_SelEnd != end || m_SelStart != start)
        {
            m_HasSelection = true;
            m_SelStart = start;
            m_SelEnd = end;
            [self setNeedsDisplay:true];
        }

        event = [[self window] nextEventMatchingMask:(NSLeftMouseDraggedMask | NSLeftMouseUpMask)];
    }
}

- (void)copy:(id)sender
{
    if(!m_HasSelection)
        return;
    
    if(m_SelStart == m_SelEnd)
        return;
    
    vector<unsigned short> unichars;
    SelPoint curr = m_SelStart;
    while(true)
    {
        if(curr >= m_SelEnd) break;
        
        const vector<TermScreen::Space> *line = 0;
        if(curr.y < 0) line = m_Screen->GetScrollBackLine( m_Screen->ScrollBackLinesCount() + curr.y );
        else           line = m_Screen->GetScreenLine(curr.y);
        
        if(!line) {
            curr.y++;
            continue;
        }
        
        bool any_inserted = false;
        for(; curr.x < line->size() && ( (curr.y == m_SelEnd.y) ? (curr.x < m_SelEnd.x) : true); ++curr.x) {
            auto &sp = (*line)[curr.x];
            if(sp.l == TermScreen::MultiCellGlyph) continue;
            unichars.push_back(sp.l != 0 ? sp.l : ' ');
            if(sp.c1 != 0) unichars.push_back(sp.c1);
            if(sp.c2 != 0) unichars.push_back(sp.c2);
            any_inserted = true;
        }
    
        if(curr >= m_SelEnd)
            break;
        
        curr.y++;
        curr.x = 0;
        if(any_inserted) unichars.push_back(0x000A);
    }
    
    NSString *result = [NSString stringWithCharactersNoCopy:unichars.data() length:unichars.size()];
    NSPasteboard *pasteBoard = [NSPasteboard generalPasteboard];
    [pasteBoard clearContents];
    [pasteBoard declareTypes:[NSArray arrayWithObjects:NSStringPboardType, nil] owner:nil];
    [pasteBoard setString:result forType:NSStringPboardType];
}

- (IBAction)paste:(id)sender
{    
    NSPasteboard *paste_board = [NSPasteboard generalPasteboard];
    NSString *best_type = [paste_board availableTypeFromArray:[NSArray arrayWithObject:NSStringPboardType]];
    if(!best_type)
        return;
    
    NSString *text = [paste_board stringForType:NSStringPboardType];
    if(!text)
        return;
    
    const char* utf8str = [text UTF8String];
    size_t sz = strlen(utf8str);
    if(m_RawTaskFeed)
        m_RawTaskFeed(utf8str, (int)sz);
}

- (void)selectAll:(id)sender
{
    m_HasSelection = true;
    m_SelStart.y = -m_Screen->ScrollBackLinesCount();
    m_SelStart.x = 0;
    m_SelEnd.y = m_Screen->Height()-1;
    m_SelEnd.x = m_Screen->Width();
    [self setNeedsDisplay:true];
}

- (void)deselectAll:(id)sender
{
    m_HasSelection = false;
    [self setNeedsDisplay:true];
}


@end
