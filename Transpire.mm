#import <Cocoa/Cocoa.h>
#include "LegacyAbi.h"
#include "ysfx.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <string>

using namespace camel::legacy;
namespace {
constexpr int width = 340, height = 484;
constexpr std::array<unsigned, 4> sliders{0, 1, 6, 9};
constexpr std::array<const char *, 4> names{"Attack", "Sustain", "Sensitivity", "Output"};
const char imageAnchor = 0;
using Host = Dispatch;
using Fx = std::unique_ptr<ysfx_t, decltype(&ysfx_free)>;
}
@class TranspireView;
namespace {
struct Instance {
    Effect effect{};
    Host host;
    Fx fx{nullptr, ysfx_free};
    std::mutex lock;
    std::array<std::atomic<float>, 4> values{};
    std::array<float, 4> applied{};
    std::array<ysfx_slider_curve_t, 4> curves{};
    TranspireView *view = nil;
    explicit Instance(Host callback) : host(callback) {}
};
Instance &instance(Effect *effect) { return *static_cast<Instance *>(effect->object); }
void apply(Instance &p)
{
    for (unsigned i = 0; i < sliders.size(); ++i) {
        const float value = p.values[i].load();
        if (value == p.applied[i]) continue;
        p.applied[i] = value;
        ysfx_slider_set_value(p.fx.get(), sliders[i], ysfx_normalized_to_ysfx_value(value, &p.curves[i]), true);
    }
}
}

@interface TranspireView : NSView
- (instancetype)initWithInstance:(Instance *)plugin;
- (void)stop;
@end

@implementation TranspireView {
    Instance *_plugin;
    NSTimer *_timer;
    std::array<uint32_t, width * height> _pixels;
    NSPoint _mouse;
    uint32_t _buttons;
    double _wheel;
}
- (instancetype)initWithInstance:(Instance *)plugin
{
    if ((self = [super initWithFrame:NSMakeRect(0, 0, width, height)])) {
        _plugin = plugin;
        ysfx_gfx_config_t config{};
        config.pixel_width = width;
        config.pixel_height = height;
        config.pixels = reinterpret_cast<uint8_t *>(_pixels.data());
        config.scale_factor = 1.0;
        {
            std::lock_guard guard(_plugin->lock);
            ysfx_gfx_setup(_plugin->fx.get(), &config);
        }
        __weak TranspireView *weakView = self;
        _timer = [NSTimer timerWithTimeInterval:1.0/30 repeats:YES block:^(NSTimer *) {
            [weakView setNeedsDisplay:YES];
        }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (void)stop { [_timer invalidate]; _timer = nil; [self removeFromSuperview]; }
- (BOOL)isFlipped { return YES; }
- (void)readEvent:(NSEvent *)event { _mouse = [self convertPoint:event.locationInWindow fromView:nil]; }
- (void)mouseDown:(NSEvent *)event { [self readEvent:event]; _buttons = 1; [self display]; }
- (void)mouseDragged:(NSEvent *)event { [self readEvent:event]; [self display]; }
- (void)mouseUp:(NSEvent *)event { [self readEvent:event]; _buttons = 0; [self display]; }
- (void)rightMouseDown:(NSEvent *)event { [self readEvent:event]; _buttons = 2; [self display]; }
- (void)rightMouseUp:(NSEvent *)event { [self readEvent:event]; _buttons = 0; [self display]; }
- (void)scrollWheel:(NSEvent *)event { [self readEvent:event]; _wheel += event.deltaY; [self display]; }
- (void)drawRect:(NSRect)rect
{
    (void)rect;
    auto &p = *_plugin;
    std::array<bool, 4> changed{};
    {
        std::lock_guard guard(p.lock);
        apply(p);
        ysfx_gfx_set_window_state(p.fx.get(), self.window.isKeyWindow, YES, YES);
        ysfx_gfx_update_mouse(p.fx.get(), 0, (int)_mouse.x, (int)_mouse.y, _buttons, _wheel, 0);
        _wheel = 0;
        ysfx_gfx_run(p.fx.get());
        for (unsigned i = 0; i < sliders.size(); ++i) {
            const float value = ysfx_ysfx_value_to_normalized(ysfx_slider_get_value(p.fx.get(), sliders[i]), &p.curves[i]);
            if (std::abs(value - p.applied[i]) <= 1e-6f) continue;
            float previous = p.applied[i];
            changed[i] = p.values[i].compare_exchange_strong(previous, value);
            p.applied[i] = value;
        }
    }
    for (unsigned i = 0; i < sliders.size(); ++i) {
        if (changed[i]) p.host(&p.effect, 0, i, 0, nullptr, p.values[i].load());
    }
    const auto provider = CGDataProviderCreateWithData(nullptr, _pixels.data(), sizeof(_pixels), nullptr);
    const auto colorSpace = CGColorSpaceCreateDeviceRGB();
    const auto image = CGImageCreate(width, height, 8, 32, width * 4, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, provider, nullptr, false, kCGRenderingIntentDefault);
    if (image) {
        const auto context = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0, height);
        CGContextScaleCTM(context, 1, -1);
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRestoreGState(context);
        CGImageRelease(image);
    }
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
}
@end

namespace {
void setParameter(Effect *effect, int32_t index, float value)
{
    if (index >= 0 && index < 4 && std::isfinite(value))
        instance(effect).values[index].store(std::clamp(value, 0.0f, 1.0f));
}
float getParameter(Effect *effect, int32_t index)
{
    return index >= 0 && index < 4 ? instance(effect).values[index].load() : 0;
}
void process(Effect *effect, float **inputs, float **outputs, int32_t frames)
{
    if (frames <= 0) return;
    auto &p = instance(effect);
    std::unique_lock guard(p.lock, std::try_to_lock);
    if (!guard) {
        for (int channel = 0; channel < 2; ++channel)
            if (outputs[channel] != inputs[channel])
                std::memmove(outputs[channel], inputs[channel], frames * sizeof(float));
        return;
    }
    apply(p);
    ysfx_process_float(p.fx.get(), inputs, outputs, 2, 2, frames);
}
intptr_t dispatch(Effect *effect, int32_t opcode, int32_t index, intptr_t value, void *data, float option)
{
    auto &p = instance(effect);
    switch (opcode) {
    case 0: return 1; // open
    case 1: [p.view stop]; delete &p; return 1;
    case 3: return 0; // get program
    case 5: if (data) std::strcpy(static_cast<char *>(data), "Default"); return 1;
    case 6: if (data) static_cast<char *>(data)[0] = 0; return 1;
    case 7:
        if (data && index >= 0 && index < 4)
            std::snprintf(static_cast<char *>(data), 8, "%.1f",
                ysfx_normalized_to_ysfx_value(getParameter(effect, index), &p.curves[index]));
        return 1;
    case 8:
        if (data && index >= 0 && index < 4) std::strcpy(static_cast<char *>(data), names[index]);
        return 1;
    case 10: { std::lock_guard guard(p.lock); ysfx_set_sample_rate(p.fx.get(), option); return 1; }
    case 11: { std::lock_guard guard(p.lock); ysfx_set_block_size(p.fx.get(), (uint32_t)value); return 1; }
    case 12: {
        if (value) { std::lock_guard guard(p.lock); ysfx_init(p.fx.get()); }
        return 1;
    }
    case 13: {
        static camel::legacy::Rect rect{0, 0, height, width};
        if (!data) return 0;
        *static_cast<camel::legacy::Rect **>(data) = &rect;
        return 1;
    }
    case 14: {
        if (!data) return 0;
        [p.view stop];
        p.view = [[TranspireView alloc] initWithInstance:&p];
        [(__bridge NSView *)data addSubview:p.view];
        return 1;
    }
    case 15: [p.view stop]; p.view = nil; return 1;
    case 26: return index >= 0 && index < 4; // can automate
    case 35: return 1; // effect category
    case 45: case 48: if (data) std::strcpy(static_cast<char *>(data), "Transpire"); return 1;
    case 47: if (data) std::strcpy(static_cast<char *>(data), "Sonic Anomaly"); return 1;
    case 49: return 1000;
    case 51:
        if (data) {
            const auto *capability = static_cast<const char *>(data);
            if (std::strcmp(capability, "hasCockosViewAsConfig") == 0) return int32_t(0xbeef0000u);
            if (std::strcmp(capability, "2in2out") == 0 ||
                std::strcmp(capability, "plugAsChannelInsert") == 0 ||
                std::strcmp(capability, "plugAsSend") == 0) return 1;
        }
        return 0;
    case 58: return 2400;
    default: return 0;
    }
}
}

extern "C" __attribute__((visibility("default"))) Effect *VSTPluginMain(Host host)
{
    if (!host || !host(nullptr, 1, 0, 0, nullptr, 0)) return nullptr;
    Dl_info info{};
    if (!dladdr(&imageAnchor, &info) || !info.dli_fname) return nullptr;
    const auto path = std::string(info.dli_fname);
    const auto resources = path.substr(0, path.rfind("/MacOS/")) + "/Resources";
    const auto script = resources + "/Transpire.jsfx";
    auto p = std::make_unique<Instance>(host);
    std::unique_ptr<ysfx_config_t, decltype(&ysfx_config_free)> config(ysfx_config_new(), ysfx_config_free);
    ysfx_guess_file_roots(config.get(), script.c_str());
    p->fx.reset(ysfx_new(config.get()));
    if (!ysfx_load_file(p->fx.get(), script.c_str(), 0) || !ysfx_compile(p->fx.get(), 0))
        return nullptr;
    ysfx_set_sample_rate(p->fx.get(), 44100);
    ysfx_set_block_size(p->fx.get(), 512);
    ysfx_init(p->fx.get());
    for (unsigned i = 0; i < sliders.size(); ++i) {
        if (!ysfx_slider_get_curve(p->fx.get(), sliders[i], &p->curves[i])) return nullptr;
        p->applied[i] = ysfx_ysfx_value_to_normalized(ysfx_slider_get_value(p->fx.get(), sliders[i]), &p->curves[i]);
        p->values[i].store(p->applied[i]);
    }
    auto &e = p->effect;
    e.magic = 0x56737450;
    e.dispatcher = dispatch;
    e.setParameter = setParameter;
    e.getParameter = getParameter;
    e.numPrograms = 1;
    e.numParams = 4;
    e.numInputs = 2;
    e.numOutputs = 2;
    e.flags = 1 | (1 << 4);
    e.object = p.get();
    e.uniqueId = 0x54525350;
    e.version = 1000;
    e.processReplacing = process;
    p.release();
    return &e;
}

extern "C" __attribute__((visibility("default"))) Effect *main_macho(Host host)
{
    return VSTPluginMain(host);
}
