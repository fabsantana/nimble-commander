//
//  OperationStats.h
//  Directories
//
//  Created by Pavel Dogurevich on 21.03.13.
//  Copyright (c) 2013 Michael G. Kazakov. All rights reserved.
//

class OperationStats
{
public:
    OperationStats();
    ~OperationStats();
    
    void SetMaxValue(uint64_t _max_value);
    uint64_t GetMaxValue() const;
    
    void SetValue(uint64_t _value);
    void AddValue(uint64_t _value);
    uint64_t GetValue() const;
    
    // Retruns value in range from 0 to 1. Equals to current value divided by max value.
    float GetProgress() const;
    
    void SetCurrentItem(string _item);
    string GetCurrentItem() const;
    void SetOnCurrentItemChanged(function<void()> _callback); // _callback will be called from main thread
    
    void StartTimeTracking();
    // Pauses the time tracking. Keeps track of how many times it was invoked.
    // To resume tracking, ResumeTimeTracking must be called the same number of times.
    void PauseTimeTracking();
    void ResumeTimeTracking();

    /**
     * Returns worked time in milliseconds.
     */
    milliseconds GetTime() const;
    
private:
    nanoseconds     m_StartTime{0};
    nanoseconds     m_PauseTime{0};
    volatile bool   m_Started{false};
    volatile int    m_Paused{0};
    atomic_ulong    m_Value{0};
    atomic_ulong    m_MaxValue{1};
    mutable mutex   m_Lock;

    string          m_CurrentItem;
    function<void()>m_OnCurrentItemChanged;
    
    OperationStats(const OperationStats&) = delete;
    void operator=(const OperationStats&) = delete;
};
