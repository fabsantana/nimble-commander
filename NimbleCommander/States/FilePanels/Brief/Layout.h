#pragma once

// 3 modes:
// - fixed widths for columns
//      setting: this width
// - fixed amount of columns
//      setting: amount of columns
// - dynamic widths of columns
//      settings: min width, max width, should be equal

struct PanelBriefViewColumnsLayout
{
    enum class Mode : signed char {
        FixedWidth      = 0,
        FixedAmount     = 1,
        DynamicWidth    = 2
    };
    short   fixed_mode_width    = 150;
    short   fixed_amount_value  = 3;
    short   dynamic_width_min   = 100;
    short   dynamic_width_max   = 300;
    bool    dynamic_width_equal = false;
    Mode    mode                = Mode::FixedAmount;
    bool operator ==(const PanelBriefViewColumnsLayout& _rhs) const noexcept;
    bool operator !=(const PanelBriefViewColumnsLayout& _rhs) const noexcept;
};

