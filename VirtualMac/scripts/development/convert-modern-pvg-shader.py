#!/usr/bin/env python3
"""Convert a single-function PVG Metal library using Apple's real AIR lowering.

This is a CPU-only diagnostic tool for the macOS 27 compiler ABI measured in
Tahoe3/modern-shader-compat. It never rewrites language-version metadata itself.
Apple's downgrade pass transforms the module, and Apple's library writer builds
the entire output library and its reflection. GPU execution must be verified
separately on the target iPad; a valid AIR module is not an execution result.
"""

import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import tempfile


COMPILER = (
    "/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/"
    "Libraries/libGPUCompiler.dylib"
)
HEADER = struct.Struct("<4sHHHBBHH9Q")


class Version(C.Structure):
    _fields_ = [("major", C.c_uint32), ("minor", C.c_uint32), ("patch", C.c_uint32)]

    def tuple(self):
        return (self.major, self.minor, self.patch)


def read_single_function(data):
    if len(data) < HEADER.size or len(data) > 16 * 1024 * 1024:
        raise ValueError("library must contain 88 bytes to 16 MiB")
    header = HEADER.unpack_from(data)
    if header[0] != b"MTLB" or header[2] != 2 or header[8] != len(data):
        raise ValueError("not the measured complete version-2 Metal library")
    function_offset, function_size = header[9:11]
    bitcode_offset, bitcode_size = header[15:17]
    # The measured size counts the records and excludes the leading count word.
    if function_offset < HEADER.size or function_offset + 4 + function_size > len(data):
        raise ValueError("function table is outside the library")
    if bitcode_offset + bitcode_size > len(data):
        raise ValueError("AIR section is outside the library")
    count, _record_size = struct.unpack_from("<II", data, function_offset)
    if count != 1:
        raise ValueError("PVG newFunctionWithIR requires exactly one function")
    tags = {}
    cursor = function_offset + 8
    end = function_offset + 4 + function_size
    while cursor + 4 <= end:
        tag = data[cursor:cursor + 4]
        cursor += 4
        if tag == b"ENDT":
            break
        if cursor + 2 > end:
            raise ValueError("truncated function tag length")
        length, = struct.unpack_from("<H", data, cursor)
        cursor += 2
        if cursor + length > end or tag in tags:
            raise ValueError("invalid or repeated function tag")
        tags[tag] = data[cursor:cursor + length]
        cursor += length
    else:
        raise ValueError("function table has no ENDT")
    name = tags.get(b"NAME", b"").rstrip(b"\0")
    if not name or b"\0" in name:
        raise ValueError("function has no unambiguous name")
    offsets = tags.get(b"OFFT")
    if not offsets or len(offsets) != 24:
        raise ValueError("function has no measured three-offset record")
    offset = struct.unpack("<3Q", offsets)[2]
    encoded_size = tags.get(b"MDSZ")
    size = struct.unpack("<Q", encoded_size)[0] if encoded_size else bitcode_size - offset
    if offset + size > bitcode_size:
        raise ValueError("function AIR is outside its section")
    air = data[bitcode_offset + offset:bitcode_offset + offset + size]
    if not air.startswith((b"\xde\xc0\x17\x0b", b"BC\xc0\xde")):
        raise ValueError("function data is not an LLVM/AIR bitcode input")
    return name, air


def load_api():
    library = C.CDLL(COMPILER)
    signatures = {
        "LLVMContextCreate": (C.c_void_p, []),
        "LLVMContextDispose": (None, [C.c_void_p]),
        "LLVMCreateMemoryBufferWithMemoryRangeCopy":
            (C.c_void_p, [C.c_char_p, C.c_size_t, C.c_char_p]),
        "LLVMDisposeMemoryBuffer": (None, [C.c_void_p]),
        "LLVMParseBitcodeInContext2":
            (C.c_int, [C.c_void_p, C.c_void_p, C.POINTER(C.c_void_p)]),
        "LLVMDisposeModule": (None, [C.c_void_p]),
        "LLVMGetNamedFunction": (C.c_void_p, [C.c_void_p, C.c_char_p]),
        "LLVMSetValueName2": (None, [C.c_void_p, C.c_char_p, C.c_size_t]),
        "LLVMPrintModuleToString": (C.c_void_p, [C.c_void_p]),
        "LLVMDisposeMessage": (None, [C.c_void_p]),
        "LLVMVerifyModule": (C.c_int, [C.c_void_p, C.c_int, C.POINTER(C.c_void_p)]),
        "MTLDowngradeAIRModule": (C.c_bool, [C.c_void_p, Version]),
        "MTLVerifyAIRModule": (C.c_bool, [C.c_void_p]),
        "LLVMExtraMakeSharedModule": (C.c_void_p, [C.c_void_p]),
        "LLVMExtraDisposeSharedModule": (None, [C.c_void_p]),
        "MTLMetalFunctionCreate": (C.c_void_p, [C.c_void_p, C.c_char_p]),
        "MTLMetalFunctionGetAIRVersion": (Version, [C.c_void_p]),
        "MTLMetalFunctionGetMetalVersion": (Version, [C.c_void_p]),
        "MTLMetalFunctionGetName": (C.c_char_p, [C.c_void_p]),
        "MTLMetalLibCreateExecutableWithTriple": (C.c_void_p, [C.c_char_p]),
        "MTLMetalLibInsertFunction": (None, [C.c_void_p, C.c_void_p]),
        "MTLWriteMetalLibToMemoryBuffer": (C.c_void_p, [C.c_void_p]),
        "LLVMGetBufferStart": (C.c_void_p, [C.c_void_p]),
        "LLVMGetBufferSize": (C.c_size_t, [C.c_void_p]),
    }
    for name, (result, arguments) in signatures.items():
        function = getattr(library, name)
        function.restype, function.argtypes = result, arguments
    return library


def module_text(api, module):
    pointer = api.LLVMPrintModuleToString(module)
    try:
        return C.string_at(pointer).decode()
    finally:
        api.LLVMDisposeMessage(pointer)


def module_versions(text):
    result = {}
    triple = re.search(r'^target triple = "([^"]+)"', text, re.M)
    result["target"] = triple.group(1) if triple else None
    for name in ("air.version", "air.language_version"):
        reference = re.search(r"!" + re.escape(name) + r" = !\{!(\d+)\}", text)
        node = re.search(r"^!" + reference.group(1) + r" = !\{(.*)\}$", text, re.M) if reference else None
        result[name] = [int(n) for n in re.findall(r"i32 (\d+)", node.group(1))] if node else None
    return result


def convert(data, target=(2, 5, 0), container_triple=None, function_name=None):
    name, air = read_single_function(data)
    input_name = name
    api = load_api()
    context = api.LLVMContextCreate()
    memory = api.LLVMCreateMemoryBufferWithMemoryRangeCopy(air, len(air), name)
    module, shared, output = C.c_void_p(), None, None
    try:
        if api.LLVMParseBitcodeInContext2(context, memory, C.byref(module)):
            raise ValueError("Apple LLVM could not parse the actual shader AIR")
        # A genuinely recompiled source function can restore a private PVG
        # symbol (containing '.') that Metal's source host_name syntax rejects.
        # LLVM changes the actual function symbol and its metadata references;
        # the complete library writer derives its NAME tag from that symbol.
        if function_name is not None and function_name != name:
            if not isinstance(function_name, bytes) or not function_name or b"\0" in function_name:
                raise ValueError("invalid output function symbol")
            function = api.LLVMGetNamedFunction(module, name)
            if not function:
                raise ValueError("input function symbol is absent from its real AIR")
            api.LLVMSetValueName2(function, function_name, len(function_name))
            name = function_name
        before = module_text(api, module)
        changed = api.MTLDowngradeAIRModule(module, Version(*target))
        if not api.MTLVerifyAIRModule(module):
            raise ValueError("Apple AIR verifier rejected the transformed module")
        verification_error = C.c_void_p()
        if api.LLVMVerifyModule(module, 2, C.byref(verification_error)):
            message = C.string_at(verification_error).decode() if verification_error else "unknown"
            if verification_error:
                api.LLVMDisposeMessage(verification_error)
            raise ValueError("Apple LLVM verifier rejected the transformed module: " + message)
        if verification_error:
            api.LLVMDisposeMessage(verification_error)
        after = module_text(api, module)
        versions = module_versions(after)
        if versions["air.version"] != list(target):
            raise ValueError("Apple pass did not produce the requested AIR version")
        language = versions["air.language_version"]
        if language is None or tuple(language) > (3, 0, 0):
            raise ValueError("Apple pass retained a language version unsupported by iPadOS 16")

        # LLVMExtraMakeSharedModule takes ownership. MetalFunctionCreate keeps
        # that real module alive and derives reflection and versions from it.
        shared = api.LLVMExtraMakeSharedModule(module)
        module = C.c_void_p()
        function = api.MTLMetalFunctionCreate(shared, name)
        if not function or api.MTLMetalFunctionGetName(function) != name:
            raise ValueError("Apple could not rebuild the original named function")
        air_version = api.MTLMetalFunctionGetAIRVersion(function).tuple()
        language_version = api.MTLMetalFunctionGetMetalVersion(function).tuple()
        if air_version != target or language_version != tuple(language):
            raise ValueError("Apple function reflection disagrees with transformed AIR")
        # Library target is chosen through Apple's real writer API. An iOS
        # container is a separate cross-platform experiment: the AIR module's
        # own target remains exactly what Apple's downgrade pass produced.
        library_triple = container_triple or versions["target"]
        library = api.MTLMetalLibCreateExecutableWithTriple(library_triple.encode())
        if not library:
            raise ValueError("Apple could not create the target Metal library")
        # InsertFunction transfers ownership; WriteMetalLib consumes the library.
        api.MTLMetalLibInsertFunction(library, function)
        output = api.MTLWriteMetalLibToMemoryBuffer(library)
        if not output:
            raise ValueError("Apple Metal library writer rejected the transformed function")
        converted = C.string_at(api.LLVMGetBufferStart(output), api.LLVMGetBufferSize(output))
        output_name, output_air = read_single_function(converted)
        if output_name != name or not output_air:
            raise ValueError("rebuilt library failed structural round-trip validation")
        return converted, {
            "function": name.decode(), "inputFunction": input_name.decode(),
            "inputSHA256": hashlib.sha256(data).hexdigest(),
            "outputSHA256": hashlib.sha256(converted).hexdigest(),
            "inputBytes": len(data), "outputBytes": len(converted),
            "before": module_versions(before), "after": versions,
            "appleDowngradeChanged": bool(changed), "appleAIRVerifier": True,
            "appleLLVMVerifier": True, "appleFunctionAIRVersion": air_version,
            "appleFunctionLanguageVersion": language_version,
            "compiler": COMPILER, "gpuExecutionVerified": False,
            "libraryContainerTarget": library_triple,
        }, before, after
    finally:
        if output:
            api.LLVMDisposeMemoryBuffer(output)
        if shared:
            api.LLVMExtraDisposeSharedModule(shared)
        elif module:
            api.LLVMDisposeModule(module)
        api.LLVMDisposeMemoryBuffer(memory)
        api.LLVMContextDispose(context)


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        stream.write(data)
        temporary = stream.name
    os.replace(temporary, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--container-triple", choices=["air64-apple-ios16.0.0"],
                        help="Ask Apple's writer for an iOS-16 container; AIR target is preserved")
    arguments = parser.parse_args()
    converted, report, before, after = convert(arguments.input.read_bytes(),
                                              container_triple=arguments.container_triple)
    atomic_write(arguments.output, converted)
    atomic_write(arguments.output.with_suffix(".conversion.json"),
                 (json.dumps(report, indent=2) + "\n").encode())
    atomic_write(arguments.output.with_suffix(".before.ll"), before.encode())
    atomic_write(arguments.output.with_suffix(".after.ll"), after.encode())
    print(json.dumps(report))


if __name__ == "__main__":
    main()
