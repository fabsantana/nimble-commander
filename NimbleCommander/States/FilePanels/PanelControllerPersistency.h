// Copyright (C) 2018 Michael Kazakov. Subject to GNU General Public License version 3.
#pragma once

#include <Config/RapidJSON_fwd.h>

@class PanelController;

namespace nc::panel {
    
struct ControllerStateEncoding
{
    enum Options {
        EncodeDataOptions   =  1,
        EncodeViewOptions   =  2,
        EncodeContentState  =  4,
            
        EncodeNothing       =  0,
        EncodeEverything    = -1
    };
};
  
// encoders / decoders assume beging called from the main thread, will assert() otherwise
    
class ControllerStateJSONEncoder
{
public:
    ControllerStateJSONEncoder(PanelController *_panel);
    
    config::Value Encode(ControllerStateEncoding::Options _options);
    
private:
    PanelController *m_Panel;
};

class ControllerStateJSONDecoder
{
public:
    ControllerStateJSONDecoder(PanelController *_panel);
    
    void Decode(const config::Value &_state);
    
private:
    PanelController *m_Panel;
};
    
}
