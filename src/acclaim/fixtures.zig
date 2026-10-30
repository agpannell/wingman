//! Independent authored controls; no third-party captures are embedded here.
pub const skeleton =
    \\:version 1.10
    \\:name authored
    \\:units
    \\ mass 1
    \\ length 2
    \\ angle deg
    \\:documentation
    \\ Declaration order differs from hierarchy traversal.
    \\:root
    \\ order TZ TX TY RZ RX RY
    \\ axis ZYX
    \\ position 1 2 3
    \\ orientation 0 0 90
    \\:bonedata
    \\begin
    \\ id 42
    \\ name tip
    \\ direction 0 0 1
    \\ length 3
    \\ axis 0 0 45 YZX
    \\ dof ry rx
    \\ limits (-20 20) (-inf inf)
    \\end
    \\begin
    \\ id 7
    \\ name base
    \\ direction 1 0 0
    \\ length 2
    \\ axis 0 90 0 XZY
    \\ dof rz
    \\ limits (0 10)
    \\end
    \\begin
    \\ id 91
    \\ name fixed
    \\ direction 0 1 0
    \\ length 1
    \\ axis 0 0 0 XYZ
    \\end
    \\:hierarchy
    \\begin
    \\ root base
    \\ base fixed
    \\ fixed tip
    \\end
;

pub const motion =
    \\# authored complete samples
    \\:FULLY-SPECIFIED
    \\:DEGREES
    \\1
    \\base 9
    \\root 1 2 3 4 5 6
    \\tip 7 8
    \\3
    \\tip 17 18
    \\base 19
    \\root 11 12 13 14 15 16
;
