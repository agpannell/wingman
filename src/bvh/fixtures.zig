//! Small authored BVH controls. Values are literal independent inputs, not production-generated
//! expected data. No external motion-capture corpus is embedded in the package.

pub const simple =
    \\HIERARCHY
    \\ROOT Hips
    \\{
    \\ OFFSET 1 2 3
    \\ CHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation
    \\ JOINT Knee
    \\ {
    \\  OFFSET 0 4 0
    \\  CHANNELS 3 Xrotation Yrotation Zrotation
    \\  End Site { OFFSET 0 2 0 }
    \\ }
    \\}
    \\MOTION
    \\Frames: 2
    \\Frame Time: 0.125
    \\1 2 3 90 0 0 0 90 0
    \\-1 -2 -3 0 90 0 45 0 -45
;

pub const forest =
    "HIERARCHY\nROOT MOTION { OFFSET 0 1 0 CHANNELS 0\n" ++
    " JOINT ROOT { OFFSET 2 0 0 CHANNELS 6 Zrotation Xposition Yrotation Zposition " ++
    "Xrotation Yposition\n  End Site { OFFSET 0 0 3 }\n }\n End Site { OFFSET -1 0 0 }\n}\n" ++
    "ROOT ROOT { OFFSET 9 8 7 CHANNELS 0\n" ++
    " JOINT mixamorig:JOINT { OFFSET 0 0 0 CHANNELS 1 Xposition }\n}\nMOTION\nFrames: 1\n" ++
    "Frame Time: 0.25\n30 1 20 2 10 3 4";
