// Copyright (c) 2021, the Dart project authors.  Please see the AUTHORS file
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
  int get length native "WasmArray_length";
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
  factory WasmIntArray(int length) native "WasmIntArray";

  int readSigned(int index) native "WasmIntArray_readSigned";
  int readUnsigned(int index) native "WasmIntArray_readUnsigned";
  void write(int index, int value) native "WasmIntArray_write";
}

@pragma("wasm:entry-point")
class WasmFloatArray<T extends _WasmFloat> extends _WasmArray {
  factory WasmFloatArray(int length) native "WasmFloatArray";

  double read(int index) native "WasmFloatArray_read";
  void write(int index, double value) native "WasmFloatArray_write";
}

@pragma("wasm:entry-point")
class WasmObjectArray<T extends Object?> extends _WasmArray {
  factory WasmObjectArray(int length) native "WasmObjectArray";

  T read(int index) native "WasmObjectArray_read";
  void write(int index, T value) native "WasmObjectArray_write";
}
