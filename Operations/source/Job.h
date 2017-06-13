#pragma once

#include <atomic>
#include <functional>
#include <mutex>

#include "Statistics.h"


namespace nc::ops
{

class Job
{
public:
    Job();
    virtual ~Job();

    void Run();
    void Stop();
    
    bool IsRunning() const noexcept;
    bool IsStopped() const noexcept;
    bool IsCompleted() const noexcept;

    void SetFinishCallback( std::function<void()> _callback );
    
    class Statistics &Statistics();
    const  class Statistics &Statistics() const;
    
protected:
    void SetCompleted();
    void Execute();
    virtual void Perform();
    virtual void OnStopped();

private:
    std::atomic_bool m_IsRunning;
    std::atomic_bool m_IsCompleted;
    std::atomic_bool m_IsStopped;
    
    std::function<void()> m_OnFinish;
    std::mutex m_OnFinishLock;
    
    class Statistics      m_Stats;
};

}
