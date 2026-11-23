#import <Cocoa/Cocoa.h>
#include "LegacyAbi.h"
#include <cassert>
#include <cstdio>
#include <dlfcn.h>

using camel::legacy::Dispatch;
using camel::legacy::Effect;

static intptr_t host(Effect *, int32_t opcode, int32_t, intptr_t, void *, float)
{
    return opcode == 1 ? 2400 : 0;
}

static NSEvent *mouseEvent(NSView *view, NSEventType type, double y)
{
    const auto point = [view convertPoint:NSMakePoint(80, y) toView:nil];
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0
        windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    @autoreleasepool {
        [NSApplication sharedApplication];
        void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
        const auto create = reinterpret_cast<Effect *(*)(Dispatch)>(dlsym(library, "VSTPluginMain"));
        assert(create);
        Effect *plugin = create(host);
        assert(plugin);
        NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 484)];
        assert(plugin->dispatcher(plugin, 14, 0, 0, (__bridge void *)parent, 0));
        assert(parent.subviews.count == 1);
        NSView *editor = parent.subviews.firstObject;

        const float initial = plugin->getParameter(plugin, 0);
        [editor mouseDown:mouseEvent(editor, NSEventTypeLeftMouseDown, 180)];
        [editor mouseDragged:mouseEvent(editor, NSEventTypeLeftMouseDragged, 160)];
        [editor mouseUp:mouseEvent(editor, NSEventTypeLeftMouseUp, 160)];
        assert(plugin->getParameter(plugin, 0) > initial);

        plugin->dispatcher(plugin, 15, 0, 0, nullptr, 0);
        assert(parent.subviews.count == 0);
        plugin->dispatcher(plugin, 1, 0, 0, nullptr, 0);
    }
}
