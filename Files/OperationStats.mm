//
//  OperationStats.m
//  Directories
//
//  Created by Pavel Dogurevich on 21.03.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

#import "OperationStats.h"
#import "Common.h"

OperationStats::OperationStats()
{
}

OperationStats::~OperationStats()
{
}

void OperationStats::SetMaxValue(uint64_t _max_value)
{
//    assert(_max_value);
    assert(m_Value <= _max_value);
    
    m_MaxValue = _max_value;
}

uint64_t OperationStats::GetMaxValue() const
{
    return m_MaxValue;
}

void OperationStats::SetValue(uint64_t _value)
{
    m_Value = _value;
    assert(m_Value <= m_MaxValue);
}

void OperationStats::AddValue(uint64_t _value)
{
    m_Value += _value;
    assert(m_Value <= m_MaxValue);
}

uint64_t OperationStats::GetValue() const
{
    return m_Value;
}

float OperationStats::GetProgress() const
{
    return (float)m_Value/m_MaxValue;
}

void OperationStats::SetCurrentItem(const char *_item)
{
    m_CurrentItem = _item;
    m_CurrentItemChanged = true;
}

const char *OperationStats::GetCurrentItem() const
{
    return m_CurrentItem;
}

bool OperationStats::IsCurrentItemChanged()
{
    bool changed = m_CurrentItemChanged;
    if (changed) m_CurrentItemChanged = false;
    return changed;
}

void OperationStats::StartTimeTracking()
{
    lock_guard<mutex> lock(m_Lock);
    assert(!m_Started);
    m_StartTime = machtime();
    if (m_Paused)
        m_PauseTime = m_StartTime;
    m_Started = true;
}

void OperationStats::PauseTimeTracking()
{
    lock_guard<mutex> lock(m_Lock);
    if (++m_Paused == 1)
        m_PauseTime = machtime();
}

void OperationStats::ResumeTimeTracking()
{
    lock_guard<mutex> lock(m_Lock);
    assert(m_Paused >= 1);
    if (--m_Paused == 0) {
        auto pause_duration = machtime() - m_PauseTime;
        m_StartTime += pause_duration;
    }
}

milliseconds OperationStats::GetTime() const
{
    lock_guard<mutex> lock(m_Lock);
    nanoseconds time;
    if (!m_Started)
        time = 0ns;
    else if (m_Paused)
        time = m_PauseTime - m_StartTime;
    else
        time = machtime() - m_StartTime;

    return duration_cast<milliseconds>(time);
}
