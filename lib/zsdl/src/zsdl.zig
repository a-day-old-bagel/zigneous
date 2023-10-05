const options = @import("zsdl_options");

const sdl3 = @import("sdl3.zig");
pub usingnamespace sdl3;

test {
    const testing = @import("std").testing;
    testing.refAllDeclsRecursive(sdl3);
}
