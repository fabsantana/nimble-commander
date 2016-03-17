//
//  BlinkingCaret.cpp
//  Files
//
//  Created by Michael G. Kazakov on 23/07/15.
//  Copyright (c) 2015 Michael G. Kazakov. All rights reserved.
//

#include "BlinkingCaret.h"

BlinkingCaret::BlinkingCaret( id<ViewWithFPSLimitedDrawer> _view, milliseconds _blink_time ):
    m_View( _view ),
    m_BlinkTime( _blink_time ),
    m_NextScheduleTime( 0 )
{
    if( !_view )
        throw logic_error("BlinkingCaret::BlinkingCaret _view can't be nil");
    if( _blink_time == 0ms )
        throw logic_error("BlinkingCaret::BlinkingCaret _blink_time can't be zero");
}

BlinkingCaret::~BlinkingCaret()
{
}

bool BlinkingCaret::Enabled() const
{
    return m_Enabled;
}

void BlinkingCaret::SetEnabled( bool _enabled )
{
    m_Enabled = _enabled;
}

bool BlinkingCaret::Visible() const
{
    if( !m_Enabled )
        return true;
    
    auto n = duration_cast<milliseconds>(machtime()) / m_BlinkTime;
    return n % 2 == 0;
}

void BlinkingCaret::ScheduleNextRedraw()
{
    if( !m_Enabled )
        return;
    
    auto mt = machtime();
    
    if( mt < m_NextScheduleTime )
        return;
    
    __weak id<ViewWithFPSLimitedDrawer> view = m_View;
    dispatch_to_main_queue_after( m_BlinkTime, [=]{
        if( id<ViewWithFPSLimitedDrawer> v = view )
            [v.fpsDrawer invalidate];
    });
    m_NextScheduleTime = mt + m_BlinkTime;
}
