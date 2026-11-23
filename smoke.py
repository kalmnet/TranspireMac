import ctypes as c
import math
import sys


class Effect(c.Structure):
    pass


EffectPtr = c.POINTER(Effect)
Dispatch = c.CFUNCTYPE(c.c_ssize_t, EffectPtr, c.c_int32, c.c_int32, c.c_ssize_t, c.c_void_p, c.c_float)
Set = c.CFUNCTYPE(None, EffectPtr, c.c_int32, c.c_float)
Get = c.CFUNCTYPE(c.c_float, EffectPtr, c.c_int32)
Channel = c.POINTER(c.c_float)
Audio = c.CFUNCTYPE(None, EffectPtr, c.POINTER(Channel), c.POINTER(Channel), c.c_int32)

Effect._fields_ = [
    ("magic", c.c_int32), ("dispatch", Dispatch), ("process", c.c_void_p),
    ("set", Set), ("get", Get), ("programs", c.c_int32), ("parameters", c.c_int32),
    ("inputs", c.c_int32), ("outputs", c.c_int32), ("flags", c.c_int32),
    ("reserved1", c.c_void_p), ("reserved2", c.c_void_p), ("delay", c.c_int32),
    ("real", c.c_int32), ("offline", c.c_int32), ("ratio", c.c_float),
    ("object", c.c_void_p), ("user", c.c_void_p), ("unique_id", c.c_int32),
    ("version", c.c_int32), ("replace", Audio),
]


@Dispatch
def host(_effect, opcode, _index, _value, _data, _option):
    return 2400 if opcode == 1 else 0


library = c.CDLL(sys.argv[1])
main = library.VSTPluginMain
main.argtypes = [Dispatch]
main.restype = EffectPtr
plugin = main(host)
assert plugin, "VSTPluginMain could not load the bundled Transpire JSFX"
effect = plugin.contents
try:
    assert effect.magic == 0x56737450 and effect.unique_id == 0x54525350
    assert (effect.parameters, effect.inputs, effect.outputs) == (4, 2, 2)
    for index in range(4):
        effect.set(plugin, index, 0.7)
        assert math.isclose(effect.get(plugin, index), 0.7, abs_tol=1e-6)

    effect.dispatch(plugin, 0, 0, 0, None, 0)
    effect.dispatch(plugin, 10, 0, 0, None, 48000)
    assert effect.delay == int(88 * 48000 / 44100)
    effect.dispatch(plugin, 11, 0, 512, None, 0)
    effect.dispatch(plugin, 12, 0, 1, None, 0)
    samples = c.c_float * 512
    left, right = samples(), samples()
    out_left, out_right = samples(), samples()
    left[20] = right[20] = 0.5
    inputs, outputs = (Channel * 2)(left, right), (Channel * 2)(out_left, out_right)
    for _ in range(8):
        effect.replace(plugin, inputs, outputs, 512)
        assert all(math.isfinite(sample) for sample in out_left)
    assert any(out_left), "Transpire produced silence for every impulse"
finally:
    effect.dispatch(plugin, 1, 0, 0, None, 0)
