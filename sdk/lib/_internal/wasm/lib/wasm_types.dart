// Copyright (c) 2022, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart.wasm;

@pragma("wasm:entry-point")
abstract class _WasmBase {}

abstract class _WasmInt extends _WasmBase {}

abstract class _WasmFloat extends _WasmBase {}

@pragma("wasm:entry-point")
class WasmAnyRef extends _WasmBase {}

@pragma("wasm:entry-point")
class WasmEqRef extends WasmAnyRef {}

@pragma("wasm:entry-point")
class WasmDataRef extends WasmEqRef {}

abstract class _WasmArray extends WasmDataRef {
  @pragma("vm:external-name", "WasmArray_length")
  external int get length;
}

@pragma("wasm:entry-point")
class WasmI8 extends _WasmInt {}

@pragma("wasm:entry-point")
class WasmI16 extends _WasmInt {}

@pragma("wasm:entry-point")
class WasmI32 extends _WasmInt {}

@pragma("wasm:entry-point")
class WasmI64 extends _WasmInt {}

@pragma("wasm:entry-point")
class WasmF32 extends _WasmFloat {}

@pragma("wasm:entry-point")
class WasmF64 extends _WasmFloat {}

@pragma("wasm:entry-point")
class WasmIntArray<T extends _WasmInt> extends _WasmArray {
  @pragma("vm:external-name", "WasmIntArray")
  external factory WasmIntArray(int length);

  @pragma("vm:external-name", "WasmIntArray_readSigned")
  external int readSigned(int index);
  @pragma("vm:external-name", "WasmIntArray_readUnsigned")
  external int readUnsigned(int index);
  @pragma("vm:external-name", "WasmIntArray_write")
  external void write(int index, int value);
}

@pragma("wasm:entry-point")
class WasmFloatArray<T extends _WasmFloat> extends _WasmArray {
  @pragma("vm:external-name", "WasmFloatArray")
  external factory WasmFloatArray(int length);

  @pragma("vm:external-name", "WasmFloatArray_read")
  external double read(int index);
  @pragma("vm:external-name", "WasmFloatArray_write")
  external void write(int index, double value);
}

@pragma("wasm:entry-point")
class WasmObjectArray<T extends Object?> extends _WasmArray {
  @pragma("vm:external-name", "WasmObjectArray")
  external factory WasmObjectArray(int length);

  @pragma("vm:external-name", "WasmObjectArray_read")
  external T read(int index);
  @pragma("vm:external-name", "WasmObjectArray_write")
  external void write(int index, T value);
}
