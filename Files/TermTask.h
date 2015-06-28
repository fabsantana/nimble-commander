//
//  TermTask.h
//  Files
//
//  Created by Michael G. Kazakov on 28/06/15.
//  Copyright (c) 2015 Michael G. Kazakov. All rights reserved.
//

#pragma once

class TermTask
{
public:
    TermTask();
    ~TermTask(); // NO virtual here
    
    
    // calling this method from a callback itself will cause a guaranteed deadlock
    void SetOnChildOutput( function<void(const void *_d, size_t _sz)> _callback );
    
    
protected:
    void DoCalloutOnChildOutput( const void *_d, size_t _sz  );
    
    
    
    static int SetupTermios(int _fd);
    
    static int SetTermWindow(int _fd,
                      unsigned short _chars_width,
                      unsigned short _chars_height,
                      unsigned short _pix_width = 0,
                      unsigned short _pix_height = 0);
    
    static void SetupHandlesAndSID(int _slave_fd);
    
    static const map<string, string> &BuildEnv();
    static void SetEnv(const map<string, string>& _env);
    
    mutable mutex m_Lock;
private:    
    function<void(const void *_d, size_t _sz)>  m_OnChildOutput;
    mutex                                       m_OnChildOutputLock;
    
};